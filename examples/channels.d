/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for channels API",
	"license": "BOOST",
	"name": "channels"
}
+/
module examples.channels;

import std.algorithm, std.datetime, std.range, std.stdio;
import photon;

void first(shared Channel!string work, shared Channel!int completion) {
    delay(2.msecs);
    work.put("first #1");
    delay(2.msecs);
    work.put("first #2");
    delay(2.msecs);
    work.put("first #3");
    completion.put(1);
}

void second(shared Channel!string work, shared Channel!int completion) {
    delay(3.msecs);
    work.put("second #1");
    delay(3.msecs);
    work.put("second #2");
    completion.put(2);
}

void main() {
    initPhoton();
    auto jobQueue = channel!string(2);
    auto finishQueue = channel!int(1);
    go({
        first(jobQueue, finishQueue);
    });
    go({ // producer # 2
        second(jobQueue, finishQueue);
    });
    go({ // consumer
        foreach (item; jobQueue) {
            delay(1.seconds);
            writeln(item);
        }
    });
    go({ // closer
        auto completions = finishQueue.take(2).array;
        assert(completions.length == 2);
        jobQueue.close(); // all producers are done
    });
    runScheduler();
}

