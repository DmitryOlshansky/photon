#!/usr/bin/env dub
/+ dub.json:
    {
        "name" : "hello",
        "dependencies": {
            "photon": { "path" : "../.." },
            "photon-http": "0.5.5"
        }
    }
+/
import std.stdio;
import std.socket;

import photon, photon.http;

class HelloWorldProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "text/plain; charset=utf-8")];

    this(Socket sock){ super(sock); }

    override void handle(HttpRequest req) {
        respondWith("Hello, world!", 200, headers);
    }
}

void server_worker(Socket client) {
    scope processor =  new HelloWorldProcessor(client);
    try {
        processor.run();
    }
    catch(Exception e) {
        stderr.writeln(e);
    }
}

void server() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("0.0.0.0", 8080));
    server.listen(1000);

    debug writeln("Started server");

    void processClient(Socket client) {
        go(() => server_worker(client));
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
    startloop();
    go(() => server());
    runFibers();
}
