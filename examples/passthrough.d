/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2026, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for passthrough behavior of Photon",
	"license": "BOOST",
	"name": "passthrough"
}
+/
module examples.passthrough;

import std.socket;
import photon;
import std.stdio;
enum PORT = 9090;

void main() {
    // we want to make sure that no state is "leaking" out of schedulers
    initPhoton();
    goOnAllThreads(() {}); // make sure each scheduler had at least one fiber
    runScheduler(); 
    auto ct = new Thread(&client);
    ct.start();
    scope(exit) ct.join();
    server();
}

void server() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("127.0.0.1", PORT));
    server.listen(1000);
    auto sock = server.accept();
    ubyte[32] buf;
    auto r = sock.receive(buf[]);
    assert(cast(char[])buf[0..r] == "hello");
    sock.send("goodbye");
    sock.shutdown(SocketShutdown.BOTH);
    sock.close();
}

void client() {
    Thread.sleep(1.seconds);
    auto target = new InternetAddress("127.0.0.1", PORT);
    Socket sock = new TcpSocket();
    ubyte[32] buf;
    sock.connect(target);
    sock.send("hello");
    auto res = sock.receive(buf[]);
    assert(cast(char[])buf[0..res] == "goodbye");
    sock.shutdown(SocketShutdown.BOTH);
    sock.close();
}