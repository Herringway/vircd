module vircd.server;

import std.datetime.systime;
import std.base64 : Base64;

import vibe.core.log;
import vibe.core.stream;
import vibe.http.websockets;
import vibe.stream.operations;

import virc : IRCMessage, Target, UserMask, VIRCChannel = Channel, VIRCUser = User;

enum maxLineLength = 510;

struct Client {
	string id;
	Stream stream;
	WebSocket webSocket;
	bool sentUSER;
	bool sentNICK;
	bool registered;
	bool usingWebSocket;
	bool waitForCapEnd;
	bool supportsCap302;
	bool supportsCapNotify;
	bool supportsEcho;
	bool isAuthenticating;
	string address;
	this(WebSocket socket, string addr) @safe {
		usingWebSocket = true;
		webSocket = socket;
		address = addr;
	}
	this(Stream socket, string addr) @safe {
		usingWebSocket = false;
		stream = socket;
		address = addr;
	}
	string receive() @safe {
		import std.string : assumeUTF;
		if (usingWebSocket) {
			return webSocket.receiveText();
		} else {
			return assumeUTF(stream.readUntil(['\r', '\n'], 512));
		}
	}
	void send(const IRCMessage message) @safe {
		logDebugV("Sending message: %s", message.toString());
		if (usingWebSocket) {
			webSocket.send(message.toString());
		} else {
			stream.write(message.toString());
			stream.write("\r\n");
		}
	}
	bool hasMoreData() @safe {
		if (usingWebSocket) {
			return webSocket.waitForData();
		} else {
			return !stream.empty;
		}
	}
	bool meetsRegistrationRequirements() @safe const {
		return sentUSER && sentNICK && !waitForCapEnd;
	}
}

struct User {
	string randomID;
	string account;
	Client[string] clients;
	SysTime connected;
	UserMask mask;
	string realname;
	bool isAnonymous = true;
	this(string userID, Client client) @safe {
		randomID = userID;
		clients[userID] = client;
		connected = Clock.currTime;
	}
	void send(const IRCMessage message) @safe {
		foreach (client; clients) {
			if (message.sourceUser.isNull || client.supportsEcho || (message.sourceUser == asVIRCUser)) {
				client.send(message);
			}
		}
	}
	bool shouldCleanup() @safe const {
		return isAnonymous && clients.length == 0;
	}
	auto accountID() @safe const {
		assert(!isAnonymous, "Anonymous users don't have accounts");
		return id;
	}
	auto id() @safe const {
		return isAnonymous ? randomID : account;
	}
	auto asVIRCUser() @safe const {
		return VIRCUser(mask);
	}
}

struct Account {
	string id;
	// this is wildly insecure, hooray
	string password;
}

struct Channel {
	string name;
	SysTime created;
	string topic;
	string[] users;
	this(string id) @safe {
		name = id;
		created = Clock.currTime;
	}
}

struct VIRCd {
	import virc.ircv3.base : Capability;
	User[string] connections;
	Channel[string] channels;
	string networkName = "Unnamed";
	string serverName = "Unknown";
	string serverVersion = "v0.0.0";
	string networkAddress = "localhost";
	VIRCUser networkUser;
	string modePrefixes = "@%+";
	string channelPrefixes = "#";
	string userModes;
	string channelModes;
	Capability[] supportedCaps = [
		Capability("cap-notify", ""),
		Capability("echo-message", ""),
		Capability("sasl", "PLAIN")
	];
	SysTime serverCreatedTime;

	Account[string] accounts;

	void init() @safe {
		serverCreatedTime = Clock.currTime;
		networkUser = VIRCUser(networkAddress);
	}

