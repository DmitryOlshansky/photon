/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2025, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for sleeps on Windows",
	"license": "BOOST",
	"name": "issue28"
}
+/
import std.stdio;
import std.range;
import std.concurrency;
import core.thread;

import photon;

void main()
{
	initPhoton;

	go({
		foreach (i; 1000.iota)
		{
			write(".");
			// photon.yield; // hang
			// Thread.sleep(1.nsecs); // broken concurrency
			delay(1.nsecs); // slow
		}
	});

	foreach (i; 32.iota)
	{
		go({ write("#"); });
	}

	runScheduler;
}