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
    "description": "A test for select over channels API",
	"license": "BOOST",
	"name": "select"
}
+/
module examples.select;

import std.range, std.datetime, std.stdio;

import photon;

void main() {
    initPhoton();
    auto first = channel!(int)(2);
    auto second = channel!(string)(1);
    go({
        delay(500.msecs);
        first.put(0);
        first.put(1);
        delay(500.msecs);
        second.put("ping");
    });
    go({
        select(
            first, { 
                assert(false);
            },
            second, {
                assert(false);
            },
            { // default
                writefln("Got default");
            }
        );
        foreach ( _; 0..3) {
            select(
                first, { 
                    writefln("Got first %s", first.take(1));
                },
                second, {
                    writefln("Got second %s", second.take(1));
                }
            );
        }
    });
    runScheduler();
}
