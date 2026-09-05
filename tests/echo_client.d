/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"description": "Echo client - a simple client that sends plain data and recvs echos back",
	"license": "BOOST",
	"name": "echo_client"
}
+/
// Simple client provided to use with echo_server
// each line typed is sent to the server, followed by receive to print the response
module tests.echo_client;

import std.conv;
import std.socket;
import std.stdio;

int main(string[] argv) {
    if (argv.length != 3) {
        stderr.writeln("Usage: ./echo_client <host> <port>");
        return 1;
    }
    auto host = argv[1];
    auto port = to!ushort(argv[2]);
    auto target = new InternetAddress(host, port);
    Socket sock = new TcpSocket();
    sock.connect(target);
    string line;
    char[256] buf=void;
    for (;;) {
        line = readln();
        sock.send(line);
        auto res = sock.receive(buf[]);
        if (res == 0) return 0;
        else if(res < 0) {
            return 1;
        }
        else {
            writeln(buf[0..res]);
        }
    }
}