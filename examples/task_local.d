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
	"description": "A test for task local storage",
	"license": "BOOST",
	"name": "task_local"
}
+/
version(Windows) {}
else:
import core.atomic;
import photon;

shared int counter = 2;

struct Destructible {
    char field;
    this(char ch) { field = ch; }
    ~this() {
        if (!__ctfe) {
            atomicOp!"-="(counter, 1);
        }
    }
}

TaskLocal!string message;


void main() {
    static TaskLocal!Destructible destructible = Destructible('A');
    initPhoton();
    goOnSameThread({
        assert(message == null);
        message = "Hello, world";
        assert(message == "Hello, world");
        assert(destructible.field == 'A');
        destructible.field = 'B';
        assert(destructible.field == 'B');
    });
    goOnSameThread({
        assert(message == null);
        message = "Huh?";
        assert(message == "Huh?");
        assert(destructible.field == 'A');
        destructible.field = 'C';
        assert(destructible.field == 'C');
    });
    runScheduler();
    assert(counter == 0);
}