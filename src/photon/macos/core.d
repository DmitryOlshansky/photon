module photon.macos.core;
version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;
version(Darwin):
package(photon):

import std.string;
import std.format;
import std.exception;
import std.conv;
import std.array;
import std.meta;
import std.random;
import std.concurrency;

import core.thread;
import core.internal.spinlock;
import core.sys.posix.sys.types;
import core.sys.posix.sys.socket;
import core.sys.posix.poll;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd;
import core.sync.mutex;
import core.stdc.errno;
import core.stdc.signal;
import core.stdc.time;
import core.stdc.stdlib;
import core.atomic;
import core.sys.posix.stdlib: abort;
import core.sys.posix.fcntl;
import core.memory;
import core.sys.posix.sys.mman;
import core.sys.posix.pthread;
import core.sys.darwin.sys.event;
import core.sys.darwin.dlfcn;
import core.sys.darwin.mach.thread_act;

import photon.macos.support;
import photon.reactor;

alias KEvent = kevent_t;

enum SYS_READ = 3;
enum SYS_WRITE = 4;
enum SYS_ACCEPT = 30;
enum SYS_CONNECT = 98;
enum SYS_SENDTO = 133;
enum SYS_RECVFROM = 29;
enum SYS_CLOSE = 6;
enum SYS_GETTID = 286;
enum SYS_POLL = 230;

immutable size_t pageSize;

shared static this() {
    pageSize = sysconf(_SC_PAGESIZE);
}

shared struct RawEvent {
nothrow:
    this(int dummy) {
        int[2] fds;
        pipe(fds).checked("event creation");
        this.fds  = fds;
    }

    void waitAndReset() {
        byte[1] bytes = void;
        ssize_t r;
        do {
            r = raw_read(fds[0], bytes.ptr, 1);
        } while(r < 0 && errno == EINTR);
        r.checked("event reset");
    }
    
    void trigger() { 
        ubyte[1] bytes;
        ssize_t r;
        do {
            r = raw_write(fds[1], bytes.ptr, 1);
        } while(r < 0 && errno == EINTR);
        r.checked("event trigger");
    }

    void close() {
        .close(fds[0]);
        .close(fds[1]);
    }
    
    private int[2] fds;
}

public struct Timer {
    alias Callback = void delegate() @safe nothrow;
    void wait(Duration d) {
        delay(d);
    }
    void stop() nothrow {}
    bool pending() nothrow { return false; }
    void rearm(Duration dur) nothrow {}
}

///
public auto timer() {
    return Timer();
}

public struct Event {
nothrow:
    @disable this(this);

    this(bool signaled) {
        int[2] fds;
        pipe(fds).checked("pipe creation for event");
        if (signaled) trigger();
        this.fds = fds;
    }

    package(photon) int fd() shared { return fds[0]; }

    package(photon) int fd() { return fds[0]; }

    /// Wait for the event to be triggered, then reset and return atomically
    void waitAndReset() {
        byte[4096] bytes = void;
        ssize_t r;
        do {
            r = read(fds[0], bytes.ptr, bytes.sizeof);
        } while(r < 0 && errno == EINTR);
    }

    void waitAndReset() shared {
        this.unshared.waitAndReset();
    }

    package(photon) void reset() {
        waitAndReset();
    }

    package(photon) void reset() shared {
        waitAndReset();
    }
    
    /// Trigger the event.
    void trigger() { 
        ubyte[1] bytes = void;
        ssize_t r;
        do {
            r = write(fds[1], bytes.ptr, 1);
        } while(r < 0 && errno == EINTR);
    }

    void trigger() shared {
        this.unshared.trigger();
    }

    ///
    void dispose() {
        close(fds[0]);
        close(fds[1]);
    }

    void dispose() shared {
        this.unshared.dispose();
    }

    private int[2] fds;
}

///
public nothrow auto event(bool signaled) {
    return cast(shared)Event(signaled);
}


public struct Semaphore {
nothrow:
    @disable this(this);

