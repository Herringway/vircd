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
		logDebugV("-> %s", message.toString());
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

struct Settings {
	Account[] accounts;
	string networkName = "Unnamed";
	string serverName = "Unknown";
	string canonicalAddress = "localhost";
	ushort tcpPort = 6697;
	ushort webSocketPort = 8080;
	string[] webSocketBindAddresses = ["::1", "127.0.0.1"];
	string[] webSocketPaths = ["/irc"];
	bool verboseLogging = false;
}

struct VIRCd {
	import virc.ircv3.base : Capability;
	User[string] connections;
	Channel[string] channels;
	string networkName = "Null";
	string serverName = "Null";
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

	void init(Settings settings) @safe {
		serverCreatedTime = Clock.currTime;
		foreach (account; settings.accounts) {
			accounts[account.id] = account;
		}
		networkName = settings.networkName;
		serverName = settings.serverName;
		networkAddress = settings.canonicalAddress;
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
		logDebugV("<- %s", str);
		auto msg = IRCMessage.fromClient(str);
		const myNickname = thisClient.registered ? thisUser.mask.nickname : "*";
		void reply(const IRCMessage msg) {
			thisClient.send(msg);
		}
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
						sendCapList(thisClient, myNickname, "LS");
						break;
					case "LIST":
						sendCapList(thisClient, myNickname, "LIST");
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
							reply(createCapNAK(myNickname, args.front));
						} else {
							reply(createCapACK(myNickname, args.front));
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
						reply(createERRInvalidCapCmd(myNickname, subCommand));
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
						reply(createMessage(networkUser, "AUTHENTICATE", "+"));
						thisClient.isAuthenticating = true;
						break;
					default:
						if (thisClient.isAuthenticating) {
							auto decoded = Base64.decode(subCommand).splitter(0);
							if (decoded.empty) {
								reply(createERRSASLFail(myNickname));
								break;
							}
							string authcid = cast(string)decoded.front.idup;
							decoded.popFront();
							if (decoded.empty) {
								reply(createERRSASLFail(myNickname));
								break;
							}
							string authzid = cast(string)decoded.front.idup;
							decoded.popFront();
							if (decoded.empty) {
								reply(createERRSASLFail(myNickname));
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
								reply(createRPLLoggedIn(myNickname, thisUser.mask, account));
								reply(createRPLSASLSuccess(myNickname));
							} else {
								reply(createERRSASLFail(myNickname));
							}
							thisClient.isAuthenticating = false;
						} else {
							reply(createRPLSASLMechs(myNickname));
						}
						break;
				}
				break;
			case "NICK":
				auto nickname = msg.args.front;
				auto currentNickname = thisUser.mask.nickname;
				if (auto alreadyUsed = getUserByNickname(nickname)) {
					if (alreadyUsed.id != thisUser.id) {
						reply(createERRNicknameInUse(myNickname, nickname));
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
			case "USERHOST":
				auto args = msg.args;
				if (args.empty) {
					reply(createERRNeedMoreParams(myNickname, msg.verb));
					break;
				}
				auto targets = args.front.splitter(",");
				foreach (target; targets) {
					if (auto user = getUserByNickname(target)) {
						reply(createRPLUserhost(myNickname, *user));
					}
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
					sendNames(thisClient, myNickname, channel);
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
							reply(createERRNoSuchChannel(myNickname, channel));
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
					reply(createMessage(thisUser, "PONG", networkUser.text, msg.args.front));
				} else {
					reply(createMessage(thisUser, "PONG", networkUser.text));
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
		client.send(createRPLWelcome(user.mask.nickname));
		client.send(createRPLYourHost(user.mask.nickname));
		client.send(createRPLCreated(user.mask.nickname));
		client.send(createRPLMyInfo(user.mask.nickname));
		client.send(createRPLISupport(user.mask.nickname));
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
		client.send(createRPLNamreply(nickname, channel));
		client.send(createRPLEndOfNames(nickname, channel.name));
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
	auto createCapACK(string nickname, string capList) @safe {
		return createMessage(networkUser, "CAP", nickname, "ACK", capList);
	}
	auto createCapNAK(string nickname, string capList) @safe {
		return createMessage(networkUser, "CAP", nickname, "NAK", capList);
	}
	auto createCapNEW(string nickname, string capList) @safe {
		return createMessage(networkUser, "CAP", nickname, "NEW", capList);
	}
	auto createCapDEL(string nickname, string capList) @safe {
		return createMessage(networkUser, "CAP", nickname, "DEL", capList);
	}
	auto createRPLWelcome(const string nickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 1, format!"Welcome to the %s Network, %s"(networkName, nickname));
	}
	auto createRPLYourHost(const string nickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 2, format!"Your host is %s, running version %s"(serverName, serverVersion));
	}
	auto createRPLCreated(const string nickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 3, format!"This server was created %s"(serverCreatedTime));
	}
	auto createRPLMyInfo(const string nickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 4, serverName, serverVersion, userModes, channelModes);
	}
	auto createRPLISupport(const string nickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 5, "are supported by this server");
	}
	auto createRPLUserhost(const string nickname, const User[] users...) @safe {
		import std.format : format;
		string[] args;
		args.reserve(users.length);
		foreach (user; users) {
			bool isAway = false;
			bool isOper = false;
			args ~= user.mask.nickname ~ (isOper ? "*" : "") ~ "=" ~ (isAway ? "-" : "+") ~ user.mask.ident ~ "@" ~user.mask.host;
		}
		return createNumeric(nickname, 302, args);
	}
	auto createRPLNamreply(const string nickname, const Channel channel) @safe {
		import std.algorithm.iteration : map;
		import std.format : format;
		return createNumeric(nickname, 353, ["=", channel.name, format!"%-(%s %)"(channel.users.map!(x => connections[x].mask.nickname))]);
	}
	auto createRPLEndOfNames(const string nickname, string channel) @safe {
		return createNumeric(nickname, 366, [channel, "End of /NAMES list"]);
	}
	auto createRPLLoggedIn(const string nickname,  UserMask mask, string account) @safe {
		import std.conv : text;
		return createNumeric(nickname, 900, mask.text, account, "You are now logged in as "~account);
	}
	auto createRPLSASLSuccess(const string nickname) @safe {
		import std.conv : text;
		return createNumeric(nickname, 903, "SASL authentication successful");
	}
	auto createERRSASLFail(const string nickname) @safe {
		import std.conv : text;
		return createNumeric(nickname, 904, "SASL authentication failed");
	}
	auto createRPLSASLMechs(const string nickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 908, "PLAIN", "are available SASL mechanisms");
	}
	auto createERRNoSuchChannel(const string nickname, string channel) @safe {
		import std.format : format;
		return createNumeric(nickname, 403, [channel, "No such channel"]);
	}
	auto createERRInvalidCapCmd(const string nickname, string cmd) @safe {
		import std.format : format;
		return createNumeric(nickname, 410, [cmd, "Invalid CAP command"]);
	}
	auto createERRNicknameInUse(const string nickname, string newNickname) @safe {
		import std.format : format;
		return createNumeric(nickname, 433, [newNickname, "Nickname is already in use"]);
	}
	auto createERRNeedMoreParams(const string nickname, string command) @safe {
		import std.format : format;
		return createNumeric(nickname, 461, [command, "Not enough parameters"]);
	}
	auto createNumeric(ref User user, ushort id, string[] args...) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.args = user.mask.nickname~args;
		return createNumericCommon(id, ircMessage);
	}
	auto createNumeric(const string nickname, ushort id, string[] args...) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.args = nickname~args;
		return createNumericCommon(id, ircMessage);
	}
	auto createNumericCommon(const ushort id, IRCMessage message) @safe {
		import std.format : format;
		message.sourceUser = networkUser;
		message.verb = format!"%03d"(id);
		return message;
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
	ircd.init(Settings());
	ircd.addChannel("#test");
}
