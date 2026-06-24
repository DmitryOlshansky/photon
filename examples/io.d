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
import std.stdio;
import photon;

version(Windows) {
import std.file : tempDir;
import std.path : buildPath;
import std.random;
import std.string;
import std.conv;

void main() {
    initPhoton();
    goOnSameThread({
        try {
            writeln("Starting to read/write");
            read_write(0);
            writeln("Done read/write");
        } catch (Throwable t) {
            writeln(t);
        }
    });
    goOnSameThread({
        writeln("Starting to read/write #2");
        read_write(1);
        writeln("Done read/write #2");
    });
    goOnSameThread({
        writeln("Starting to read/write #3");
        read_write(2);
        writeln("Done read/write #3");
    });
    runScheduler();
}

void read_write(int id) {
    auto dir = tempDir;
    auto name = "read_write_ " ~ to!string(id) ~ "_" ~ to!string(uniform!ulong) ~ ".tmp";
    auto path = buildPath(dir, name);
    int handle = open(path.toStringz, O_RDWR | O_CREAT, octal!777);
    scope(exit) std.file.remove(path);
    assert(handle >= 0);
    scope(exit) close(handle);
    enum SIZE = 1<<20;
    ubyte[] data = new ubyte[SIZE];
    data[] = 0x55;
    int ret = ftruncate(handle, SIZE);
    assert(ret >= 0);
    foreach (_; 0..100) {
        ret = cast(int)pwrite(handle, data.ptr, data.length, 0);
        assert(ret >= 0);
        data[] = 0xAA;
        ret = cast(int)pread(handle, data.ptr, data.length, 0);
        assert(ret >= 0);
        foreach (i; 0..data.length) {
            assert(data[i] == 0x55);
        }
    }
}

} else:
import core.sys.posix.unistd;

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