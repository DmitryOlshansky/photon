module photon.reactor;

version(OSX):
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

version (OSX) {
    import photon.macos.core;
    import photon.macos.support;
}
import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.threadpool;

import mecca.time_queue;

struct AwaitingFiber {
    shared FiberExt* fiber;
    AwaitingFiber* next;

    void scheduleAll(int wakeFd, size_t nsched) nothrow
    {
        auto w = &this;
        FiberExt head;
        // first process all AwaitingFibers since they are on stack
        do {
            auto fiber = steal(*w.fiber);
            if (fiber) {
                fiber.unshared.next = head;
                head = fiber.unshared;
            }
            w = w.next;
        } while(w);
        while(head) {
            logf("Waking with FD=%d", wakeFd);
            head.wakeFd = wakeFd;
            auto next = head.next;
            head.schedule(nsched);
            head = next;
        }
    }
}

enum wokenUpByTimer = 2;

class FiberExt : Fiber { 
    FiberExt next;
    uint numScheduler;
    int wakeFd; // recieves fd that woken us up
    ThreadInfo tidInfo;
    SpinLock joinLock;
    FiberExt joiners;
    
    this(void function() fn, uint numSched) nothrow {
        super(fn);
        numScheduler = numSched;
    }

    this(void delegate() dg, uint numSched) nothrow {
        super(dg);
        numScheduler = numSched;
    }

    void schedule(size_t nsched) nothrow
    {
        scheds[numScheduler].queue.push(this);
        if (nsched != numScheduler) {
            notifyEventloop(numScheduler);
        }
    }

    void join() nothrow {
        bool suspend = false;
        joinLock.lock();
        if (state != Fiber.State.TERM) {
            currentFiber.next = joiners;
            joiners = currentFiber;
            suspend = true;
        }
        joinLock.unlock();
        if (suspend) yield();
    }

    void wakeUpJoiners(size_t numSched) {
        joinLock.lock();
        FiberExt f = joiners;
        while (f) {
            FiberExt next = f.next;
            f.schedule(numSched);
            f = next;
        }
        joinLock.unlock();
    }
}

FiberExt currentFiber;
shared int alive; // count of non-terminated Fibers scheduled

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    int event_loop;
    int padding;
}
static assert(SchedulerBlock.sizeof == 64);

enum TIMER_NUM_BINS = 256;
enum TIMER_NUM_LEVELS = 4;

struct TimedFiber {
    shared FiberExt* fiber;
    TscTimePoint timePoint;
    timeQueue.OwnerAttrType _owner;
    TimedFiber* _next, _prev;

    void schedule(size_t numSched) {
        auto f = cast()steal(*fiber);
        f.schedule(numSched);
    }
}

