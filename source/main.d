import std.stdio;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import vibe.http.websockets;
import vibe.stream.operations;
import vibe.stream.tls;

import vircd.server;

void setupSocket(ref VIRCd instance) {
	auto sslctx = createTLSContext(TLSContextKind.server);
	sslctx.useCertificateChainFile("server.crt");
	sslctx.usePrivateKeyFile("server.key");
	listenTCP(6697, delegate void(TCPConnection conn) @trusted nothrow {
		try {
			auto stream = createTLSStream(conn, sslctx);
			instance.handleStream(stream, conn.remoteAddress.toAddressString);
		} catch (Throwable e) {
			logInfo("ERROR: %s", e);
		}
	});
}

void setupWebSocket(ref VIRCd instance) {
	import vibe.http.router;
	auto router = new URLRouter;
	router.get("/irc", handleWebSockets(delegate void(scope WebSocket socket) {
		instance.handleStream(socket, socket.request.clientAddress.toAddressString);
	}));
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	listenHTTP(settings, router);
}

void main() {
	VIRCd instance;
	instance.init();
	runTask({
		setupSocket(instance);
	});
	runTask({
		setupWebSocket(instance);
	});
	runEventLoop();
}