    this(int initial) {
        int[2] fds;
        pipe(fds).checked("pipe initilization for semaphore");
        if (initial > 0) {
            trigger(initial);
        }
        this.fds = fds;
    }

    package(photon) int fd() { return fds[0]; }

    package(photon) int fd() shared { return fds[0]; }
    /// 
    void wait() {
        byte[1] bytes = void;
        ssize_t r;
        do {
            r = read(fds[0], bytes.ptr, bytes.sizeof);
        } while(r < 0 && errno == EINTR);
    }

    ///
    void wait() shared {
        this.unshared.wait();
    }

    package(photon) void reset() {
        wait();
    }

    package(photon) void reset() shared {
        wait();
    }
    
    /// 
    void trigger(int count) { 
        ubyte[4096] bytes = void;
        ssize_t size = count > 4096 ? 4096 : count;
        ssize_t r;
        do {
            r = write(fds[1], bytes.ptr, size);
        } while(r < 0 && errno == EINTR);
    }

    /// 
    void trigger(int count) shared {
        this.unshared.trigger(count);
    }

    ///
    void dispose() {
        close(fds[0]);
        close(fds[1]);
    }

    ///
    void dispose() shared {
        this.unshared.dispose();
    }

    private int[2] fds;
}

///
public nothrow auto semaphore(int initial) {
    return cast(shared)Semaphore(initial);
}

enum int MAX_EVENTS = 500;
shared long inited;

void notifyEventloop(size_t n) nothrow {
    KEvent event;
    event.ident = n;
    event.filter = EVFILT_USER;
    event.flags = EV_ADD | EV_ENABLE | EV_ONESHOT;
    event.fflags = NOTE_TRIGGER;
    logf("Notifying event loop %d", n);
    kevent(scheds[n].event_loop, &event, 1, null, 0, null).checked("notifying event loop");
}

int getCurrentKqueue() nothrow {
    return currentFiber !is null ? scheds[currentFiber.numScheduler].event_loop : scheds[0].event_loop;
}


public void startloop()
{
    auto s = atomicFetchAdd(inited, 1);
    if (s != 0) return;
    int threads = cast(int)sysconf(_SC_NPROCESSORS_ONLN).checked;
    debug(photon_single) {
        threads = 1;
    }
    ssize_t fdMax = sysconf(_SC_OPEN_MAX).checked;
    fdMax = fdMax > 2^^24 ? 2^^24 : fdMax;
    ssize_t size = ((fdMax * Descriptor.sizeof) + pageSize-1) & ~(pageSize-1);
    descriptors = (cast(shared(Descriptor*)) mmap(null, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))[0..fdMax];
    checked(cast(ssize_t)descriptors.ptr, "mmap failed");
    size = ((fdMax * DescriptorState.sizeof) + pageSize-1) & ~(pageSize-1);
    descriptorStates = (cast(shared(DescriptorState*)) mmap(null, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))[0..fdMax];
    checked(cast(ssize_t)descriptorStates.ptr, "mmap failed");
    scheds = new SchedulerBlock[threads];
    foreach(ref sched; scheds) {
        sched.queue = IntrusiveQueue!(FiberExt, RawEvent)(RawEvent(0));
        sched.event_loop = kqueue();
        enforce(sched.event_loop != -1);
    }
    initWorkQueues(threads);
}

