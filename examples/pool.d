/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for pool API",
	"license": "BOOST",
	"name": "pool"
}
+/
module examples.pool;

import core.atomic, core.time;
import std.stdio;
import photon;


void main() {
    initPhoton();
    shared int active;
    shared int closed;
    auto counts = pool(2, 1.seconds, () => atomicFetchAdd(active, 1), (ref int i) { atomicFetchAdd(closed, 1); });
    go({
        auto first = counts.acquire();
        writeln("acquire: ", first.get);
        auto second = counts.acquire();
        writeln("acquire: ", second.get);
        go({
            delay(1.seconds);
            counts.release(first);
            writeln("closed:", closed);
        });
        auto third = counts.acquire();
        writeln("acquire:", third.get);
        counts.dispose(third); // now we have allocated == 1 and empty free list
        writeln("closed: ", closed);
        auto fourth = counts.acquire(); // so this should allocate new connection
        writeln("acquire: ", fourth.get);
        counts.release(fourth);
        counts.release(second);
        delay(2.seconds); // give time for the cleaner to cleanup stale connections
        writeln("closed: ", 3);
        auto fifth = counts.acquire();
        writeln("acquire: ", fifth.get);
        counts.shutdown();
        writeln("after shutdown");
    });
    runScheduler();
}
