module vircd.server;

import std.datetime.systime;

import vibe.core.log;
import vibe.core.stream;
import vibe.http.websockets;
import vibe.stream.operations;

import virc : IRCMessage, Target, UserMask, VIRCChannel = Channel, VIRCUser = User;

struct Client {
	Stream stream;
	WebSocket webSocket;
	bool sentUSER;
	bool sentNICK;
	bool registered;
	bool usingWebSocket;
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
		return sentUSER && sentNICK;
	}
}

struct User {
	string id;
	Client[] clients;
	SysTime connected;
	string defaultHost;
	UserMask mask;
	string realname;
	bool isAnonymous;
	this(string userID, Stream userStream) @safe {
		this(userID, Client(userStream));
	}
	this(string userID, WebSocket socket) @safe {
		this(userID, Client(socket));
	}
	this(string userID, Client client) @safe {
		id = userID;
		clients ~= client;
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
}

struct ServerChannel {
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
	User[string] connections;
	ServerChannel[string] channels;
	string networkName = "Unnamed";
	string serverName = "Unknown";
	string serverVersion = "v0.0.0";
	string networkAddress = "localhost";
	string[] supportedCaps = ["SASL"];
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
		auto userID = uniform!ulong().text;
		auto user = User(userID, client);
		user.defaultHost = address;

		logInfo("User connected: %s/%s", address, userID);

		while (client.hasMoreData) {
			receive(client.receive(), user, client);
		}
		cleanup(userID, "Connection reset by peer");
	}
	void cleanup(string id, string message) @safe {
		if (id in connections) {
			if (connections[id].shouldCleanup) {
				foreach (otherUser; subscribedUsers(Target(VIRCUser(connections[id].mask.nickname)))) {
					sendQuit(*otherUser, connections[id], message);
				}
				if (!connections.remove(id)) {
					logWarn("Could not remove ID from connection list?");
				}
			}
		}
	}
	void receive(string str, ref User thisUser, ref Client thisClient) @safe {
		import virc.ircmessage : IRCMessage;
		auto msg = IRCMessage.fromClient(str);
		switch(msg.verb) {
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
				cleanup(thisUser.id, msg.args.front);
				break;
			case "JOIN":
				if (!thisClient.registered) {
					break;
				}
				void joinChannel(ref ServerChannel channel) @safe {
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
							joinChannel(channels.require(channel, ServerChannel(channel)));
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
	void sendNames(ref User user, const ServerChannel channel) @safe {
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
	void sendRPLNamreply(ref User user, const ServerChannel channel) @safe {
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
