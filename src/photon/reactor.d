module photon.reactor;
version(Posix):
package(photon):

import std.stdio;
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
import core.sync.mutex;
import core.stdc.errno;
import core.stdc.signal;
import core.stdc.time;
import core.stdc.stdlib;
import core.atomic;
import core.sys.posix.stdlib: abort;
import core.sys.posix.fcntl;
import core.sys.posix.sys.types;
import core.sys.posix.sys.socket;
import core.sys.posix.poll;
import core.sys.posix.netinet.in_;
import core.memory;

version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;

version (Darwin) {
    import photon.macos.core;
    import photon.macos.support;
} else version(linux) {
    import photon.linux.core;
    import photon.linux.support;
    import photon.linux.syscalls;
}

import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.threadpool;
import photon.task;
import photon.joiners;
import photon.exceptions;

import mecca.time_queue;
import mecca.containers.lists;

struct AwaitingFiber {
    shared FiberExt* fiber;
    AwaitingFiber* next;
    AwaitingFiber* prev;
    
    nothrow void schedule(size_t sched, int wakeFd) {
        auto f = cast()steal(*fiber);
        if (f !is null) {
            f.schedule(sched, wakeFd);
        }
    }
}

class FiberExt : Fiber { 
    FiberExt next;
    uint numScheduler;
    int wakeFd; // recieves fd that woken us up
    FiberJoiners joiners;
    struct FlsEntry {
        void* pointer;
        void function(void*) dtor;
    }
    FlsEntry[] fls;
    static size_t flsOffset;
    
    this(void function() fn, uint numSched) nothrow {
        super(fn, 2<<20);
        numScheduler = numSched;
        joiners = new FiberJoiners;
    }

    this(void delegate() dg, uint numSched) nothrow {
        super(dg, 2<<20);
        numScheduler = numSched;
        joiners = new FiberJoiners;
    }

    void schedule(size_t nsched, int wakeFd) nothrow
    {
        this.wakeFd = wakeFd;
        scheds[numScheduler].queue.push(this);
        if (nsched != numScheduler) {
            notifyEventloop(numScheduler);
        }
    }

    static size_t flsAlloc() nothrow {
        auto offset = flsOffset++;
        return offset;
    }

    void* flsGet(size_t offset, void* initValue, size_t size, void function(void*) dtor) nothrow {
        if (fls.length <= offset) {
            fls.length = offset + 1;
        }
        if (fls[offset].pointer is null) {
            fls[offset].pointer = new void[size].ptr;
            fls[offset].pointer[0..size] = initValue[0..size];
            fls[offset].dtor = dtor;
        }
        return fls[offset].pointer;
    }

    void destroyFls() {
        foreach (ref e; fls) {
            if (e.pointer) {
                e.dtor(e.pointer);
            }
        }
    }
}

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    int event_loop;
    ubyte[64 - queue.sizeof - assigned.sizeof - event_loop.sizeof] padding;
}
static assert(SchedulerBlock.sizeof == 64);

struct TimedFiber {
    shared FiberExt* fiber;
    TscTimePoint timePoint;
    timeQueue.OwnerAttrType _owner;
    TimedFiber* _next, _prev;

    void schedule(size_t numSched) {
        auto f = cast()steal(*fiber);
        if (f) {
            f.schedule(numSched, WAKE_TIMER);
        }
    }
}


enum ReaderState: uint {
    EMPTY = 0,
    UNCERTAIN = 1,
    READING = 2,
    READING_SIGNALED = 3,
    READY = 4
}

enum WriterState: uint {
    READY = 0,
    UNCERTAIN = 1,
    WRITING = 2,
    WRITING_SIGNALED = 3,
    FULL = 4
}

enum DescriptorState: uint {
    NOT_INITED,
    INITIALIZING,
    NONBLOCKING,
    THREADPOOL
}