void processEventsEntry(size_t n, Duration timeout)
{
    KEvent[MAX_EVENTS] ke;
    timespec ts;
    ts.tv_sec = timeout.total!"seconds"();
    ts.tv_nsec = (timeout - ts.tv_sec.seconds).total!"nsecs";
    int cnt = kevent(scheds[n].event_loop, null, 0, ke.ptr, MAX_EVENTS, timeout == Duration.max ? null : &ts);
    if (cnt < 0) return;
    for (int i = 0; i < cnt; i++) {
        auto fd = cast(int)ke[i].ident;
        auto filter = ke[i].filter;
        auto descriptor = descriptors.ptr + fd;
        if (filter == EVFILT_READ) {
            auto readers = &descriptor.readers;
            readers.lock();
            logf("Read event for fd=%d", fd);
            auto state = readers.state;
            logf("read state = %d", state);
            final switch(state) with(ReaderState) { 
                case EMPTY:
                case UNCERTAIN:
                case READY:
                    readers.state = READY;
                    readers.signal(n, fd);
                    break;
                case READING:
                case READING_SIGNALED:
                    readers.state = READING_SIGNALED;
                    readers.unlock();
                    break;
            }
        }
        if (filter == EVFILT_WRITE) {
            logf("Write event for fd=%d", fd);
            auto writers = &descriptor.writers;
            writers.lock();
            auto state = writers.state;
            logf("write state = %d", state);
            final switch(state) with(WriterState) { 
                case FULL:
                case READY:
                case UNCERTAIN:
                    writers.state = READY;
                    writers.signal(n, fd);
                    break;
                case WRITING:
                case WRITING_SIGNALED:
                    writers.state = WRITING_SIGNALED;
                    writers.unlock();
                    break;
            }
        }
        if (filter == EVFILT_USER) {
            logf("USER event %s", ke[i].ident);
        } 
    }
}

enum Fcntl: int { explicit = 0, msg = MSG_DONTWAIT, noop = 0xFFFFF }
enum SyscallKind { accept, read, write, connect }

// intercept - a filter for file descriptor, changes flags and register on first use
void interceptFd(Fcntl needsFcntl)(int fd) nothrow {
    logf("Hit interceptFD");
    if (fd < 0 || fd >= descriptors.length) return;
    if (cas(&descriptorStates[fd], DescriptorState.NOT_INITED, DescriptorState.INITIALIZING)) {
        logf("First use, registering fd = %s", fd);
        KEvent[2] ke;
        ke[0].ident = fd;
        ke[1].ident = fd;
        ke[0].filter = EVFILT_READ;
        ke[1].filter = EVFILT_WRITE;
        ke[1].flags = ke[0].flags = EV_ADD | EV_ENABLE | EV_CLEAR;
        int ret = kevent(getCurrentKqueue, ke.ptr, 2, null, 0, null);
        if (ret < 0) {
            descriptorStates[fd] = DescriptorState.THREADPOOL;
        } else {
            static if(needsFcntl == Fcntl.explicit) {
                int flags = fcntl(fd, F_GETFL, 0);
                fcntl(fd, F_SETFL, flags | O_NONBLOCK).checked("registering for non-blocking I/O");
                logf("Setting FCNTL. %x", cast(void*)currentFiber);
            }
            descriptorStates[fd] = DescriptorState.NONBLOCKING;
        }
    }
}

int gettid()
{
    return cast(int)__syscall(SYS_GETTID);
}

alias Nanosleep = int function(const timespec* req, timespec* rem);
Nanosleep nanosleepPtr;

extern(C) private int nanosleep(const timespec* req, timespec* rem) {
    if (currentFiber !is null) {
        delay(req);
        return 0;
    } else {
        if (nanosleepPtr == null) {
            nanosleepPtr = cast(Nanosleep)dlsym(RTLD_NEXT, "nanosleep");
        }
        return nanosleepPtr(req, rem);
    }
}

ssize_t raw_read(int fd, void *buf, size_t count) nothrow {
    logf("Raw read on FD=%d", fd);
    return __syscall(SYS_READ, fd, cast(ssize_t) buf, cast(ssize_t) count);
}

ssize_t raw_write(int fd, const void *buf, size_t count) nothrow
{
    logf("Raw write on FD=%d", fd);
    return __syscall(SYS_WRITE, fd, cast(size_t) buf, count);
}

int raw_poll(pollfd *fds, nfds_t nfds, int timeout) nothrow
{
    logf("Raw poll");
    return cast(int)__syscall(SYS_POLL, cast(size_t)fds, cast(size_t) nfds, timeout);
}
