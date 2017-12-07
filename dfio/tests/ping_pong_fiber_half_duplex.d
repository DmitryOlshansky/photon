import std.stdio;
import core.sys.posix.unistd : write, _exit;
import core.sys.posix.sys.types;
import std.socket;
import core.stdc.errno;
import core.sys.posix.sys.socket;
import core.sys.posix.fcntl;
import core.thread;
import core.sys.posix.stdlib: abort;
import dfio;

void check(int code) {
    if(code < 0)
        abort();
}

// if this writes say 100 bytes total
void writer(int fd) {
    stderr.writefln("<started writer, fd = %d>", fd);
    auto s = "simple read write\n";
    write(fd, s.ptr, s.length).checked;
    stderr.writefln("<finished writer>");
}

// it must read the exact same amount (in total) that would be 100 bytes
void reader(int fd) {
    stderr.writefln("<started reader, fd = %d>", fd);
    char[100] buf;
    ssize_t total = 17;
    ssize_t bytes = 0;
    while(bytes < total) {
        ssize_t resp = read(fd, buf.ptr + bytes, total - bytes).checked;
        stderr.writefln("read resp = %s", resp);
        bytes += resp;
    }
    stderr.writefln("<finished reader>");
}

void main() {
   int[2] socks;
   startloop();
   check(socketpair(AF_UNIX, SOCK_STREAM, 0, socks));
   writeln(socks);
   // spawn a thread to run I/O loop
   // spawn thread to write stuff
   auto wr = new Thread(() => reader(socks[0]));
   wr.start();

   // spawn fiber to read stuff
   spawn(() => writer(socks[1]));
   runUntilCompletion();
   //
   wr.join();
}