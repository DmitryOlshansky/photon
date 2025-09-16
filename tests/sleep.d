/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for thread sleep and fiber sleep API",
	"license": "BOOST",
	"name": "sleep"
}
+/
module tests.await;

import std.stdio, std.datetime;
import photon;

void main(){
    initPhoton();
    auto e = event(false);
    auto s = semaphore(0);
    delay(1.seconds);
    go({
        delay(1.seconds);
    });
    go({
        delay(1.seconds);
    });
    runScheduler();
}