struct FdWaiters(T) {
    private LinkedList!(AwaitingFiber*, "next", "prev") waiters;
    T state;
    private SpinLock splk;
nothrow:
    void lock() shared {
        splk.lock();
    }

    void unlock() shared {
        splk.unlock();
    }

    // must be called with lock grabbed
    void register(AwaitingFiber* waiter) shared {
        waiters.unshared.append(waiter);
        unlock();
    }

    // must be called with lock grabbed
    void unregister(AwaitingFiber* waiter) shared {
        if (waiter.next != null) { // is linked
            waiters.unshared.remove(waiter);
        }
        unlock();
    }

    // must be called with lock grabbed
    void signal(size_t sched, int wakeFd) shared {
        AwaitingFiber* waiter;
        if (!waiters.unshared.empty) {
            waiter = waiters.unshared.popHead();
        }
        unlock();
        if (waiter) {
            waiter.schedule(sched, wakeFd);
        }
    }

    void broadcast(size_t sched, int wakeFd) shared {
        AwaitingFiber* waiter;
        while (!waiters.unshared.empty) {
            waiter = waiters.unshared.popHead();
            waiter.schedule(sched, wakeFd);
        }
        unlock(); 
    }
}

// list of awaiting fibers
shared struct Descriptor {
    FdWaiters!ReaderState readers;
    FdWaiters!WriterState writers;
}
static assert (Descriptor.sizeof == 64);

enum TIMER_NUM_BINS = 256;
enum TIMER_NUM_LEVELS = 4;
enum int MAX_EVENTS = 500;
// fiber wakeup is due to an active FD or one of the following reasons
enum int WAKE_TRIGGER = -1;
enum int WAKE_TIMER = -2;
enum int WAKE_JOIN = -3;

FiberExt currentFiber;
shared int alive; // count of non-terminated Fibers
shared SchedulerBlock[] scheds; // per core scheduler data, notably run queue
shared Descriptor[] descriptors;
shared DescriptorState[] descriptorStates;

