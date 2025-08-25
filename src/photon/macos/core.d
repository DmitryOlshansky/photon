module photon.macos.core;
version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;
version(Darwin):
package(photon):

import std.stdio;
import std.string;
import std.format;
import std.exception;
import std.conv;
import std.array;
import std.meta;
import std.random;

import core.thread;
import core.internal.spinlock;
import core.sys.posix.sys.types;
import core.sys.posix.sys.socket;
import core.sys.posix.poll;
import core.sys.posix.netinet.in_;
import core.sys.freebsd.unistd;
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
import core.sys.darwin.mach.thread_act;

import photon.macos.support;
import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.threadpool;

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

struct thread;
alias thread_t = thread*;
extern(C) thread_t current_thread();

// T becomes thread-local b/c it's stolen from shared resource
auto steal(T)(ref shared T arg)
{
    for (;;) {
        auto v = atomicLoad(arg);
        if(cas(&arg, v, cast(shared(T))null)) return v;
    }
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

shared size_t timerId;

struct Timer {
nothrow:
    this(size_t id) {
        this.id = id;
    }

    ///
    void wait(const timespec* ts) {
        wait(ts.tv_sec.seconds + ts.tv_nsec.nsecs);
    }

    ///
    void wait(Duration dur) {
        arm(dur);
        FiberExt.yield();
    }

    void arm(Duration dur) {
        KEvent event;
        event.ident = id;
        event.filter = EVFILT_TIMER;
        event.flags = EV_ADD | EV_ENABLE | EV_ONESHOT;
        event.fflags = 0;
        event.data = dur.total!"msecs";
        event.udata = cast(void*)(cast(size_t)cast(void*)currentFiber | 0x1);
        timespec timeout;
        timeout.tv_nsec = 1000;
        kevent(getCurrentKqueue, &event, 1, null, 0, &timeout).checked("arming the timer");
    }

    void disarm() {
        KEvent event;
        event.ident = id;
        event.filter = EVFILT_TIMER;
        event.flags = EV_DELETE;
        event.fflags = 0;
        timespec timeout;
        timeout.tv_nsec = 1000;
        kevent(getCurrentKqueue, &event, 1, null, 0, &timeout).checked("canceling the timer");
    }

    private void waitThread(const timespec* ts) {
        auto dur = ts.tv_sec.seconds + ts.tv_nsec.nsecs;
        KEvent event;
        event.ident = id;
        event.filter = EVFILT_TIMER;
        event.flags = EV_ADD | EV_ENABLE | EV_ONESHOT;
        event.fflags = 0;
        event.data = dur.total!"msecs";
        event.udata = cast(void*)(cast(size_t)mach_thread_self() << 1);
        timespec timeout;
        timeout.tv_nsec = 1000;
        kevent(getCurrentKqueue, &event, 1, null, 0, &timeout).checked("arming the timer for a thread");
    }

    private size_t id;
}

/// Allocate a timer
public nothrow auto timer() {
    return Timer(atomicFetchAdd(timerId, 1));
}


public struct Event {
nothrow:
    @disable this(this);

    this(bool signaled) {
        int[2] fds;
        pipe(fds).checked;
        if (signaled) trigger();
        this.fds = fds;
    }

    private int fd() shared { return fds[0]; }

    private int fd() { return fds[0]; }

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

    private void reset() {
        waitAndReset();
    }

    private void reset() shared {
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
        pipe(fds).checked;
        if (initial > 0) {
            trigger(initial);
        }
        this.fds = fds;
    }

    private int fd() { return fds[0]; }

    private int fd() shared { return fds[0]; }
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

    private void reset() {
        wait();
    }

    private void reset() shared {
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

struct AwaitingFiber {
    shared FiberExt fiber;
    AwaitingFiber* next;

    void scheduleAll(int wakeFd, size_t nsched) nothrow
    {
        auto w = &this;
        FiberExt head;
        // first process all AwaitingFibers since they are on stack
        do {
            auto fiber = steal(w.fiber);
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

    enum PAGESIZE = 4096;
    
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
}

FiberExt currentFiber;
shared int alive; // count of non-terminated Fibers scheduled

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    int kq;
    int padding;
}
static assert(SchedulerBlock.sizeof == 64);

package(photon) shared SchedulerBlock[] scheds;

enum int MAX_EVENTS = 500;
enum int SIGNAL = 42;

void notifyEventloop(size_t n) nothrow {
    KEvent event;
    event.ident = n;
    event.filter = EVFILT_USER;
    event.flags = EV_ADD | EV_ENABLE | EV_ONESHOT;
    event.fflags = NOTE_TRIGGER;
    logf("Notifying event loop %d", n);
    kevent(scheds[n].kq, &event, 1, null, 0, null).checked("notifying event loop");
}

int getCurrentKqueue() nothrow {
    return currentFiber !is null ? scheds[currentFiber.numScheduler].kq : scheds[0].kq;
}

package(photon) void schedulerEntry(size_t n)
{
    int tid = gettid();
    /*cpu_set_t mask;
    CPU_SET(n, &mask);
    sched_setaffinity(tid, mask.sizeof, &mask).checked("sched_setaffinity");
    */
    shared SchedulerBlock* sched = scheds.ptr + n;
    void onTermination() {
        atomicOp!"-="(alive, 1);
        if (alive == 0) {
            foreach (i; 0..scheds.length) {
                notifyEventloop(i);
            }
        }
    }
    while (alive > 0) {
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
                logf("Fiber %s terminated", cast(void*)f);
                onTermination();
            }
            f = next;
        }
        processEventsEntry(n);
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

extern(C) void graceful_shutdown_on_signal(int, siginfo_t*, void*)
{
    version(photon_tracing) printStats();
    _exit(9);
}

version(photon_tracing) 
void printStats()
{
    // TODO: report on various events in eventloop/scheduler
    string msg = "Tracing report:\n\n";
    write(2, msg.ptr, msg.length);
}

__gshared ssize_t function (const timespec* req, const timespec* rem) libcNanosleep;
Timer[] timerPool; // thread-local pool of preallocated timers

nothrow auto getSleepTimer() {
    Timer tm;
    if (timerPool.length == 0) {
        tm = timer();
    } else {
        tm = timerPool[$-1];
        timerPool.length = timerPool.length-1;
    }
    return tm;
}

nothrow void freeSleepTimer(Timer tm) {
    timerPool.assumeSafeAppend();
    timerPool ~= tm;
}

/// Delay fiber execution by `req` duration.
public nothrow void delay(T)(T req)
if (is(T : const timespec*) || is(T : Duration)) {
    auto tm = getSleepTimer();
    tm.wait(req);
    freeSleepTimer(tm);
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

public void startloop()
{
    int threads = cast(int)sysconf(_SC_NPROCESSORS_ONLN).checked;
    debug(photon_single) {
        threads = 1;
    }
    ssize_t fdMax = sysconf(_SC_OPEN_MAX).checked;
    descriptors = (cast(shared(Descriptor*)) mmap(null, fdMax * Descriptor.sizeof, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))[0..fdMax];
    scheds = new SchedulerBlock[threads];
    foreach(ref sched; scheds) {
        sched.queue = IntrusiveQueue!(FiberExt, RawEvent)(RawEvent(0));
        sched.kq = kqueue();
        enforce(sched.kq != -1);
    }
    initWorkQueues(threads);
}

void processEventsEntry(size_t n)
{
    KEvent[MAX_EVENTS] ke;
    int cnt = kevent(scheds[n].kq, null, 0, ke.ptr, MAX_EVENTS, null);
    enforce(cnt >= 0);
    for (int i = 0; i < cnt; i++) {
        auto fd = cast(int)ke[i].ident;
        auto filter = ke[i].filter;
        auto descriptor = descriptors.ptr + fd;
        if (filter == EVFILT_READ) {
            logf("Read event for fd=%d", fd);
            auto state = descriptor.readerState;
            logf("read state = %d", state);                
            final switch(descriptor.readerState) with(ReaderState) {
                case EMPTY:
                    logf("Trying to schedule readers");
                    descriptor.changeReader(EMPTY, READY);
                    descriptor.scheduleReaders(fd, n);
                    logf("Scheduled readers");
                    break;
                case UNCERTAIN:
                    descriptor.changeReader(UNCERTAIN, READY);
                    descriptor.scheduleReaders(fd, n);
                    break;
                case READING:
                    if (!descriptor.changeReader(READING, UNCERTAIN)) {
                        if (descriptor.changeReader(EMPTY, UNCERTAIN)) // if became empty - move to UNCERTAIN and wake readers
                            descriptor.scheduleReaders(fd, n);
                    }
                    break;
                case READY:
                    descriptor.scheduleReaders(fd, n);
                    break;
            }
        }
        if (filter == EVFILT_WRITE) {
            logf("Write event for fd=%d", fd);
            auto state = descriptor.writerState;
            logf("write state = %d", state);
            final switch(state) with(WriterState) { 
                case FULL:
                    descriptor.changeWriter(FULL, READY);
                    descriptor.scheduleWriters(fd, n);
                    break;
                case UNCERTAIN:
                    descriptor.changeWriter(UNCERTAIN, READY);
                    descriptor.scheduleWriters(fd, n);
                    break;
                case WRITING:
                    if (!descriptor.changeWriter(WRITING, UNCERTAIN)) {
                        if (descriptor.changeWriter(FULL, UNCERTAIN)) // if became full - move to UNCERTAIN and wake writers
                            descriptor.scheduleWriters(fd, n);
                    }
                    break;
                case READY:
                    descriptor.scheduleWriters(fd, n);
                    break;
            }
            logf("Awaits %x", cast(void*)descriptor.writeWaiters);
        }
        if (filter == EVFILT_TIMER) {
            size_t udata = cast(size_t)ke[i].udata;
            if (udata & 0x1) {
                auto ptr = udata & ~1;
                FiberExt fiber = *cast(FiberExt*)&ptr;
                fiber.wakeFd = wokenUpByTimer;
                fiber.schedule(n);
            }
            else {
                auto thread = cast(thread_act_t)udata >> 1;
                thread_resume(thread);
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
    if (cas(&descriptors[fd].state, DescriptorState.NOT_INITED, DescriptorState.INITIALIZING)) {
        logf("First use, registering fd = %s", fd);
        static if(needsFcntl == Fcntl.explicit) {
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK).checked;
            logf("Setting FCNTL. %x", cast(void*)currentFiber);
        }
        KEvent[2] ke;
        ke[0].ident = fd;
        ke[1].ident = fd;
        ke[0].filter = EVFILT_READ;
        ke[1].filter = EVFILT_WRITE;
        ke[1].flags = ke[0].flags = EV_ADD | EV_ENABLE | EV_CLEAR;
        kevent(getCurrentKqueue, ke.ptr, 2, null, 0, null).checked;
    }
}

void deregisterFd(int fd) nothrow {
    if(fd >= 0 && fd < descriptors.length) {
        auto descriptor = descriptors.ptr + fd;
        atomicStore(descriptor._writerState, WriterState.READY);
        atomicStore(descriptor._readerState, ReaderState.EMPTY);
        descriptor.scheduleReaders(fd, currentFiber.numScheduler);
        descriptor.scheduleWriters(fd, currentFiber.numScheduler);
        atomicStore(descriptor.state, DescriptorState.NOT_INITED);
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
        if (atomicLoad(descriptor.state) == DescriptorState.THREADPOOL) {
            logf("%s syscall THREADPOLL FD=%d", name, fd);
            //TODO: offload syscall to thread-pool
            return __syscall(ident, fd, args);
        }
    L_start:
        shared AwaitingFiber await = AwaitingFiber(cast(shared)currentFiber, null);
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
            if (p != 0) {
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
            shared AwaitingFiber aw = shared(AwaitingFiber)(cast(shared)currentFiber);
            Timer tm = timer();
            tm.arm(timeout.msecs);
            FiberExt.yield();
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
        shared AwaitingFiber aw = shared(AwaitingFiber)(cast(shared)currentFiber);
        foreach (i; 0..nfds) {
            if (fds[i].events & POLLIN)
                descriptors[fds[i].fd].enqueueReader(&aw);
            else if(fds[i].events & POLLOUT)
                descriptors[fds[i].fd].enqueueWriter(&aw);
        }
        if (timeout > 0) {
            Timer tm = timer();
            tm.arm(timeout.msecs);
            FiberExt.yield();
            tm.disarm();
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
        auto timer = getSleepTimer();
        timer.waitThread(req);
        thread_suspend(mach_thread_self());
        return 0;
    }
}

extern(C) private ssize_t close(int fd) nothrow
{
    logf("HOOKED CLOSE FD=%d", fd);
    deregisterFd(fd);
    return cast(int)__syscall(SYS_CLOSE, fd);
}


int gettid()
{
    return cast(int)__syscall(SYS_GETTID);
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

ssize_t raw_poll(pollfd *fds, nfds_t nfds, int timeout)
{
    logf("Raw poll");
    return __syscall(SYS_POLL, cast(size_t)fds, cast(size_t) nfds, timeout);
}
