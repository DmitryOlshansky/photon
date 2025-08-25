module photon.macos.support;
version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;
version(Darwin):
import core.sys.posix.unistd;
import core.stdc.errno;
import core.stdc.stdlib;
import core.thread;
import core.stdc.config;
import core.sys.posix.pthread;
import core.sys.darwin.sys.event;

enum int MSG_DONTWAIT = 0x80;
alias off_t = long;
alias quad_t = ulong;
extern(C) nothrow off_t __syscall(quad_t number, ...);
extern(C) void perror(const(char) *s) nothrow;

T checked(T: ssize_t)(T value, const char* msg="unknown place") nothrow {
    if (value < 0) {
        perror(msg);
        _exit(cast(int)-value);
    }
    return value;
}

void logf(string file = __FILE__, int line = __LINE__, T...)(string msg, T args)
{
    debug(photon) {
        try {
            import std.stdio;
            stderr.writefln(msg, args);
            stderr.writefln("\tat %s:%s:[LWP:%s]", file, line, pthread_self());
        }
        catch(Throwable t) {
            abort();
        }
    }
}

