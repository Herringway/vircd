import std.stdio;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import vibe.http.websockets;
import vibe.stream.operations;
import vibe.stream.tls;

import vircd.server;

import siryul;

void setupSocket(ref VIRCd instance, const ushort port) @safe {
	auto sslctx = createTLSContext(TLSContextKind.server);
	sslctx.useCertificateChainFile("server.crt");
	sslctx.usePrivateKeyFile("server.key");
	listenTCP(port, delegate void(TCPConnection conn) @safe nothrow {
		try {
			auto stream = createTLSStream(conn, sslctx);
			instance.handleStream(stream, conn.remoteAddress.toAddressString);
		} catch (Exception e) {
			debug logInfo("ERROR: %s", e);
		}
	});
}

void setupWebSocket(ref VIRCd instance, string[] addresses, string[] paths, const ushort port) @safe {
	import vibe.http.router;
	auto dg = delegate void(scope WebSocket socket) {
		instance.handleStream(socket, socket.request.clientAddress.toAddressString);
	};
	auto router = new URLRouter;
	foreach (path; paths) {
		router.get(path, handleWebSockets(dg));
	}
	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = addresses;
	listenHTTP(settings, router);
}

void main() {
	import std.file : exists;
	if (!exists("settings.yml")) {
		toFile!YAML(Settings(), "settings.yml");
		stderr.writeln("Please edit settings.yml");
		return;
	}
	auto settings = fromFile!(Settings, YAML)("settings.yml");
	setLogLevel(settings.verboseLogging ? LogLevel.debugV : LogLevel.info);
	VIRCd instance;
	instance.init(settings);
	runTask({
		setupSocket(instance, settings.tcpPort);
	});
	runTask({
		setupWebSocket(instance, settings.webSocketBindAddresses, settings.webSocketPaths, settings.webSocketPort);
	});
	runEventLoop();
}
