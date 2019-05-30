module vircd.server;

import std.datetime.systime;

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
	this(WebSocket socket) @safe {
		usingWebSocket = true;
		webSocket = socket;
	}
	this(Stream socket) @safe {
		usingWebSocket = false;
		stream = socket;
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
	string defaultHost;
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
			client.send(message);
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
	Capability[] supportedCaps = [
		Capability("cap-notify", "")
	];
	SysTime serverCreatedTime;

	void init() @safe {
		serverCreatedTime = Clock.currTime;
	}

	void handleStream(Stream stream, string address) @safe {
		handleStream(Client(stream), address);
	}
	void handleStream(WebSocket stream, string address) @safe {
		handleStream(Client(stream), address);
	}
	void handleStream(Client client, string address) @safe {
		import std.conv : text;
		import std.random : uniform;
		auto randomID = uniform!ulong().text;
		client.id = randomID;
		auto user = new User(randomID, client);
		user.defaultHost = address;

		logInfo("User connected: %s/%s", address, randomID);

		while (client.hasMoreData) {
			receive(client.receive(), *user, client);
			if (user.id != randomID) {
				user = user.id in connections;
				client = user.clients[randomID];
			}
		}
		cleanup(user.id, randomID, "Connection reset by peer");
	}
	void cleanup(string id, string clientID, string message) @safe {
		logInfo("Client disconnected: %s: %s", id, message);
		if (id in connections) {
			connections[id].clients.remove(clientID);
			if (connections[id].shouldCleanup) {
				foreach (otherUser; subscribedUsers(Target(VIRCUser(connections[id].mask.nickname)))) {
					sendQuit(*otherUser, connections[id], message);
				}
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
					foreach (otherUser; subscribedUsers(Target(VIRCUser(currentNickname)))) {
						sendNickChange(*otherUser, thisUser, nickname);
					}
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
					foreach (otherUser; subscribedUsers(Target(VIRCChannel(channel.name)))) {
						sendJoin(*otherUser, thisUser, channel.name);
					}
					sendNames(thisUser, channel);
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
				auto targets = args.front.splitter(",");
				args.popFront();
				auto message = args.front;
				foreach (target; targets) {
					if (auto user = getUserByNickname(target)) {
						sendPrivmsg(*user, thisUser, target, message);
					} else {
						if (target in channels) {
							foreach (otherUser; subscribedUsers(Target(VIRCChannel(channels[target].name)))) {
								if (otherUser.id != thisUser.id) {
									sendPrivmsg(*otherUser, thisUser, target, message);
								}
							}
						}
					}
				}
				break;
			case "NOTICE":
				if (!thisClient.registered) {
					break;
				}
				auto args = msg.args;
				auto targets = args.front.splitter(",");
				args.popFront();
				auto message = args.front;
				foreach (target; targets) {
					if (auto user = getUserByNickname(target)) {
						sendNotice(*user, thisUser, target, message);
					} else {
						if (target in channels) {
							foreach (otherUser; subscribedUsers(Target(VIRCChannel(channels[target].name)))) {
								if (otherUser.id != thisUser.id) {
									sendNotice(*otherUser, thisUser, target, message);
								}
							}
						}
					}
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
		user.mask.host = user.defaultHost;
		client.registered = true;
		connections.require(user.id, user);
		connections[user.id].clients[user.randomID] = client;
		sendRPLWelcome(client, user.mask.nickname);
		sendRPLYourHost(client, user.mask.nickname);
		sendRPLCreated(client, user.mask.nickname);
		sendRPLMyInfo(client, user.mask.nickname);
		sendRPLISupport(client, user.mask.nickname);
	}
	auto subscribedUsers(Target target) @safe {
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
			}
		}
		return result;
	}
	void sendNames(ref User user, const Channel channel) @safe {
		sendRPLNamreply(user, channel);
		sendRPLEndOfNames(user, channel.name);
	}
	void sendNickChange(ref User user, const User subject, string newNickname) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "NICK";
		ircMessage.args = newNickname;
		user.send(ircMessage);
	}
	void sendJoin(ref User user, ref User subject, string channel) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "JOIN";
		ircMessage.args = channel;
		user.send(ircMessage);
	}
	void sendQuit(ref User user, ref User subject, string msg) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "QUIT";
		ircMessage.args = msg;
		user.send(ircMessage);
	}
	void sendPrivmsg(ref User user, ref User subject, string target, string message) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "PRIVMSG";
		ircMessage.args = [target, message];
		user.send(ircMessage);
	}
	void sendNotice(ref User user, ref User subject, string target, string message) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "NOTICE";
		ircMessage.args = [target, message];
		user.send(ircMessage);
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
			auto ircMessage = IRCMessage();
			ircMessage.source = networkAddress;
			ircMessage.verb = "CAP";
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
			ircMessage.args = args;
			client.send(ircMessage);
			capsToSend = capsToSend[numCaps .. $];
		} while(!capsToSend.empty);
	}
	void sendCapACK(ref Client client, string nickname, string capList) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.source = networkAddress;
		ircMessage.verb = "CAP";
		ircMessage.args = [nickname, "ACK", capList];
		client.send(ircMessage);
	}
	void sendCapNAK(ref Client client, string nickname, string capList) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.source = networkAddress;
		ircMessage.verb = "CAP";
		ircMessage.args = [nickname, "NAK", capList];
		client.send(ircMessage);
	}
	void sendCapNEW(ref User user, string capList) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.source = networkAddress;
		ircMessage.verb = "CAP";
		ircMessage.args = [user.mask.nickname, "NEW", capList];
		user.send(ircMessage);
	}
	void sendCapDEL(ref User user, string capList) @safe {
		auto ircMessage = IRCMessage();
		ircMessage.source = networkAddress;
		ircMessage.verb = "CAP";
		ircMessage.args = [user.mask.nickname, "NEW", capList];
		user.send(ircMessage);
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
		sendNumeric(client, nickname, 4, format!"%s %s %s"(serverName, serverVersion, "abcdefghijklmnopqrstuvwxyz"));
	}
	void sendRPLISupport(ref Client client, const string nickname) @safe {
		import std.format : format;
		sendNumeric(client, nickname, 5, "are supported by this server");
	}
	void sendRPLNamreply(ref User user, const Channel channel) @safe {
		import std.algorithm.iteration : map;
		import std.format : format;
		sendNumeric(user, 353, ["=", channel.name, format!"%-(%s %)"(channel.users.map!(x => connections[x].mask.nickname))]);
	}
	void sendRPLEndOfNames(ref User user, string channel) @safe {
		import std.format : format;
		sendNumeric(user, 366, [channel, "End of /NAMES list"]);
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
		message.source = networkAddress;
		message.verb = format!"%03d"(id);
		target.send(message);
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
