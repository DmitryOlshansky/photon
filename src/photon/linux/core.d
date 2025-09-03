module photon.linux.core;
version(linux):
package(photon):

import core.internal.spinlock;
import core.sys.posix.sys.types;
import core.sys.posix.sys.socket;
import core.sys.posix.poll;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd;
import core.sys.linux.epoll;
import core.sys.linux.timerfd;
import core.sys.linux.sys.eventfd;
import core.sync.mutex;
import core.stdc.errno;
import core.atomic;
import core.sys.posix.stdlib: abort;
import core.sys.posix.fcntl;
import core.memory;
import core.sys.posix.sys.mman;
import core.sys.posix.pthread;
import core.stdc.stdlib;
import core.sys.linux.sys.signalfd;

import photon.linux.support;
import photon.linux.syscalls;
import photon.reactor;
import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.threadpool;
import photon.task;

immutable size_t pageSize;

shared static this() {
    pageSize = sysconf(_SC_PAGESIZE);
}

shared struct RawEvent {
nothrow:
    this(int init) {
        fd = eventfd(init, 0).checked("raw event");
    }

    void waitAndReset() {
        union U {
            ulong cnt;
            ubyte[8] bytes;
        }
        U value;
        ssize_t r;
        do {
            r = raw_read(fd, value.bytes.ptr, 8);
        } while(r < 0 && errno == EINTR);
        r.checked("event reset");
    }
    
    void trigger() { 
        union U {
            ulong cnt;
            ubyte[8] bytes;
        }
        U value;
        value.cnt = 1;
        ssize_t r;
        do {
            r = raw_write(fd, value.bytes.ptr, 8);
        } while(r < 0 && errno == EINTR);
        r.checked("event trigger");
    }

    void close() {
        .close(fd);
    }
    
    int fd;
}

///
public struct Event {
nothrow @trusted:
    private int evfd;

    this(bool signaled) {
        evfd = eventfd(signaled ? 1 : 0, EFD_NONBLOCK).checked("Event constructor");
        interceptFd!(Fcntl.noop)(evfd);
    }

    package(photon) int fd() { return evfd; }

    package(photon) int fd() shared { return evfd; }

    @disable this(this);

    /// Wait for the event to be triggered, then reset and return atomically
    void waitAndReset() {
        byte[8] bytes = void;
        ssize_t r;
        do {
            r = read(evfd, bytes.ptr, bytes.sizeof);
        } while (r < 0 && errno == EINTR);
    }

    void waitAndReset() shared {
        this.unshared.waitAndReset();
    }

    void reset() {
        waitAndReset();
    }

    void reset() shared {
        waitAndReset();
    }

    /// Trigger the event.
    void trigger() { 
        union U {
            ulong cnt;
            ubyte[8] bytes;
        }
        U value;
        value.cnt = 1;
        ssize_t r;
        do {
            r = write(evfd, value.bytes.ptr, value.sizeof);
        } while(r < 0 && errno == EINTR);
    }

    void trigger() shared {
        this.unshared.trigger();
    }

    /// Free this event
    void dispose() {
        close(evfd);
    }

    void dispose() shared {
        this.unshared.dispose();
    }
}

///
public auto event(bool triggered) {
    return Event(triggered);
}

///
public struct Semaphore {
nothrow @trusted:
    private int evfd;
    ///
    this(int count) {
        evfd = eventfd(count, EFD_NONBLOCK | EFD_SEMAPHORE).checked("Semaphore constructor");
        interceptFd!(Fcntl.noop)(evfd);
    }

    int fd() { return evfd; }

    int fd() shared { return evfd; }

    @disable this(this);

    ///
    void wait() {
        ubyte[8] bytes = void;
        ssize_t r;
        do {
            // go through event loop
            r = read(evfd, bytes.ptr, bytes.sizeof);
            logf("READ SEM %d", r);
        } while (r < 0 && errno == EINTR);
    }

    void wait() shared {
        this.unshared.wait();
    }

    void reset() {
        wait();
    }

    void reset() shared {
        wait();
    }

    ///
    void trigger(int count) {
        union U {
            ulong cnt;
            ubyte[8] bytes;
        }
        U value;
        value.cnt = count;
        ssize_t r;
        do {
            r = write(evfd, value.bytes.ptr, value.sizeof);
            logf("WRITE SEM %d", r);
        } while(r < 0 && errno == EINTR);
    }

    void trigger(int count) shared {
        this.unshared.trigger(count);
    }

    /// Free this semaphore
    void dispose() {
        close(evfd).checked;
    }

    void dispose() shared {
        this.unshared.dispose();
    }
}

///
public auto nothrow semaphore(int initialCount) {
    return Semaphore(initialCount);
}

public struct Timer {
    void wait(Duration d) {
        delay(d);
    }
}

///
public auto timer() {
    return Timer();
}

enum int MAX_EVENTS = 500;
shared long inited;

