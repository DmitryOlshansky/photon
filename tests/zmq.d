#!/usr/bin/env dub
/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." },
        "zmqd": "1.3.0"
	},
	"description": "A test for ZeroMQ interop",
	"license": "BOOST",
	"name": "zmq"
}
+/
import std.stdio;
import zmqd;
import photon;
import core.thread;

void main()
{
	initPhoton();
	shared bool terminated = false;
	go({
    	//  Socket to talk to clients
		auto responder = Socket(SocketType.rep);
		writeln("Got socket");
		responder.bind("tcp://*:5555");
		writeln("Binded socket");

		while (!terminated) {
			ubyte[10] buffer;
			responder.receive(buffer);
			writefln("Received: \"%s\"", cast(string)buffer);
			Thread.sleep(1.seconds);
			responder.send("World");
		}
	});
	go({
		writeln ("Connecting to hello world server...");
		auto requester = Socket(SocketType.req);
		requester.connect("tcp://localhost:5555");

		foreach (int requestNbr; 0..10)
		{
			ubyte[10] buffer;
			writefln("Sending Hello #%s", requestNbr);
			if (requestNbr == 9) terminated = true;
			requester.send("Hello");
			requester.receive(buffer);
			writefln("Received: %s #%s", cast(string)buffer, requestNbr);
		}
	});
	runScheduler();
}