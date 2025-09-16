import std.stdio;
import core.sys.posix.unistd : write, _exit;
import core.sys.posix.sys.types;
import core.memory;
import std.socket;
import core.stdc.errno;
import core.stdc.string;
import std.string;
import std.getopt;
import core.sys.posix.sys.socket;
import core.sys.posix.fcntl;
import core.thread;
import core.time;
import core.sys.posix.stdlib: abort;
static import core.sys.posix.unistd;
import std.conv : to;
import photon;
import photon.support;

void check(int code) {
    if(code < 0)
        abort();
}

// if this writes say 100 bytes total
void writerReader(int fd, string toSend, string toRecv) {
    logf("<started writerReader, fd = %d>", fd);
    auto s = "simple read write\n";
    write(fd, toSend.ptr, toSend.length).checked;

    logf("<midway writerReader, fd = %d>", fd);

    char[100] buf2 = 0;
    ssize_t total = toRecv.length;
    ssize_t bytes = 0;
    while(bytes < total) {
        ssize_t resp = core.sys.posix.unistd.read(fd, buf2.ptr + bytes, total - bytes).checked;
        logf("read1 resp = %s", resp);
        bytes += resp;
    }

    assert(cmp(fromStringz(buf2.ptr), toRecv) == 0);

    logf("<finished writerReader, fd = %d>", fd);
}

// it must read the exact same amount (in total) that would be 100 bytes
void readerWriter(int fd, string toSend, string toRecv) {
    logf("<started readerWriter, fd = %d>", fd);
    char[100] buf = 0;
    ssize_t total = toRecv.length;
    ssize_t bytes = 0;
    while(bytes < total) {
        ssize_t resp = core.sys.posix.unistd.read(fd, buf.ptr + bytes, total - bytes).checked;
        logf("read2 resp = %s", resp);
        bytes += resp;
    }

    assert(cmp(fromStringz(buf.ptr), toRecv) == 0);
    logf("<midway readerWriter, fd = %d>", fd);

    auto s = "simple read write\n";
    char[] buf2 = s.dup;
    write(fd, toSend.ptr, toSend.length).checked;
    logf("<finished readerWriter, fd = %d>", fd);
}

Thread threadPingPong(int fd, string toSend, string toRecv) {
    return new Thread(() => writerReader(fd, toSend, toRecv));
}

void fiberPongPing(int fd, string toSend, string toRecv) {
    go(() => readerWriter(fd, toSend, toRecv));
}

void main(string[] args) {
    int NR;
    getopt(args,
        "count", &NR);
    int[][] socks = new int[][](NR, 2);
    string s1 = "first read write\n";
    string s2 = "second read write\n";
    initPhoton();
    for(int i = 0; i < NR; i++) {
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, socks[i].ptr[0..2]));
        //logf("socks[i] = %s", i, socks[i]);
    }

    logf("socks = %s", socks);
    // spawn a thread to run I/O loop
    // spawn thread to write stuff
    Thread[] wrs;
    for(int i = 0; i < NR; i ++) {
        auto a = socks[i][0];
        auto wr = threadPingPong(a, s2, s1);
        logf("wr = %s", cast(void*)wr);
        wr.start();
        wrs ~= wr;
    }

    // spawn fiber to read stuff
    for(int i = 0; i < NR; i++) {
        logf("socks[i][1] = %d", socks[i][1]);
        auto a = socks[i][1];
        fiberPongPing(a, s1, s2);
    }
    runScheduler();
    //
    foreach(w; wrs) {
        w.join();
    }
}