public void startloop() nothrow @trusted
{
    auto s = atomicFetchAdd(inited, 1);
    if (s != 0) return;
    cpu_set_t cpus;
    size_t threads = 0;
    if (sched_getaffinity(gettid(), cpus.sizeof, &cpus) < 0) {
        photon.linux.support.perror("sched_getaffinity");
    }
    for (size_t i = 0; i < cpus.sizeof*8; i++) {
        if (CPU_GET(i, &cpus))
            threads += 1;
    }
    debug(photon_single) {
        threads = 1;
    }

    ssize_t fdMax = sysconf(_SC_OPEN_MAX).checked;
    fdMax = fdMax > 2^^24 ? 2^^24 : fdMax;
    ssize_t size = ((fdMax * Descriptor.sizeof) + pageSize-1) & ~(pageSize-1);
    descriptors = (cast(shared(Descriptor*)) mmap(null, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))[0..fdMax];
    checked(cast(ssize_t)descriptors.ptr, "mmap failed");
    scheds = new SchedulerBlock[threads];
    foreach(ref sched; scheds) {
        sched.queue = IntrusiveQueue!(FiberExt, RawEvent)(RawEvent(0));
        sched.event_loop = cast(int)epoll_create1(0).checked("ERROR: Failed to create event-loop!");
        epoll_event event;
        event.events = EPOLLIN;
        event.data.fd = sched.queue.event.fd;
        epoll_ctl(sched.event_loop, EPOLL_CTL_ADD, sched.queue.event.fd, &event).checked;
    }

    initWorkQueues(threads);
}

void processEventsEntry(size_t numSched, Duration timeout)
{
    //for (;;) {
    epoll_event[MAX_EVENTS] events = void;
    auto sched = &scheds[numSched];
    int r;
    do {
        r = epoll_wait(sched.event_loop, events.ptr, MAX_EVENTS, timeout > dur!"hours"(1000) ? -1 : cast(int)timeout.total!"msecs");
    } while (r < 0 && errno == EINTR);
    for (int n = 0; n < r; n++) {
        int fd = events[n].data.fd;
        if (fd == sched.queue.event.fd) {
            sched.queue.event.waitAndReset();
        }
        else {
            auto descriptor = descriptors.ptr + fd;
            if (descriptor.state == DescriptorState.NONBLOCKING) {
                if (events[n].events & EPOLLIN) {
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
                            readers.signal(numSched, fd);
                            break;
                        case READING:
                        case READING_SIGNALED:
                            readers.state = READING_SIGNALED;
                            readers.unlock();
                            break;
                    }
                }
                if (events[n].events & EPOLLOUT) {
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
                            writers.signal(numSched, fd);
                            break;
                        case WRITING:
                        case WRITING_SIGNALED:
                            writers.state = WRITING_SIGNALED;
                            writers.unlock();
                            break;
                    }
                }
            }
        }
    }
}

void notifyEventloop(size_t n) nothrow {
    scheds[n].queue.event.trigger();
}

auto __syscall(T...)(T args) {
    pragma(inline, true);
    return syscall(args);
}

enum Fcntl: int { explicit = 0, msg = MSG_DONTWAIT, sock = SOCK_NONBLOCK, noop = 0xFFFFF }
enum SyscallKind { accept, read, write, connect }

// intercept - a filter for file descriptor, changes flags and register on first use
void interceptFd(Fcntl needsFcntl)(int fd) nothrow {
    logf("Hit interceptFD");
    if (fd < 0 || fd >= descriptors.length) return;
    if (cas(&descriptors[fd].state, DescriptorState.NOT_INITED, DescriptorState.INITIALIZING)) {
        logf("First use, registering fd = %s", fd);
        static if(needsFcntl == Fcntl.explicit) {
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK).checked;
            logf("Setting FCNTL. %x", cast(void*)currentFiber);
        }
        epoll_event event;
        event.events = EPOLLIN | EPOLLOUT | EPOLLET;
        event.data.fd = fd;
        size_t n = currentFiber !is null ? currentFiber.numScheduler : 0;
        if (epoll_ctl(scheds[n].event_loop, EPOLL_CTL_ADD, fd, &event) < 0 && errno == EPERM) {
            logf("isSocket = false FD = %s", fd);
            descriptors[fd].state = DescriptorState.THREADPOOL;
        }
        else {
            logf("isSocket = true FD = %s", fd);
            descriptors[fd].state = DescriptorState.NONBLOCKING;
        }
    }
    while(descriptors[fd].state == DescriptorState.INITIALIZING) {}
}

// ======================================================================================
// SYSCALL warappers intercepts
// ======================================================================================
nothrow:

extern(C) private int nanosleep(const timespec* req, timespec* rem) {
    if (currentFiber !is null) {
        delay(req);
        return 0;
    } else {
        __syscall(SYS_NANOSLEEP, req, rem);
        return 0;
    }
}

extern(C) ssize_t accept4(int sockfd, sockaddr *addr, socklen_t *addrlen, int flags)
{
    return universalSyscall!(SYS_ACCEPT4, "accept4", SyscallKind.accept, Fcntl.sock, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen, flags);
}
