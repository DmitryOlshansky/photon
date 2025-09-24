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
	"description": "A test for sleep function interception",
	"license": "BOOST",
	"name": "sleepy"
}
+/
module examples.sleepy;

import std.stdio;
import core.time;
import core.thread;
import photon;


void task(string msg, Duration duration) {
    Thread.sleep(duration / 2);
    delay(duration / 2);
    writeln(msg);
}

void main() {
    initPhoton();
    writeln("Starting a bunch of fibers and threads, each waiting 1 second");
    foreach (_; 0..1000) {
        go({
            task("fiber sleep is over", 1.seconds);
        });
    }
    foreach (_; 0..100) {
        new Thread({
            task("thread sleep is over", 1.seconds);
        }).start();
    }
    runScheduler();
}