shared SchedulerBlock[] scheds;
CascadingTimeQueue!(TimedFiber*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue; // thread-local

TimedFiber timerEntry(FiberExt* fiber, Duration delay) nothrow {
    return TimedFiber(cast(shared)fiber, TscTimePoint.hardNow() + delay);
}

TimedFiber timerEntry(FiberExt* fiber, const timespec* ts) nothrow {
    return TimedFiber(cast(shared)fiber, TscTimePoint.hardNow() + ts.tv_sec * dur!"seconds"(1) + ts.tv_nsec * dur!"nsecs"(1));
}


enum int MAX_EVENTS = 500;
enum int SIGNAL = 42;

package(photon) void schedulerEntry(size_t n)
{
    shared SchedulerBlock* sched = scheds.ptr + n;
    void onTermination() {
        atomicOp!"-="(alive, 1);
        if (alive == 0) {
            foreach (i; 0..scheds.length) {
                notifyEventloop(i);
            }
        }
    }
    timeQueue.open(100.usecs);
    while (alive > 0) {
        TscTimePoint t = TscTimePoint.hardNow();
        for (;;) {
            TimedFiber* f = timeQueue.pop(t);
            if (f == null) break;
            f.schedule(n);
        }
        FiberExt f = sched.queue.drain();
        while (f) {
            auto next = f.next; //save next, it will be reused on scheduling
            currentFiber = f;
            logf("Fiber %x started", cast(void*)f);
            try {
                f.call();
            }
            catch (Throwable e) {
                stderr.writeln(e);
                onTermination();
            }
            if (f.state == FiberExt.State.TERM) {
                f.wakeUpJoiners(n);
                logf("Fiber %s terminated", cast(void*)f);
                onTermination();
            }
            f = next;
        }
        processEventsEntry(n, timeQueue.timeTillNextEntry(t));
    }
}

/// Convenience overload for functions
public void go(void function() func) {
    go({ func(); });
}

/// Setup a fiber task to run on the Photon scheduler.
public void go(void delegate() func) {
    uint choice;
    if (scheds.length == 1) choice = 0;
    else {
        uint a = uniform!"[)"(0, cast(uint)scheds.length);
        uint b = uniform!"[)"(0, cast(uint)scheds.length-1);
        if (a == b) b = cast(uint)scheds.length-1;
        uint loadA = scheds[a].assigned;
        uint loadB = scheds[b].assigned;
        if (loadA < loadB) choice = a;
        else choice = b;
    }
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    logf("Assigned %x -> %d / %d scheduler", cast(void*)f, choice, scheds.length);
    f.schedule(choice);
    notifyEventloop(choice);
}

/// Convenience overload for goOnSameThread that accepts functions 
public void goOnSameThread(void function() func) {
    goOnSameThread({ func(); });
}

/// Same as go but make sure the fiber is scheduled on the same thread of the threadpool.
/// Could be useful if there is a need to propagate TLS variable.
public void goOnSameThread(void delegate() func) {
    auto choice = currentFiber !is null ? currentFiber.numScheduler : 0;
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    logf("Assigned %x -> %d / %d scheduler", cast(void*)f, choice, scheds.length);
    f.schedule(choice);
    notifyEventloop(choice);
}

shared Descriptor[] descriptors;

enum ReaderState: uint {
    EMPTY = 0,
    UNCERTAIN = 1,
    READING = 2,
    READY = 3
}

enum WriterState: uint {
    READY = 0,
    UNCERTAIN = 1,
    WRITING = 2,
    FULL = 3
}

enum DescriptorState: uint {
    NOT_INITED,
    INITIALIZING,
    NONBLOCKING,
    THREADPOOL
}

// list of awaiting fibers
shared struct Descriptor {
    ReaderState _readerState;   
    AwaitingFiber* _readerWaits;
    WriterState _writerState;
    AwaitingFiber* _writerWaits;
    DescriptorState state;
nothrow:
    ReaderState readerState()() {
        return atomicLoad(_readerState);
    }

    WriterState writerState()() {
        return atomicLoad(_writerState);
    }

    // try to change state & return whatever it happend to be in the end
    bool changeReader()(ReaderState from, ReaderState to) {
        return cas(&_readerState, from, to);
    }

    // ditto for writer
    bool changeWriter()(WriterState from, WriterState to) {
        return cas(&_writerState, from, to);
    }

    //
    shared(AwaitingFiber)* readWaiters()() {
        return atomicLoad(_readerWaits);
    }

    //
    shared(AwaitingFiber)* writeWaiters()(){
        return atomicLoad(_writerWaits);
    }

    // try to enqueue reader fiber given old head
    bool enqueueReader()(shared(AwaitingFiber)* fiber) {
        auto head = readWaiters;
        if (head == fiber) {
            return true; // TODO: HACK
        }
        fiber.next = head;
        return cas(&_readerWaits, head, fiber);
    }

    void removeReader()(shared(AwaitingFiber)* fiber) {
        auto head = steal(_readerWaits);
        if (head is null || head.next is null) return;
        head = removeFromList(head.unshared, fiber);
        cas(&_readerWaits, head, cast(shared(AwaitingFiber*))null);
    }

    // try to enqueue writer fiber given old head
    bool enqueueWriter()(shared(AwaitingFiber)* fiber) {
        auto head = writeWaiters;
        if (head == fiber) {
            return true; // TODO: HACK
        }
        fiber.next = head;
        return cas(&_writerWaits, head, fiber);
    }

    void removeWriter()(shared(AwaitingFiber)* fiber) {
        auto head = steal(_writerWaits);
        if (head is null || head.next is null) return;
        head = removeFromList(head.unshared, fiber);
        cas(&_writerWaits, head, cast(shared(AwaitingFiber*))null);
    }

    // try to schedule readers - if fails - someone added a reader, it's now his job to check state
    void scheduleReaders()(int wakeFd, size_t nsched) {
        auto w = steal(_readerWaits);
        if (w) w.unshared.scheduleAll(wakeFd, nsched);
    }

    // try to schedule writers, ditto
    void scheduleWriters()(int wakeFd, size_t nsched) {
        auto w = steal(_writerWaits);
        if (w) w.unshared.scheduleAll(wakeFd, nsched);
    }
}

/// Delay fiber execution by `req` duration.
public nothrow void delay(T)(T req)
if (is(T : const timespec*) || is(T : Duration)) {
    FiberExt fiber = currentFiber;
    auto tm = timerEntry(&fiber, req);
    timeQueue.insert(&tm);
    FiberExt.yield();
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
        if (atomicLoad(descriptor.state) == DescriptorState.THREADPOOL) {
            logf("%s syscall THREADPOLL FD=%d", name, fd);
            //TODO: offload syscall to thread-pool
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
    L_start:
        FiberExt fiber = currentFiber;
        shared AwaitingFiber await = AwaitingFiber(cast(shared)&fiber, null);
        // set flags argument if able to avoid direct fcntl calls
        static if (fcntlStyle != Fcntl.explicit)
        {
            args[2] |= fcntlStyle;
        }
        //if (kind == SyscallKind.accept)
        logf("kind:s args:%s", kind, args);
        static if(kind == SyscallKind.accept || kind == SyscallKind.read) {
            auto state = descriptor.readerState;
            logf("%s syscall state is %d. Fiber %x", name, state, cast(void*)currentFiber);
            final switch (state) with (ReaderState) {
            case EMPTY:
                logf("EMPTY - enqueue reader");
                if (!descriptor.enqueueReader(&await)) goto L_start;
                // changed state to e.g. READY or UNCERTAIN in meantime, may need to reschedule
                if (descriptor.readerState != EMPTY) descriptor.scheduleReaders(fd, currentFiber.numScheduler);
                FiberExt.yield();
                goto L_start;
            case UNCERTAIN:
                descriptor.changeReader(UNCERTAIN, READING); // may became READY or READING
                goto case READING;
            case READY:
                descriptor.changeReader(READY, READING); // always succeeds if 1 fiber reads
                goto case READING;
            case READING:
                ssize_t resp = __syscall(ident, fd, args);
                static if (kind == SyscallKind.accept) {
                    if (resp >= 0) // for accept we never know if we emptied the queue
                        descriptor.changeReader(READING, UNCERTAIN);
                    else if (errno == ERR || errno == EAGAIN) {
                        if (descriptor.changeReader(READING, EMPTY))
                            goto case EMPTY;
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                }
                else static if (kind == SyscallKind.read) {
                    if (resp == args[1]) // length is 2nd in (buf, length, ...)
                        descriptor.changeReader(READING, UNCERTAIN);
                    else if(resp >= 0)
                        descriptor.changeReader(READING, EMPTY);
                    else if (errno == ERR || errno == EAGAIN) {
                        if (descriptor.changeReader(READING, EMPTY))
                            goto case EMPTY;
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                }
                else
                    static assert(0);
                return resp;
            }
        }
        else static if(kind == SyscallKind.write || kind == SyscallKind.connect) {
            auto state = descriptor.writerState;
            logf("%s syscall state is %d. Fiber %x", name, state, cast(void*)currentFiber);
            final switch (state) with (WriterState) {
            case FULL:
                logf("FULL FD=%d Fiber %x", fd, cast(void*)currentFiber);
                if (!descriptor.enqueueWriter(&await)) goto L_start;
                // changed state to e.g. READY or UNCERTAIN in meantime, may need to reschedule
                if (descriptor.writerState != FULL) descriptor.scheduleWriters(fd, currentFiber.numScheduler);
                FiberExt.yield();
                goto L_start;
            case UNCERTAIN:
                logf("UNCERTAIN on FD=%d Fiber %x", fd, cast(void*)currentFiber);
                descriptor.changeWriter(UNCERTAIN, WRITING); // may became READY or WRITING
                goto case WRITING;
            case READY:
                descriptor.changeWriter(READY, WRITING); // always succeeds if 1 fiber writes
                goto case WRITING;
            case WRITING:
                ssize_t resp = __syscall(ident, fd, args);
                static if (kind == SyscallKind.connect) {
                    if(resp >= 0) {
                        descriptor.changeWriter(WRITING, READY);
                    }
                    else if (errno == ERR || errno == EALREADY) {
                        if (descriptor.changeWriter(WRITING, FULL)) {
                            goto case FULL;
                        }
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                    return resp;
                }
                else {
                    if (resp == args[1]) // (buf, len) args to syscall
                        descriptor.changeWriter(WRITING, UNCERTAIN);
                    else if(resp >= 0) {
                        logf("Short-write on FD=%d, become FULL", fd);
                        descriptor.changeWriter(WRITING, FULL);
                    }
                    else if (errno == ERR || errno == EAGAIN) {
                        if (descriptor.changeWriter(WRITING, FULL)) {
                            logf("Sudden block on FD=%d, become FULL", fd);
                            goto case FULL;
                        }
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                    return resp;
                }
            }
        }
        assert(0);
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

extern(C) ssize_t accept(int sockfd, sockaddr *addr, socklen_t *addrlen)
{
    return universalSyscall!(SYS_ACCEPT, "accept", SyscallKind.accept, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);    
}

extern(C) ssize_t connect(int sockfd, const sockaddr *addr, socklen_t *addrlen)
{
    return universalSyscall!(SYS_CONNECT, "connect", SyscallKind.connect, Fcntl.explicit, EINPROGRESS)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);
}

extern(C) ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
                      const sockaddr *dest_addr, socklen_t addrlen)
{
    return universalSyscall!(SYS_SENDTO, "sendto", SyscallKind.write, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) buf, len, flags, cast(size_t) dest_addr, cast(size_t) addrlen);
}

extern(C) size_t recv(int sockfd, void *buf, size_t len, int flags) nothrow {
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

extern(C) private ssize_t poll(pollfd *fds, nfds_t nfds, int timeout)
{
    nothrow bool nonBlockingCheck(ref ssize_t result, int timeout) {
        bool uncertain;
    L_cacheloop:
        foreach (ref fd; fds[0..nfds]) {
            interceptFd!(Fcntl.explicit)(fd.fd);
            fd.revents = 0;
            auto descriptor = descriptors.ptr + fd.fd;
            if (fd.events & POLLIN) {
                auto state = descriptor.readerState;
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
                auto state = descriptor.writerState;
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
            ssize_t p = raw_poll(fds, nfds, 0);
            if (p != 0 || timeout == 0) {
                result = p;
                logf("Raw poll returns %d", result);
                return true;
            }
        }
        else {
            ssize_t j = 0;
            foreach (i; 0..nfds) {
                if (fds[i].revents) {
                    j++;
                }
            }
            logf("Using our own event cache: %d events", j);
            if (j > 0 || timeout == 0) {
                result = cast(ssize_t)j;
                return true;
            }
        }
        return false;
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
            if (fd.fd < 0 || fd.fd >= descriptors.length) {
                errno = EBADF;
                return -1;
            }
            fd.revents = 0;
        }
        ssize_t result = 0;
        if (nonBlockingCheck(result, timeout)) return result;
        FiberExt fiber = currentFiber;
        shared AwaitingFiber aw = shared(AwaitingFiber)(cast(shared)&fiber);
        foreach (i; 0..nfds) {
            if (fds[i].events & POLLIN)
                descriptors[fds[i].fd].enqueueReader(&aw);
            else if(fds[i].events & POLLOUT)
                descriptors[fds[i].fd].enqueueWriter(&aw);
        }
        if (timeout > 0) {
            auto tm = timerEntry(&fiber, timeout.msecs);
            timeQueue.insert(&tm);
            FiberExt.yield();
            timeQueue.cancel(&tm);
        }
        else {
            FiberExt.yield();
        }
        foreach (i; 0..nfds) {
            if (fds[i].events & POLLIN)
                descriptors[fds[i].fd].removeReader(&aw);
            else if(fds[i].events & POLLOUT)
                descriptors[fds[i].fd].removeWriter(&aw);
        }
        logf("Woke up after select %x. WakeFD=%d", cast(void*)currentFiber, currentFiber.wakeFd);
        if (currentFiber.wakeFd == wokenUpByTimer) return 0;
        else {
            nonBlockingCheck(result, timeout);
            return result;
        }
    }
}

extern(C) private ssize_t nanosleep(const timespec* req, const timespec* rem) {
    if (currentFiber !is null) {
        delay(req);
        return 0;
    } else {
        __syscall(SYS_NANOSLEEP, req, rem);
        return 0;
    }
}

extern(C) private int close(int fd) nothrow
{
    logf("HOOKED CLOSE FD=%d", fd);
    deregisterFd(fd);
    return cast(int)__syscall(SYS_CLOSE, fd);
}

int gettid()
{
    return cast(int)__syscall(SYS_GETTID);
}