CascadingTimeQueue!(TimedFiber*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue; // thread-local

TimedFiber timerEntry(FiberExt* fiber, Duration delay) nothrow {
    return TimedFiber(cast(shared)fiber, TscTimePoint.hardNow() + delay);
}

TimedFiber timerEntry(FiberExt* fiber, const timespec* ts) nothrow {
    return TimedFiber(cast(shared)fiber, TscTimePoint.hardNow() + ts.tv_sec * dur!"seconds"(1) + ts.tv_nsec * dur!"nsecs"(1));
}

package(photon) void schedulerEntry(size_t n)
{
    void onTermination(FiberExt f) {
        f.destroyFls();
        atomicOp!"-="(alive, 1);
        if (alive == 0) {
            foreach (i; 0..scheds.length) {
                notifyEventloop(i);
            }
        }
        logf("Fiber %s terminated", cast(void*)f);
        auto joiners = f.joiners;
        destroy(f);
        joiners.wakeUpJoiners(n);

    }

    shared SchedulerBlock* sched = scheds.ptr + n;
    timeQueue.open(100.usecs);
    while (alive > 0) {
        TscTimePoint t;
        for (;;) {
            t = TscTimePoint.hardNow();
            for (;;) {
                TimedFiber* f = timeQueue.pop(t);
                if (f == null) break;
                f.schedule(n);
            }
            FiberExt f = sched.queue.drain();
            if (f is null) break;
            while (f) {
                auto next = f.next; //save next, it will be reused on scheduling
                currentFiber = f;
                logf("Fiber %x started", cast(void*)f);
                try {
                    f.call();
                    if (f.state == FiberExt.State.TERM) {
                        onTermination(f);
                    }
                }
                catch (Exception e) {
                    if (errorHandler) {
                        errorHandler(e, Task(f.joiners));
                    } else {
                        stderr.writeln("Unhandled fiber exception: ", e);
                    }
                    onTermination(f);
                }
                catch (Throwable e) {
                    if (errorHandler) {
                        errorHandler(e, Task(f.joiners));
                        onTermination(f);
                    } else {
                        stderr.writeln("FATAL fiber error: ", e);
                        abort();
                    }
                }
                f = next;
            }
        }
        processEventsEntry(n, timeQueue.timeTillNextEntry(t));
    }
}

/// Convenience overload for functions
public Task go(void function() func) nothrow @trusted {
    return go({ func(); });
}

/// Setup a fiber task to run on the Photon scheduler.
public Task go(void delegate() func) nothrow @trusted  {
    uint choice;
    if (scheds.length == 1) choice = 0;
    else {
        try {
            uint a = uniform!"[)"(0, cast(uint)scheds.length);
            uint b = uniform!"[)"(0, cast(uint)scheds.length-1);
            if (a == b) b = cast(uint)scheds.length-1;
            uint loadA = scheds[a].assigned;
            uint loadB = scheds[b].assigned;
            if (loadA < loadB) choice = a;
            else choice = b;
        } catch (Throwable t) { assert(false, t.toString()); }
    }
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    logf("Assigned %x -> %d / %d scheduler", cast(void*)f, choice, scheds.length);
    f.schedule(choice, WAKE_TRIGGER);
    notifyEventloop(choice);
    return Task(f.joiners);
}

/// Convenience overload for goOnSameThread that accepts functions 
public Task goOnSameThread(void function() func) nothrow @trusted {
    return goOnSameThread({ func(); });
}

/// Same as go but make sure the fiber is scheduled on the same thread of the threadpool.
/// Could be useful if there is a need to propagate TLS variable.
public Task goOnSameThread(void delegate() func) nothrow @trusted {
    auto choice = currentFiber !is null ? currentFiber.numScheduler : 0;
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    logf("Assigned %x -> %d / %d scheduler", cast(void*)f, choice, scheds.length);
    f.schedule(choice, WAKE_TRIGGER);
    notifyEventloop(choice);
    return Task(f.joiners);
}

/// Convenience overload for goOnAllThreads that accepts functions 
public void goOnAllThreads(void function() func) nothrow @trusted {
    goOnAllThreads({ func(); });
}

/// Schedules func on every available scheduler.
/// Could be useful for explicit parallel computation.
public void goOnAllThreads(void delegate() func) nothrow @trusted {
    atomicOp!"+="(alive, scheds.length);
    foreach (i; 0..scheds.length) {
        atomicOp!"+="(scheds[i].assigned, 1);
        auto f = new FiberExt(func, cast(uint)i);
        logf("Assigned %x -> %d / %d scheduler", cast(void*)f, i, scheds.length);
        f.schedule(i, WAKE_TRIGGER);
        notifyEventloop(i);
    }
}

/// Delay fiber execution by `req` duration.
public nothrow @trusted void delay(T)(T req)
if (is(T : const timespec*) || is(T : Duration)) {
    if (currentFiber is null) {
        static if(is(T : const timespec*)) {
            Duration toSleep = req.tv_sec * 1.seconds + req.tv_nsec * 1.nsecs;
        } else {
            Duration toSleep = req;
        }
        Thread.sleep(toSleep);
    } else {
        FiberExt fiber = currentFiber;
        auto tm = timerEntry(&fiber, req);
        timeQueue.insert(&tm);
        FiberExt.yield();
    }
}

///
public void yield() @trusted nothrow {
    if (currentFiber !is null) {
        currentFiber.schedule(currentFiber.numScheduler, WAKE_TRIGGER);
        FiberExt.yield();
    } else {
        Thread.yield();
    }
}

template Unshared(T) {
    static if (is(T: shared(U), U)) {
        alias Unshared = U;
    } else static if (is(T: shared(U)*, U)) {
        alias Unshared = U*;
    }
    else {
        alias Unshared = T;
    }
}

///
public enum isAwaitable(E) = is (Unshared!E : Event) || is (Unshared!E : Semaphore) 
    || is(Unshared!E : Event*) || is(Unshared!E : Semaphore*);

static assert(isAwaitable!(Event*));
static assert(isAwaitable!(shared(Event)*));

public size_t awaitAny(Awaitable...)(auto ref Awaitable args) 
if (allSatisfy!(isAwaitable, Awaitable)) {
    pollfd* fds = cast(pollfd*)calloc(args.length, pollfd.sizeof);
    scope(exit) free(fds);
    foreach (i, ref arg; args) {
        fds[i].fd = arg.fd;
        fds[i].events = POLL_IN;
    }
    ssize_t resp;
    do {
        resp = poll(fds, cast(nfds_t)args.length, -1); 
    } while (resp < 0 && errno == EINTR);
    foreach (idx, ref arg; args[0..args.length]) {
        auto fd = fds[idx];
        if (fd.revents & POLL_IN) {
            arg.reset();
            return idx;
        }
    }
    assert(0);
}

public size_t awaitAny(Awaitable)(Awaitable[] args) 
if (isAwaitable!(Awaitable)) {
    pollfd* fds = cast(pollfd*)calloc(args.length, pollfd.sizeof);
    scope(exit) free(fds);
    foreach (i, ref arg; args) {
        fds[i].fd = arg.fd;
        fds[i].events = POLL_IN;
    }
    ssize_t resp;
    do {
        resp = poll(fds, cast(nfds_t)args.length, -1); 
    } while (resp < 0 && errno == EINTR);
    foreach (idx, ref arg; args[0..args.length]) {
        auto fd = fds[idx];
        if (fd.revents & POLL_IN) {
            arg.reset();
            return idx;
        }
    }
    assert(0);
}

ssize_t syscallOffload(T...)(size_t ident, int fd, T args) nothrow {
    pragma(inline, false);
    auto result = offload(() {
        auto ret = __syscall(ident, fd, args);
        if (ret < 0) {
            return -errno;
        }
        else {
            return ret;
        }
    });
    if (result < 0) {
        errno = cast(int)-result;
        return -1;
    }
    else {
        return result;
    }
}

ssize_t universalSyscall(size_t ident, string name, SyscallKind kind, Fcntl fcntlStyle, ssize_t ERR, T...)
                        (int fd, T args) nothrow {
    if (currentFiber is null) {
        logf("%s PASSTHROUGH FD=%s", name, fd);
        return __syscall(ident, fd, args);
    }
    else {
        logf("HOOKED %s FD=%d", name, fd);
        interceptFd!(fcntlStyle)(fd);
        shared(Descriptor)* descriptor = descriptors.ptr + fd;
        if (atomicLoad(descriptorStates[fd]) == DescriptorState.THREADPOOL) {
            logf("%s syscall THREADPOOL FD=%d", name, fd);
            return syscallOffload(ident, fd, args);
        }
    L_start:
        FiberExt fiber = currentFiber;
        AwaitingFiber await = AwaitingFiber(cast(shared)&fiber);
        // set flags argument if able to avoid direct fcntl calls
        static if (fcntlStyle != Fcntl.explicit)
        {
            args[2] |= fcntlStyle;
        }
        logf("kind:s args:%s", kind, args);
        static if(kind == SyscallKind.accept || kind == SyscallKind.read) {
            auto readers = &descriptor.readers;
            readers.lock();
            auto state = readers.state;
            logf("%s syscall state is %d. Fiber %x", name, state, cast(void*)fiber);
            final switch (state) with (ReaderState) {
            case EMPTY:
            case READING:
            case READING_SIGNALED:
                readers.register(&await); // unlocks the lock
                FiberExt.yield();
                goto L_start;
            case UNCERTAIN:
            case READY:
                readers.state = READING;
                readers.unlock();
                ssize_t resp = __syscall(ident, fd, args);
                readers.lock();
                 // was notified by event loop somewhere between __syscall and lock()
                if(readers.state == READING_SIGNALED && resp < 0) { // redo failed syscall
                    goto case READY;
                }
                static if (kind == SyscallKind.accept) {
                    if (resp >= 0)  { // for accept we never know if we emptied the queue
                        readers.state = UNCERTAIN;
                         // wake one of waiters if present, unlocks the lock
                        readers.signal(currentFiber.numScheduler, fd);
                    }
                    else if (errno == ERR || errno == EAGAIN) {
                        readers.state = EMPTY;
                        readers.register(&await); // unlocks the lock
                        FiberExt.yield();
                        goto L_start;
                    }
                    else { // other error
                        readers.unlock(); 
                    }
                }
                else static if (kind == SyscallKind.read) {
                    // length is 2nd in (buf, length, ...)
                    if (resp == args[1] || readers.state == READING_SIGNALED) {
                        readers.state = UNCERTAIN;
                         // wake one of waiters if present, unlocks the lock
                        readers.signal(currentFiber.numScheduler, fd);
                    }
                    else if(resp >= 0) {
                        readers.state = EMPTY;
                        readers.unlock(); // no need to wake up others it's empty now
                    }
                    else if (errno == ERR || errno == EAGAIN) {
                        readers.state = EMPTY;
                        readers.register(&await); // unlocks the lock
                        FiberExt.yield();
                        goto L_start;
                    }
                    else { // other error
                        readers.unlock(); 
                    }
                }
                else
                    static assert(0);
                return resp;
            }
        }
        else static if(kind == SyscallKind.write || kind == SyscallKind.connect) {
            auto writers = &descriptor.writers;
            writers.lock();
            auto state = writers.state;
            logf("%s syscall state is %d. Fiber %x", name, state, cast(void*)currentFiber);
            final switch (state) with (WriterState) {
            case FULL:
            case WRITING:
            case WRITING_SIGNALED:
                writers.register(&await); // unlocks the lock
                FiberExt.yield();
                goto L_start;
            case READY:
            case UNCERTAIN:
                writers.state = WRITING;
                writers.unlock();
                ssize_t resp = __syscall(ident, fd, args);
                writers.lock();
                if (writers.state == WRITING_SIGNALED && resp < 0) { // got signaled by eventloop in the meantime
                    goto case READY;
                }
                static if (kind == SyscallKind.connect) {
                    if(resp >= 0) {
                        writers.state = READY;
                        writers.unlock();
                    }
                    else if (errno == ERR || errno == EALREADY) {
                        writers.state = FULL;
                        writers.register(&await); // unlocks the lock
                        FiberExt.yield();
                        goto L_start;
                    }
                    else {
                        // other error
                        writers.unlock();
                    }
                    return resp;
                }
                else {
                     // (buf, len) args to syscall
                    if (resp == args[1] || writers.state == WRITING_SIGNALED) {
                        writers.state = UNCERTAIN;
                        writers.signal(currentFiber.numScheduler, fd); // unlocks the lock
                    }
                    else if(resp >= 0) {
                        logf("Short-write on FD=%d, become FULL", fd);
                        writers.state = FULL;
                        writers.unlock(); // no need to wake up others
                    }
                    else if (errno == ERR || errno == EAGAIN) {
                        writers.state = FULL;
                        writers.register(&await); // unlocks the lock
                        FiberExt.yield();
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                    else { // other error
                        writers.unlock();
                    }
                    return resp;
                }
            }
        }
        assert(0);
    }
}

void deregisterFd(int fd) nothrow {
    if(fd >= 0 && fd < descriptors.length) {
        size_t choice = currentFiber !is null ? currentFiber.numScheduler : size_t.max;
        auto descriptor = descriptors.ptr + fd;
        descriptor.readers.lock();
        descriptor.readers.state = ReaderState.EMPTY;
        descriptor.readers.broadcast(choice, fd);
        descriptor.writers.lock();
        descriptor.writers.state = WriterState.READY;
        descriptor.writers.broadcast(choice, fd);
        atomicStore(descriptorStates[fd], DescriptorState.NOT_INITED);
    }
}


// ======================================================================================
// SYSCALL warappers intercepts
// ======================================================================================
nothrow:
private:
extern(C) ssize_t read(int fd, void *buf, size_t count) nothrow
{
    return universalSyscall!(SYS_READ, "read", SyscallKind.read, Fcntl.explicit, EWOULDBLOCK)
        (fd, cast(size_t)buf, count);
}

extern(C) ssize_t write(int fd, const void *buf, size_t count)
{
    return universalSyscall!(SYS_WRITE, "write", SyscallKind.write, Fcntl.explicit, EWOULDBLOCK)
        (fd, cast(size_t)buf, count);
}

extern(C) int accept(int sockfd, sockaddr *addr, socklen_t *addrlen)
{
    return cast(int)universalSyscall!(SYS_ACCEPT, "accept", SyscallKind.accept, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);    
}

extern(C) int connect(int sockfd, const sockaddr *addr, socklen_t addrlen)
{
    return cast(int)universalSyscall!(SYS_CONNECT, "connect", SyscallKind.connect, Fcntl.explicit, EINPROGRESS)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);
}

extern(C) ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
                      const sockaddr *dest_addr, socklen_t addrlen)
{
    return universalSyscall!(SYS_SENDTO, "sendto", SyscallKind.write, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) buf, len, flags, cast(size_t) dest_addr, cast(size_t) addrlen);
}

