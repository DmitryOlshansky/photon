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
	"description": "A test for file read/write thread offload",
	"license": "BOOST",
	"name": "io"
}
+/
version(Windows) {

void main() {

}

} else:
import std.stdio;
import core.sys.posix.unistd;
import photon;

void read_a_lot() {
    ubyte[] buf = new ubyte[2^^20];
    int file = open("/dev/zero", O_RDONLY);
    scope(exit) close(file);
    foreach (_; 0..16_000) {
        read(file, buf.ptr, buf.length);
    }
}

void main() {
    initPhoton();
    go({
        goOnSameThread({
            writeln("Starting to read a lot");
            read_a_lot();
            writeln("Done reading a lot");
        });
        goOnSameThread({
            writeln("Starting to read a lot #2");
            read_a_lot();
            writeln("Done reading a lot #2");
        });
        goOnSameThread({
            writeln("Starting to read a lot #3");
            read_a_lot();
            writeln("Done reading a lot #3");
        });
    });
    runScheduler();
}