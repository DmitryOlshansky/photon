#!/usr/bin/env dub
/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A simple use of ready channel primitive",
	"license": "BOOST",
	"name": "ready"
}
+/
module examples.ready;

import core.time;
import std.stdio;
import photon;

void main() {
    initPhoton();
    auto ch = channel!int(2);
    assert(!ch.ready);
    ch.put(42);
    assert(ch.ready);
    assert(ch.front == 42); // ready implies !empty but without blocking
    ch.popFront();
    assert(!ch.ready);
    go({
        for (int i = 0; i < 5; i++) {
            delay(1.msecs); // do some large work
            ch.put(i);
        }
    });
    go({
        for (int i = 0; i < 5; i++) {
            while(!ch.ready()) {
                stderr.write("*"); // signify waiting
                delay(1.usecs); // do some other short work
            }
            stderr.write(ch.front);
            ch.popFront();
        }
    });
    runScheduler();
}