	void handleStream(Stream stream, string address) @safe {
		handleStream(Client(stream, address));
	}
	void handleStream(WebSocket stream, string address) @safe {
		handleStream(Client(stream, address));
	}
	void handleStream(Client client) @safe {
		import std.conv : text;
		import std.random : uniform;
		auto randomID = uniform!ulong().text;
		client.id = randomID;
		string lastID = randomID;
		auto user = new User(randomID, client);
		user.mask.host = client.address;

		logInfo("User connected: %s/%s", client.address, randomID);

		scope(exit) cleanup(user.id, randomID, "Connection reset by peer");

		while (client.hasMoreData) {
			receive(client.receive(), *user, client);
			if (client.registered && (user.id != lastID)) {
				user = user.id in connections;
				client = user.clients[randomID];
				lastID = user.id;
			}
		}
	}
	void cleanup(string id, string clientID, string message) @safe {
		logInfo("Client disconnected: %s: %s", id, message);
		if (id in connections) {
			connections[id].clients.remove(clientID);
			if (connections[id].shouldCleanup) {
				sendToTarget(Target(VIRCUser(connections[id].mask.nickname)), createQuit(connections[id], message));
				if (!connections.remove(id)) {
					logWarn("Could not remove ID from connection list?");
				}
			}
		} else {
			logWarn("ID of user not found");
		}
	}
	void receive(string str, ref User thisUser, ref Client thisClient) @safe {
		import std.algorithm.iteration : map;
		import std.algorithm.searching : canFind;
		import std.conv : text;
		import virc.ircmessage : IRCMessage;
		auto msg = IRCMessage.fromClient(str);
		switch(msg.verb) {
			case "CAP":
				auto args = msg.args;
				if (args.empty) {
					break;
				}
				const subCommand = args.front;
				args.popFront();
				switch (subCommand) {
					case "LS":
						if (!args.empty && args.front == "302") {
							thisClient.supportsCap302 = true;
						}
						thisClient.waitForCapEnd = true;
						sendCapList(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", "LS");
						break;
					case "LIST":
						sendCapList(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", "LIST");
						break;
					case "REQ":
						Capability[] caps;
						bool reject;
						foreach (clientCap; args.front.splitter(" ").map!(x => Capability(x))) {
							if (!supportedCaps.canFind(clientCap.name)) {
								reject = true;
								break;
							}
							caps ~= clientCap;
						}
						if (reject) {
							sendCapNAK(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", args.front);
						} else {
							sendCapACK(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", args.front);
						}
						foreach (cap; caps) {
							switch (cap) {
								case "cap-notify":
									thisClient.supportsCapNotify = !cap.isDisabled;
									break;
								case "echo-message":
									thisClient.supportsEcho = !cap.isDisabled;
									break;
								case "sasl":
									break;
								default: assert(0, "Unsupported CAP ACKed???");
							}
						}
						break;
					case "END":
						thisClient.waitForCapEnd = false;
						if (!thisClient.registered && thisClient.meetsRegistrationRequirements) {
							completeRegistration(thisClient, thisUser);
						}
						break;
					default:
						sendERRInvalidCapCmd(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", subCommand);
					break;
				}
				break;
			case "AUTHENTICATE":
				auto args = msg.args;
				if (args.empty) {
					break;
				}
				const subCommand = args.front;
				args.popFront();
				switch (subCommand) {
					case "PLAIN":
						thisClient.send(createMessage(networkUser, "AUTHENTICATE", "+"));
						thisClient.isAuthenticating = true;
						break;
					default:
						if (thisClient.isAuthenticating) {
							auto decoded = Base64.decode(subCommand).splitter(0);
							if (decoded.empty) {
								sendERRSASLFail(thisClient, thisClient.registered ? thisUser.mask.nickname : "*");
								break;
							}
							string authcid = cast(string)decoded.front.idup;
							decoded.popFront();
							if (decoded.empty) {
								sendERRSASLFail(thisClient, thisClient.registered ? thisUser.mask.nickname : "*");
								break;
							}
							string authzid = cast(string)decoded.front.idup;
							decoded.popFront();
							if (decoded.empty) {
								sendERRSASLFail(thisClient, thisClient.registered ? thisUser.mask.nickname : "*");
								break;
							}
							string password = cast(string)decoded.front.idup;
							string account = authzid;
							bool correct;
							if (auto acc = account in accounts) {
								if (acc.password == password) {
									correct = true;
								}
							}
							if (correct) {
								thisUser.account = account;
								thisUser.isAnonymous = false;
								sendRPLLoggedIn(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", thisUser.mask, account);
								sendRPLSASLSuccess(thisClient, thisClient.registered ? thisUser.mask.nickname : "*");
							} else {
								sendERRSASLFail(thisClient, thisClient.registered ? thisUser.mask.nickname : "*");
							}
							thisClient.isAuthenticating = false;
						} else {
							sendRPLSASLMechs(thisClient, thisClient.registered ? thisUser.mask.nickname : "*");
						}
						break;
				}
				break;
			case "NICK":
				auto nickname = msg.args.front;
				auto currentNickname = thisUser.mask.nickname;
				if (auto alreadyUsed = getUserByNickname(nickname)) {
					if (alreadyUsed.id != thisUser.id) {
						sendERRNicknameInUse(thisUser, nickname);
						break;
					}
				}
				if (thisClient.registered) {
					sendToTarget(Target(VIRCUser(currentNickname)), createNickChange(thisUser, nickname));
				}
				thisUser.mask.nickname = nickname;
				thisClient.sentNICK = true;
				if (!thisClient.registered && thisClient.meetsRegistrationRequirements) {
					completeRegistration(thisClient, thisUser);
				}
				break;
			case "USER":
				if (thisClient.registered) {
					break;
				}
				auto args = msg.args;
				thisUser.mask.ident = args.front;
				args.popFront();
				const unused = args.front;
				args.popFront();
				const unused2 = args.front;
				args.popFront();
				thisUser.realname = args.front;
				thisClient.sentUSER = true;
				if (!thisClient.registered && thisClient.meetsRegistrationRequirements) {
					completeRegistration(thisClient, thisUser);
				}
				break;
			case "QUIT":
				cleanup(thisUser.id, thisClient.id, msg.args.front);
				break;
			case "JOIN":
				if (!thisClient.registered) {
					break;
				}
				void joinChannel(ref Channel channel) @safe {
					channel.users ~= thisUser.id;
					sendToTarget(Target(VIRCChannel(channel.name)), createJoin(thisUser, channel.name));
					sendNames(thisClient, thisClient.registered ? thisUser.mask.nickname : "*", channel);
				}
				auto channelsToJoin = msg.args.front.splitter(",");
				foreach (channel; channelsToJoin) {
					final switch (couldUserJoin(thisUser, channel)) {
						case JoinAttemptResult.yes:
							if (channel[0] != '#') {
								channel = "#"~channel;
							}
							logDebugV("%s joining channel %s", thisUser.id, channel);
							joinChannel(channels.require(channel, Channel(channel)));
							break;
						case JoinAttemptResult.illegalChannel:
							sendERRNoSuchChannel(thisUser, channel);
							continue;
					}
				}
				break;
			case "PRIVMSG":
				if (!thisClient.registered) {
					break;
				}
				auto args = msg.args;
				auto targets = args.front.splitter(",").map!(x => Target(x, modePrefixes, channelPrefixes));
				args.popFront();
				auto message = args.front;
				foreach (target; targets) {
					sendToTarget(target, createPrivmsg(thisUser, target, message));
				}
				break;
			case "NOTICE":
				if (!thisClient.registered) {
					break;
				}
				auto args = msg.args;
				auto targets = args.front.splitter(",").map!(x => Target(x, modePrefixes, channelPrefixes));
				args.popFront();
				auto message = args.front;
				foreach (target; targets) {
					sendToTarget(target, createNotice(thisUser, target, message));
				}
				break;
			case "PING":
				if (!msg.args.empty) {
					thisClient.send(createMessage(thisUser, "PONG", networkUser.text, msg.args.front));
				} else {
					thisClient.send(createMessage(thisUser, "PONG", networkUser.text));
				}
				break;
			default:
				logInfo("Unhandled verb '%s' with args %s", msg.verb, msg.args);
				break;
		}
	}
	void completeRegistration(ref Client client, ref User user) @safe
		in(client.meetsRegistrationRequirements, "Client does not meet registration requirements yet")
		in(!client.registered, "Client already registered")
	{
		import std.algorithm.searching : canFind;
		client.registered = true;
		connections.require(user.id, user);
		connections[user.id].clients[user.randomID] = client;
		sendRPLWelcome(client, user.mask.nickname);
		sendRPLYourHost(client, user.mask.nickname);
		sendRPLCreated(client, user.mask.nickname);
		sendRPLMyInfo(client, user.mask.nickname);
		sendRPLISupport(client, user.mask.nickname);
		foreach (channel; channels) {
			if (!channel.users.canFind(user.id)) {
				continue;
			}
			client.send(createJoin(user, channel.name));
			sendNames(client, user.mask.nickname, channel);
		}
		if (user.mask.nickname != connections[user.id].mask.nickname) {
			client.send(createNickChange(user, connections[user.id].mask.nickname));
		}
	}
	auto subscribedUsers(const Target target) @safe {
		import std.algorithm.searching : canFind;
		User*[] result;
		if (target.isChannel) {
			if (target.targetText in channels) {
				foreach (user; channels[target.targetText].users) {
					result ~= user in connections;
				}
			}
		} else if (target.isUser) {
			string id;
			foreach (user; connections) {
				if (user.mask.nickname == target.targetText) {
					id = user.id;
					break;
				}
			}
			if (id != "") {
				foreach (channel; channels) {
					if (channel.users.canFind(id)) {
						foreach (user; channel.users) {
							result ~= user in connections;
						}
					}
				}
				if (result.length == 0) {
					result ~= id in connections;
				}
			}
		}
		return result;
	}
	void sendNames(ref Client client, const string nickname, const Channel channel) @safe {
		sendRPLNamreply(client, nickname, channel);
		sendRPLEndOfNames(client, nickname, channel.name);
	}
	auto createMessage(const User subject, string verb, string[] args...) @safe {
		return createMessage(subject.asVIRCUser, verb, args);
	}
	auto createMessage(const VIRCUser subject, string verb, string[] args...) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.sourceUser = subject;
		ircMessage.verb = verb;
		ircMessage.args = args;
		return ircMessage;
	}
	auto createNickChange(const User subject, string newNickname) @safe {
		return createMessage(subject, "NICK", newNickname);
	}
	auto createJoin(ref User subject, string channel) @safe {
		return createMessage(subject, "JOIN", channel);
	}
	auto createQuit(ref User subject, string msg) @safe {
		return createMessage(subject, "QUIT", msg);
	}
	auto createPrivmsg(ref User subject, Target target, string message) @safe {
		import std.conv : text;
		return createMessage(subject, "PRIVMSG", target.text, message);
	}
	auto createNotice(ref User subject, Target target, string message) @safe {
		import std.conv : text;
		return createMessage(subject, "NOTICE", target.text, message);
	}
	void sendCapList(ref Client client, string nickname, string subCommand) @safe {
		import std.array : empty;
		import std.algorithm.iteration : map;
		import std.string : join;
		auto capsToSend = supportedCaps;
		const capLengthLimit = maxLineLength - (networkAddress.length + 2) - "CAP ".length - (nickname.length + 1) - (subCommand.length + 3);
		do {
			size_t thisLength = 0;
			size_t numCaps;
			foreach (i, cap; capsToSend) {
				thisLength += cap.name.length + 1;
				if (client.supportsCap302) {
					thisLength += cap.value.length+1;
				}
				if (thisLength > capLengthLimit) {
					assert(i > 0, "CAP name way too long");
					numCaps = i;
					break;
				}
				if (i == capsToSend.length-1) {
					numCaps = i + 1;
					break;
				}
			}
			string[] args;
			args.reserve(4);
			args ~= [nickname, subCommand];
			assert((capsToSend.length == 0) || (numCaps > 0), "Unexpectedly sending zero caps");
			if (client.supportsCap302) {
				if (numCaps < capsToSend.length) {
					args ~= "*";
				}
				args ~= capsToSend[0 .. numCaps].map!(x => x.toString).join(" ");
			} else {
				args ~= capsToSend[0 .. numCaps].map!(x => x.name).join(" ");
			}
			client.send(createMessage(networkUser, "CAP", args));
			capsToSend = capsToSend[numCaps .. $];
		} while(!capsToSend.empty);
	}
	void sendCapACK(ref Client client, string nickname, string capList) @safe {
		client.send(createMessage(networkUser, "CAP", nickname, "ACK", capList));
	}
	void sendCapNAK(ref Client client, string nickname, string capList) @safe {
		client.send(createMessage(networkUser, "CAP", nickname, "NAK", capList));
	}
	void sendCapNEW(ref User user, string capList) @safe {
		user.send(createMessage(networkUser, "CAP", user.mask.nickname, "NEW", capList));
	}
	void sendCapDEL(ref User user, string capList) @safe {
		user.send(createMessage(networkUser, "CAP", user.mask.nickname, "DEL", capList));
	}
	void sendRPLWelcome(ref Client client, const string nickname) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 1, format!"Welcome to the %s Network, %s"(networkName, nickname));
	}
	void sendRPLYourHost(ref Client client, const string nickname) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 2, format!"Your host is %s, running version %s"(serverName, serverVersion));
	}
	void sendRPLCreated(ref Client client, const string nickname) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 3, format!"This server was created %s"(serverCreatedTime));
	}
	void sendRPLMyInfo(ref Client client, const string nickname) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 4, serverName, serverVersion, userModes, channelModes);
	}
	void sendRPLISupport(ref Client client, const string nickname) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 5, "are supported by this server");
	}
	void sendRPLNamreply(ref Client user, const string nickname, const Channel channel) @safe {
		import std.algorithm.iteration : map;
		import std.format : format;
		sendNumeric(user, nickname, 353, ["=", channel.name, format!"%-(%s %)"(channel.users.map!(x => connections[x].mask.nickname))]);
	}
	void sendRPLEndOfNames(ref Client user, const string nickname, string channel) @safe {
		sendNumeric(user, nickname, 366, [channel, "End of /NAMES list"]);
	}
	void sendRPLLoggedIn(ref Client user, const string nickname,  UserMask mask, string account) @safe {
		import std.conv : text;
		sendNumeric(user, nickname, 900, mask.text, account, "You are now logged in as "~account);
	}
	void sendRPLSASLSuccess(ref Client user, const string nickname) @safe {
		import std.conv : text;
		sendNumeric(user, nickname, 903, "SASL authentication successful");
	}
	void sendERRSASLFail(ref Client user, const string nickname) @safe {
		import std.conv : text;
		sendNumeric(user, nickname, 904, "SASL authentication failed");
	}
	void sendRPLSASLMechs(ref Client user, const string nickname) @safe {
		import std.format : format;
		sendNumeric(user, nickname, 908, "PLAIN", "are available SASL mechanisms");
	}
	void sendERRNoSuchChannel(ref User user, string channel) @safe {
		import std.format : format;
		sendNumeric(user, 403, [channel, "No such channel"]);
	}
	void sendERRInvalidCapCmd(ref Client client, const string nickname, string cmd) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 410, [cmd, "Invalid CAP command"]);
	}
	void sendERRNicknameInUse(ref User user, string nickname) @safe {
		import std.format : format;
		sendNumeric(user, 433, [nickname, "Nickname is already in use"]);
	}
	void sendNumeric(ref User user, ushort id, string[] args...) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.args = user.mask.nickname~args;
		sendNumericCommon(user, id, ircMessage);
	}
	void sendNumeric(ref Client client, const string nickname, ushort id, string[] args...) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.args = nickname~args;
		sendNumericCommon(client, id, ircMessage);
	}
	void sendNumericCommon(T)(ref T target, const ushort id, IRCMessage message) {
		import std.format : format;
		message.sourceUser = networkUser;
		message.verb = format!"%03d"(id);
		target.send(message);
	}
	void sendToTarget(Target target, const IRCMessage message) @safe {
		foreach (otherUser; subscribedUsers(target)) {
			otherUser.send(message);
		}
	}

	User* getUserByNickname(string nickname) @safe {
		foreach (id, user; connections) {
			if (user.mask.nickname == nickname) {
				return id in connections;
			}
		}
		return null;
	}
	enum JoinAttemptResult {
		yes,
		illegalChannel
	}
	auto couldUserJoin(ref User user, string channel) @safe {
		return JoinAttemptResult.yes;
	}
}

@safe unittest {
	auto ircd = VIRCd();
	ircd.init();
	ircd.addChannel("#test");
}
