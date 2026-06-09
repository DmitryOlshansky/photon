#!/usr/bin/env dub
/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2026, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
    "description": "A test for select on closed channels",
	"license": "BOOST",
	"name": "select2"
}
+/
module photon.examples.select2;

import std.range, std.datetime, std.stdio;

import photon;

void main() {
    initPhoton();
    auto first = channel!(int)(2);
    auto second = channel!(int)(2);
    first.close();
    second.close();
    go({
        bool[2] channels;
        // test pseudo random selection on closed channels
        while (channels != [true, true]) {
            select(
                first, {
                    channels[0] = true;
                    assert(first.empty);
                },
                second, {
                    channels[1] = true;
                    assert(second.empty);
                }
            );
        }
    });
    runScheduler();
}
