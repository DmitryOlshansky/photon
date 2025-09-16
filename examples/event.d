#!/usr/bin/env dub
/+ dub.json:
    {
	    "name" : "event",
        "dependencies": {
		    "photon": { "path" : ".." }
        }
    }
+/
module examples.event;

import core.thread;
import std.stdio;

import photon;

shared Event ev1, ev2;
enum iterations = 2;

void firstJob() {
    writeln("Wait for the second to trigger the event");
    ev1.waitAndReset();
    writeln("First triggers event for the second");
    ev2.trigger();
    writeln("First is done");
}

void secondJob() {
    writeln("Second triggers event for the first");
    ev1.trigger();
    writeln("Triggered event for the first, now waiting for trigger back");
    ev2.waitAndReset();
    writeln("Second is done");
}

void main() {
    initPhoton();
    ev1 = event(false);
    ev2 = event(false);
    go(&firstJob);
    go(&secondJob);
    runScheduler();
}