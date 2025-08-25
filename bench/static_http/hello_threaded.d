#!/usr/bin/env dub
/+ dub.json:
    {
	    "name" : "hello-threaded",
        "dependencies": {
            "photon-http": "~>0.4.5"
        }
    }
+/
import std.stdio;
import std.socket;
import core.thread;

import photon.http;

class HelloWorldProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "text/plain; charset=utf-8")];

    this(Socket sock){ super(sock); }

    override void handle(HttpRequest req) {
        respondWith("Hello, world!", 200, headers);
    }
}

void server_worker(Socket client) {
    scope processor =  new HelloWorldProcessor(client);
    processor.run();
}

void server() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("0.0.0.0", 8080));
    server.listen(1000);

    debug writeln("Started server");

    void processClient(Socket client) {
        new Thread(() => server_worker(client)).start();
    }

    while(true) {
        try {
            debug writeln("Waiting for server.accept()");
            Socket client = server.accept();
            debug writeln("New client accepted");
            processClient(client);
        }
        catch(Exception e) {
            writefln("Failure to accept %s", e);
        }
    }
}

void main() {
    new Thread(() => server()).start();
}
