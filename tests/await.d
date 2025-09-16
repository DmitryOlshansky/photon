/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for awaitAny API",
	"license": "BOOST",
	"name": "channels"
}
+/
module tests.await;

import std.stdio, std.datetime;
import photon;

void main(){
    initPhoton();
    auto e = event(false);
    auto s = semaphore(0);
    go({
        delay(1.seconds);
        e.trigger();
        delay(1.seconds);
        s.trigger(1);
    });
    go({ // awaiter
        auto n = awaitAny(e, s);
        assert(n == 0);
        writeln("Await ", n);
        delay(3.seconds);
        n = awaitAny(e, s);
        assert(n == 1);
        writeln(n);
        writeln("Await ", n);

    });
    runScheduler();
}