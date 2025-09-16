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
	"name": "evently"
}
+/
module examples.evently;

import std.stdio;
import core.time;
import core.thread;
import photon;

enum EVENTS = 1000;

shared Event[EVENTS] events;

void task(int n) {
    go({
        events[n].waitAndReset();
        writeln("Wait is over");
    });
}

void main() {
    initPhoton();
    writeln("Starting a bunch of fibers each waiting on a distinct event");
    foreach (i; 0..EVENTS) {
        events[i] = event(false);
    }
    foreach (i; 0..EVENTS) {
        task(i);
    }
    go({
        delay(1.seconds);
        foreach_reverse (i; 0..EVENTS) {
            events[i].trigger();
        }
    });
    runScheduler();
}
