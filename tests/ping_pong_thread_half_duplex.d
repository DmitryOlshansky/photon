import std.stdio;
import core.sys.posix.unistd : write, _exit;
import core.sys.posix.sys.types;
import std.socket;
import core.stdc.errno;
import core.sys.posix.sys.socket;
import core.sys.posix.fcntl;
import core.thread;
import core.sys.posix.stdlib: abort;
import photon;

void check(int code) {
    if(code < 0)
        abort();
}

// if this writes say 100 bytes total
void writer(int fd) {
    logf("<started writer, fd = %d>", fd);
    auto s = "simple read write\n";
    write(fd, s.ptr, s.length).checked;
    logf("<finished writer>");
}

// it must read the exact same amount (in total) that would be 100 bytes
void reader(int fd) {
    logf("<started reader, fd = %d>", fd);
    char[100] buf;
    ssize_t total = 17;
    ssize_t bytes = 0;
    while(bytes < total) {
        ssize_t resp = core.sys.posix.unistd.read(fd, buf.ptr + bytes, total - bytes).checked;
        logf("read resp = %s", resp);
        bytes += resp;
    }
    logf("<finished reader>");
}

void main() {
   int[2] socks;
   initPhoton();
   check(socketpair(AF_UNIX, SOCK_STREAM, 0, socks));
   logf("socks = %s", socks);
   // spawn a thread to run I/O loop
   // spawn thread to write stuff
   auto wr = new Thread(() => writer(socks[0]));
   wr.start();

   // spawn fiber to read stuff
   go(() => reader(socks[1]));
   runScheduler();
   //
   wr.join();
}
