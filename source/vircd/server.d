module vircd.server;

import std.datetime.systime;

import vibe.core.log;
import vibe.core.stream;
import vibe.http.websockets;
import vibe.stream.operations;

import virc;

struct Client {
	string id;
	Stream stream;
	WebSocket webSocket;
	SysTime connected;
	string defaultHost;
	UserMask mask;
	string realname;
	bool registered;
	this(string clientID, Stream userStream) @safe {
		id = clientID;
		stream = userStream;
		connected = Clock.currTime;
	}
	this(string clientID, WebSocket socket) @safe {
		id = clientID;
		webSocket = socket;
		connected = Clock.currTime;
	}
	void send(const IRCMessage message) @safe {
		logTrace("Sending message: %s", message.toString());
		if (webSocket) {
			webSocket.send(message.toString());
		}
		if (stream) {
			stream.write(message.toString());
			stream.write("\r\n");
		}
	}
	void disconnect() @safe {
		if (webSocket) {
			webSocket.close();
		}
		if (stream) {
			stream.finalize();
		}
	}
	bool meetsRegistrationRequirements() @safe const {
		return ((mask.ident != "") && (mask.nickname != ""));
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
	Client[string] connections;
	ServerChannel[string] channels;
	string networkName = "Unnamed";
	string serverName = "Unknown";
	string serverVersion = "v0.0.0";
	string networkAddress = "localhost";
	SysTime serverCreatedTime;

	void init() @safe {
		serverCreatedTime = Clock.currTime;
	}

	void handleStream(Stream stream, string address) @safe {
		import std.conv : text;
		import std.random : uniform;
		import std.string : assumeUTF;
		auto clientID = uniform!ulong().text;
		auto client = Client(clientID, stream);
		client.defaultHost = address;
		connections[clientID] = client;

		logInfo("User connected: %s/%s", address, clientID);

		while (!stream.empty) {
			receive(assumeUTF(stream.readUntil(['\r', '\n'], 512)), clientID);
		}
		cleanup(clientID, "Connection reset by peer");
	}
	void handleStream(WebSocket stream, string address) @safe {
		import std.conv : text;
		import std.random : uniform;
		import std.string : assumeUTF;
		auto clientID = uniform!ulong().text;
		auto client = Client(clientID, stream);
		client.defaultHost = address;
		connections[clientID] = client;

		logInfo("User connected: %s/%s", address, clientID);

		while (stream.waitForData()) {
			receive(stream.receiveText(), clientID);
		}
		cleanup(clientID, "Connection reset by peer");
	}
	void cleanup(string id, string message) @safe {
		if (id in connections) {
			foreach (otherClient; subscribedUsers(Target(User(connections[id].mask.nickname)))) {
				sendQuit(*otherClient, connections[id], message);
			}
			connections[id].disconnect();
			if (!connections.remove(id)) {
				logTrace("Could not remove ID from connection list?");
			}
		}
	}
	void receive(string str, string client) @safe {
		import virc.ircmessage : IRCMessage;
		auto thisClient = client in connections;
		auto msg = IRCMessage.fromClient(str);
		switch(msg.verb) {
			case "NICK":
				auto nickname = msg.args.front;
				auto currentNickname = thisClient.mask.nickname;
				if (auto alreadyUsed = getUserByNickname(nickname)) {
					if (alreadyUsed !is thisClient) {
						sendERRNicknameInUse(*thisClient, nickname);
						break;
					}
				}
				if (thisClient.registered) {
					foreach (otherClient; subscribedUsers(Target(User(currentNickname)))) {
						sendNickChange(*otherClient, *thisClient, nickname);
					}
				}
				thisClient.mask.nickname = nickname;
				if (!thisClient.registered && thisClient.meetsRegistrationRequirements) {
					completeRegistration(*thisClient);
				}
				break;
			case "USER":
				auto args = msg.args;
				thisClient.mask.ident = args.front;
				args.popFront();
				const unused = args.front;
				args.popFront();
				const unused2 = args.front;
				args.popFront();
				thisClient.realname = args.front;
				if (!thisClient.registered && thisClient.meetsRegistrationRequirements) {
					completeRegistration(*thisClient);
				}
				break;
			case "QUIT":
				cleanup(client, msg.args.front);
				break;
			case "JOIN":
				void joinChannel(ref ServerChannel channel) @safe {
					channel.users ~= client;
					foreach (otherClient; subscribedUsers(Target(Channel(channel.name)))) {
						sendJoin(*otherClient, *thisClient, channel.name);
					}
					sendNames(*thisClient, channel);
				}
				auto channelsToJoin = msg.args.front.splitter(",");
				foreach (channel; channelsToJoin) {
					final switch (couldUserJoin(*thisClient, channel)) {
						case JoinAttemptResult.yes:
							if (channel[0] != '#') {
								channel = "#"~channel;
							}
							logTrace("%s joining channel %s", client, channel);
							joinChannel(channels.require(channel, ServerChannel(channel)));
							break;
						case JoinAttemptResult.illegalChannel:
							sendERRNoSuchChannel(*thisClient, channel);
							continue;
					}
				}
				break;
			case "PRIVMSG":
				auto args = msg.args;
				auto targets = args.front.splitter(",");
				args.popFront();
				auto message = args.front;
				foreach (target; targets) {
					if (auto user = getUserByNickname(target)) {
						sendPrivmsg(*user, *thisClient, target, message);
					} else {
						if (target in channels) {
							foreach (otherClient; subscribedUsers(Target(Channel(channels[target].name)))) {
								if (otherClient !is thisClient) {
									sendPrivmsg(*otherClient, *thisClient, target, message);
								}
							}
						}
					}
				}
				break;
			case "NOTICE":
				auto args = msg.args;
				auto targets = args.front.splitter(",");
				args.popFront();
				auto message = args.front;
				foreach (target; targets) {
					if (auto user = getUserByNickname(target)) {
						sendNotice(*user, *thisClient, target, message);
					} else {
						if (target in channels) {
							foreach (otherClient; subscribedUsers(Target(Channel(channels[target].name)))) {
								if (otherClient !is thisClient) {
									sendNotice(*otherClient, *thisClient, target, message);
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
	void completeRegistration(ref Client client) @safe {
		client.mask.host = client.defaultHost;
		client.registered = true;
		sendRPLWelcome(client);
		sendRPLYourHost(client);
		sendRPLCreated(client);
		sendRPLMyInfo(client);
		sendRPLISupport(client);
	}
	auto subscribedUsers(Target target) @safe {
		Client*[] result;
		if (target.isChannel) {
			if (target.targetText in channels) {
				foreach (client; channels[target.targetText].users) {
					result ~= client in connections;
				}
			}
		}
		if (target.isUser) {
			string id;
			foreach (client; connections) {
				if (client.mask.nickname == target.targetText) {
					id = client.id;
					break;
				}
			}
			if (id != "") {
				foreach (channel; channels) {
					if (channel.users.canFind(id)) {
						foreach (client; channel.users) {
							result ~= client in connections;
						}
					}
				}
			}
		}
		return result;
	}
	void sendNames(ref Client client, const ServerChannel channel) @safe {
		sendRPLNamreply(client, channel);
		sendRPLEndOfNames(client, channel.name);
	}
	void sendNickChange(ref Client client, const Client subject, string newNickname) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "NICK";
		ircMessage.args = newNickname;
		client.send(ircMessage);
	}
	void sendJoin(ref Client client, ref Client subject, string channel) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "JOIN";
		ircMessage.args = channel;
		client.send(ircMessage);
	}
	void sendQuit(ref Client client, ref Client subject, string msg) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "QUIT";
		ircMessage.args = msg;
		client.send(ircMessage);
	}
	void sendPrivmsg(ref Client client, ref Client subject, string target, string message) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "PRIVMSG";
		ircMessage.args = [target, message];
		client.send(ircMessage);
	}
	void sendNotice(ref Client client, ref Client subject, string target, string message) @safe {
		import std.conv : text;
		auto ircMessage = IRCMessage();
		ircMessage.source = subject.mask.text;
		ircMessage.verb = "NOTICE";
		ircMessage.args = [target, message];
		client.send(ircMessage);
	}
	void sendRPLWelcome(ref Client client) @safe {
		import std.format : format;
		sendNumeric(client, 1, format!"Welcome to the %s Network, %s"(networkName, client.mask.nickname));
	}
	void sendRPLYourHost(ref Client client) @safe {
		import std.format : format;
		sendNumeric(client, 2, format!"Your host is %s, running version %s"(serverName, serverVersion));
	}
	void sendRPLCreated(ref Client client) @safe {
		import std.format : format;
		sendNumeric(client, 3, format!"This server was created %s"(serverCreatedTime));
	}
	void sendRPLMyInfo(ref Client client) @safe {
		import std.format : format;
		sendNumeric(client, 4, format!"%s %s %s"(serverName, serverVersion, "abcdefghijklmnopqrstuvwxyz"));
	}
	void sendRPLISupport(ref Client client) @safe {
		import std.format : format;
		sendNumeric(client, 5, "are supported by this server");
	}
	void sendRPLNamreply(ref Client client, const ServerChannel channel) @safe {
		import std.algorithm.iteration : map;
		import std.format : format;
		sendNumeric(client, 353, ["=", channel.name, format!"%-(%s %)"(channel.users.map!(x => connections[x].mask.nickname))]);
	}
	void sendRPLEndOfNames(ref Client client, string channel) @safe {
		import std.format : format;
		sendNumeric(client, 366, [channel, "End of /NAMES list"]);
	}
	void sendERRNoSuchChannel(ref Client client, string channel) @safe {
		import std.format : format;
		sendNumeric(client, 403, [channel, "No such channel"]);
	}
	void sendERRNicknameInUse(ref Client client, string nickname) @safe {
		import std.format : format;
		sendNumeric(client, 433, [nickname, "Nickname is already in use"]);
	}
	void sendNumeric(ref Client client, ushort id, string[] args) @safe {
		import std.format : format;
		auto ircMessage = IRCMessage();
		ircMessage.source = networkAddress;
		ircMessage.verb = format!"%03d"(id);
		ircMessage.args = client.mask.nickname~args;
		client.send(ircMessage);
	}
	void sendNumeric(ref Client client, ushort id, string arg) @safe {
		import std.format : format;
		auto ircMessage = IRCMessage();
		ircMessage.source = networkAddress;
		ircMessage.verb = format!"%03d"(id);
		ircMessage.args = [client.mask.nickname, arg];
		client.send(ircMessage);
	}
	Client* getUserByNickname(string nickname) @safe {
		foreach (id, client; connections) {
			if (client.mask.nickname == nickname) {
				return id in connections;
			}
		}
		return null;
	}
	enum JoinAttemptResult {
		yes,
		illegalChannel
	}
	auto couldUserJoin(ref Client client, string channel) @safe {
		return JoinAttemptResult.yes;
	}
}