extern(C) ssize_t send(int sockfd, const void *buf, size_t len, int flags)
{
    return universalSyscall!(SYS_SENDTO, "sendto", SyscallKind.write, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) buf, len, flags, null, 0);
}

extern(C) ssize_t recv(int sockfd, void *buf, size_t len, int flags) nothrow {
    sockaddr_in src_addr;
    src_addr.sin_family = AF_INET;
    src_addr.sin_port = 0;
    src_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    ssize_t addrlen = sockaddr_in.sizeof;
    return recvfrom(sockfd, buf, len, flags, cast(sockaddr*)&src_addr, &addrlen);   
}

extern(C) private ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
                        sockaddr *src_addr, ssize_t* addrlen) nothrow
{
    return universalSyscall!(SYS_RECVFROM, "recvfrom", SyscallKind.read, Fcntl.msg, EWOULDBLOCK)
        (sockfd, cast(size_t)buf, len, flags, cast(size_t)src_addr, cast(size_t)addrlen);
}

extern(C) private int poll(pollfd *fds, nfds_t nfds, int timeout)
{
    nothrow bool nonBlockingCheck(ref int result, int timeout) {
        bool uncertain;
    L_cacheloop:
        foreach (ref fd; fds[0..nfds]) {
            interceptFd!(Fcntl.explicit)(fd.fd);
            fd.revents = 0;
            auto descriptor = descriptors.ptr + fd.fd;
            if (fd.events & POLLIN) {
                descriptor.readers.lock();
                scope(exit) descriptor.readers.unlock();
                auto state = descriptor.readers.state;
                logf("Found event %d for reader in select", state);
                switch(state) with(ReaderState) {
                case READY:
                    fd.revents |=  POLLIN;
                    break;
                case EMPTY:
                    break;
                default:
                    uncertain = true;
                    break L_cacheloop;
                }
            }
            if (fd.events & POLLOUT) {
                descriptor.writers.lock();
                scope(exit) descriptor.writers.unlock();
                auto state = descriptor.writers.state;
                logf("Found event %d for writer in select", state);
                switch(state) with(WriterState) {
                case READY:
                    fd.revents |= POLLOUT;
                    break;
                case FULL:
                    break;
                default:
                    uncertain = true;
                    break L_cacheloop;
                }
            }
        }
        // fallback to system poll call if descriptor state is uncertain
        if (uncertain) {
            logf("Fallback to system poll, descriptors have uncertain state");
            int p = raw_poll(fds, nfds, 0);
            if (p != 0 || timeout == 0) {
                result = p;
                logf("Raw poll returns %d", result);
                return true;
            }
        }
        else {
            int j = 0;
            foreach (i; 0..nfds) {
                if (fds[i].revents) {
                    j++;
                }
            }
            logf("Using our own event cache: %d events", j);
            if (j > 0 || timeout == 0) {
                result = j;
                return true;
            }
        }
        return false;
    }
    size_t numEvents() {
        size_t j = 0;
        foreach (i; 0..nfds) {
            if (fds[i].events & POLLIN)
                j++;
            else if(fds[i].events & POLLOUT)
                j++;
        }
        return j;
    }
    if (currentFiber is null) {
        logf("POLL PASSTHROUGH!");
        return raw_poll(fds, nfds, timeout);
    }
    else {
        logf("HOOKED POLL %d fds timeout %d", nfds, timeout);
        if (nfds < 0) {
            errno = EINVAL;
            return -1;
        }
        if (nfds == 0) {
            if (timeout == 0) return 0;
            delay(timeout.msecs);
            logf("Woke up after select %x. WakeFd=%d", cast(void*)currentFiber, currentFiber.wakeFd);
            return 0;
        }
        foreach(ref fd; fds[0..nfds]) {
            fd.revents = 0;
        }
        int result = 0;
        if (nonBlockingCheck(result, timeout)) return result;
        FiberExt fiber = currentFiber;
        size_t events = numEvents();
        AwaitingFiber[2] stack;
        bool heapAlloc = false;
        AwaitingFiber[] waiters;
        if (events < stack.length) {
            waiters = stack[0..events];
        } else {
            heapAlloc = true;
            waiters = (cast(AwaitingFiber*)calloc(events, AwaitingFiber.sizeof))[0..events];
        }
        scope(exit) {
            if (heapAlloc)
                free(waiters.ptr);
        }
        foreach (ref af; waiters) {
            af.fiber = cast(shared)&fiber;
        }
        size_t j = 0;
        foreach (i; 0..nfds) {
            auto d = &descriptors[fds[i].fd];
            if (fds[i].events & POLLIN) {
                d.readers.lock();
                d.readers.register(&waiters[j++]);
            }
            if(fds[i].events & POLLOUT) {
                d.writers.lock();
                d.writers.register(&waiters[j++]);
            }
        }
        assert(j == events);
        if (timeout > 0) {
            auto tm = timerEntry(&fiber, timeout.msecs);
            timeQueue.insert(&tm);
            FiberExt.yield();
            if (currentFiber.wakeFd != WAKE_TIMER) {
                timeQueue.cancel(&tm);
            }
        }
        else {
            FiberExt.yield();
        }
        j = 0;
        foreach (i; 0..nfds) {
            auto d = &descriptors[fds[i].fd];
            if (fds[i].events & POLLIN) {
                d.readers.lock();
                d.readers.unregister(&waiters[j++]);
            }
            if(fds[i].events & POLLOUT) {
                d.writers.lock();
                d.writers.unregister(&waiters[j++]);
            }
        }
        logf("Woke up after select %x. WakeFD=%d", cast(void*)currentFiber, currentFiber.wakeFd);
        if (currentFiber.wakeFd == WAKE_TIMER) return 0;
        else {
            nonBlockingCheck(result, 0);
            return result;
        }
    }
}

extern(C) private int close(int fd) nothrow
{
    logf("HOOKED CLOSE FD=%d", fd);
    deregisterFd(fd);
    return cast(int)__syscall(SYS_CLOSE, fd);
}
