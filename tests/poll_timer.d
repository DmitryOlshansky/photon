module poll_test;
import std.stdio;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : read, write, _exit;
import core.sys.posix.sys.types;
import core.stdc.errno;
import core.sys.posix.sys.socket;
import core.thread;
import core.sys.posix.stdlib: abort;
import core.sys.posix.poll;
import core.sys.posix.fcntl;
import photon;
import photon.linux.support;
import photon.linux.syscalls;

shared int idx = 0;

void check(int code) {
    if(code < 0)
        abort();
}

void writer(int fd) {
    writefln("<started writer, fd = %d>", fd);
    auto s = "wait and write\n";
    for (int i = 0; i <  30; ++i) {
        logf("writer idx = %d", i);
        idx = i;
        ssize_t rc = write(fd, s.ptr, s.length).checked("write fail");
        logf("write rc = %d", rc);
        Thread.sleep(1.seconds);
    }
    logf("<finished writer>");
}

void reader(int fd) {
    logf("<started reader, fd = %d>", fd);
    char[100] buf;
    ssize_t total = 15;
    int timeout = 2000;
    bool finished = false;
    pollfd fds;
    fds.fd = fd;
    fds.events = POLLIN;
    fds.revents = 0;
    do {
        int rc = poll(&fds, 1, timeout).checked("poll");
        logf("rc = %d", rc);
        if (rc == 0) continue;
        if (idx == 29) finished = true;
        //logf("preparing to read");
        ssize_t resp = read(fds.fd, buf.ptr, total).checked("read fail");
        logf("read resp = %s", resp);
    } while(!finished);
    logf(" <finished reader>");
}

void main(){
   int[2] socks;

   initPhoton();
   socketpair(AF_UNIX, SOCK_STREAM, 0, socks).checked("here");
   logf("socks = %s", socks);
   auto wr = new Thread(() => writer(socks[0]));
   wr.start();

   spawn(() => reader(socks[1]));
   runScheduler();

   wr.join();
}
