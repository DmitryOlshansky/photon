module photon.linux.core;
version(linux):
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
import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.threadpool;

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
        byte[8] bytes = void;
        ssize_t r;
        do {
            r = raw_read(fd, bytes.ptr, 8);
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
nothrow:
    private int evfd;

    this(bool signaled) {
        evfd = eventfd(signaled ? 1 : 0, EFD_NONBLOCK).checked("Event constructor");
        interceptFd!(Fcntl.noop)(evfd);
    }

    int fd() { return evfd; }

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
}

///
public auto event(bool triggered) {
    return Event(triggered);
}

///
public struct Semaphore {
nothrow:
    private int evfd;
    ///
    this(int count) {
        evfd = eventfd(count, EFD_NONBLOCK | EFD_SEMAPHORE).checked("Semaphore constructor");
        interceptFd!(Fcntl.noop)(evfd);
    }

    int fd() { return evfd; }

    @disable this(this);

    ///
    void wait() {
        ubyte[8] bytes = void;
        ssize_t r;
        do {
            // go through event loop
            r = read(evfd, bytes.ptr, bytes.sizeof);
        } while (r < 0 && errno == EINTR);
    }

    void wait() shared {
        this.unshared.wait();
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

/// A fiber-friendly timer.
public struct Timer {
nothrow:
    private int timerfd;


    int fd() {
        return timerfd;
    }

    static void duration2ts(timespec *ts, Duration d) {
        auto total = d.total!"nsecs"();
        ts.tv_sec = total / 1_000_000_000;
        ts.tv_nsec = total % 1_000_000_000;
    }

    private void arm(const timespec *ts_timeout) {
        itimerspec its;
        its.it_value = *ts_timeout;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 0;
        timerfd_settime(timerfd, 0, &its, null);
    }

    private void arm(Duration timeout) {
        timespec ts_timeout;
        duration2ts(&ts_timeout, timeout); //convert duration to timespec
        arm(&ts_timeout);
    }

    private void disarm() {
        itimerspec its; // zeros
        timerfd_settime(timerfd, 0, &its, null);
    }

    /// Wait for the timer to trigger.
    void wait(T)(T duration)
    if (is(T : const timespec*) || is(T : Duration)) {
        arm(duration);
        union U {
            ulong timeouts;
            ubyte[8] bytes;
        }
        U u = void;
        ssize_t r;
        do {
            r = read(timerfd, u.bytes.ptr, U.sizeof);
        } while (r < 0 && errno == EINTR);
        disarm();
    }

    void dispose() {
        close(timerfd).checked;
    }
}

///
public nothrow Timer timer() {
    int timerfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC).checked;
    interceptFd!(Fcntl.noop)(timerfd);
    return Timer(timerfd);
}

struct AwaitingFiber {
    shared FiberExt fiber;
    AwaitingFiber* next;

    void scheduleAll(int wakeFd, size_t from) nothrow
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
            auto next = head.next; // schedule uses .next pointer
            head.schedule(from);
            head = next;
        }
    }
}

class FiberExt : Fiber {
    FiberExt next;
    uint numScheduler;
    int wakeFd; // recieves fd that woken us up

    this(void function() fn, uint numSched) nothrow {
        super(fn);
        numScheduler = numSched;
    }

    this(void delegate() dg, uint numSched) nothrow {
        super(dg);
        numScheduler = numSched;
    }

    void schedule(size_t from) nothrow
    {
        scheds[numScheduler].queue.push(this);
        if (from != numScheduler) {
            scheds[numScheduler].queue.event.trigger();
        }
    }
}

FiberExt currentFiber;
shared RawEvent termination; // termination event, triggered once last fiber exits
shared pthread_t eventLoop; // event loop, runs outside of D runtime
shared int alive; // count of non-terminated Fibers scheduled

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

///
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
        resp = poll(fds, args.length, -1);
    } while (resp < 0 && errno == EINTR);
    foreach (idx, ref fd; fds[0..args.length]) {
        if (fd.revents & POLL_IN) {
            ubyte[8] tmp;
            read(fds[idx].fd, tmp.ptr, tmp.sizeof);
            return idx;
        }
    }
    assert(0);
}

///
public size_t awaitAny(Awaitable)(Awaitable[] args)
if (allSatisfy!(isAwaitable, Awaitable)) {
    pollfd* fds = cast(pollfd*)calloc(args.length, pollfd.sizeof);
    scope(exit) free(fds);
    foreach (i, ref arg; args) {
        fds[i].fd = arg.fd;
        fds[i].events = POLL_IN;
    }
    ssize_t resp;
    do {
        resp = poll(fds, args.length, -1);
    } while (resp < 0 && errno == EINTR);
    foreach (idx, ref fd; fds[0..args.length]) {
        if (fd.revents & POLL_IN) {
            ubyte[8] tmp;
            read(fds[idx].fd, tmp.ptr, tmp.sizeof);
            return idx;
        }
    }
    assert(0);
}

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    int event_loop_fd;
    int signal_loop_fd;
    size_t padding;
}
static assert(SchedulerBlock.sizeof == 64);

package(photon) shared SchedulerBlock[] scheds;

enum int MAX_EVENTS = 500;
enum int SIGNAL = 42;

package(photon) void schedulerEntry(size_t n)
{
    int tid = gettid();
    cpu_set_t mask;
    CPU_SET(n, &mask);
    if (sched_setaffinity(tid, mask.sizeof, &mask) < 0) {
        photon.linux.support.perror("sched_setaffinity");
    }
    shared SchedulerBlock* sched = scheds.ptr + n;
    while (alive > 0) {
        FiberExt f = sched.queue.drain();
        while(f !is null) {
            auto next = f.next; //save next, it will be reused on scheduling
            currentFiber = f;
            logf("Fiber %x started", cast(void*)f);
            try {
                f.call();
            }
            catch (Throwable e) {
                stderr.writeln(e);
                atomicOp!"-="(alive, 1);
                if (alive == 0) termination.trigger();
            }
            if (f.state == FiberExt.State.TERM) {
                logf("Fiber %s terminated", cast(void*)f);
                atomicOp!"-="(alive, 1);
                if (alive == 0) termination.trigger();
            }
            f = next;
        }
        processEventsEntry(n);
    }
    termination.trigger();
    foreach (ref s; scheds) {
        s.queue.event.trigger();
    }
    terminateWorkQueues();
}

/// Convenience overload for functions.
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
    logf("Assigned %x -> %d scheduler", cast(void*)f, choice);
    f.schedule(choice);
    scheds[choice].queue.event.trigger();
}

/// Convenience overload for goOnSameThread that accepts functions.
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
    scheds[choice].queue.event.trigger();
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
    void scheduleReaders()(int wakeFd, size_t from) {
        auto w = steal(_readerWaits);
        if (w) w.unshared.scheduleAll(wakeFd, from);
    }

    // try to schedule writers, ditto
    void scheduleWriters()(int wakeFd, size_t from) {
        auto w = steal(_writerWaits);
        if (w) w.unshared.scheduleAll(wakeFd, from);
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

public void startloop()
{
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
        sched.event_loop_fd = cast(int)epoll_create1(0).checked("ERROR: Failed to create event-loop!");
        // use RT signals, disable default termination on signal received
        sigset_t mask;
        sigemptyset(&mask);
        sigaddset(&mask, SIGNAL);
        pthread_sigmask(SIG_BLOCK, &mask, null).checked;
        sched.signal_loop_fd = cast(int)signalfd(-1, &mask, 0).checked("ERROR: Failed to create signalfd!");

        epoll_event event;
        event.events = EPOLLIN;
        event.data.fd = sched.signal_loop_fd;
        epoll_ctl(sched.event_loop_fd, EPOLL_CTL_ADD, sched.signal_loop_fd, &event).checked;

        event.events = EPOLLIN;
        event.data.fd = sched.queue.event.fd;
        epoll_ctl(sched.event_loop_fd, EPOLL_CTL_ADD, sched.queue.event.fd, &event).checked;
    }


    termination = RawEvent(0);
    epoll_event event;
    event.events = EPOLLIN;
    event.data.fd = termination.fd;
    foreach(ref sched; scheds) {
        epoll_ctl(sched.event_loop_fd, EPOLL_CTL_ADD, termination.fd, &event).checked;
    }

    {

        sigaction_t action;
        action.sa_sigaction = &graceful_shutdown_on_signal;
        sigaction(SIGTERM, &action, null).checked;
    }

    initWorkQueues(threads);
}

void processEventsEntry(size_t numSched)
{
    //for (;;) {
    epoll_event[MAX_EVENTS] events = void;
    signalfd_siginfo[20] fdsi = void;
    auto sched = &scheds[numSched];
    int r;
    do {
        r = epoll_wait(sched.event_loop_fd, events.ptr, MAX_EVENTS, -1);
    } while (r < 0 && errno == EINTR);
    checked(r);
    for (int n = 0; n < r; n++) {
        int fd = events[n].data.fd;
        if (fd == termination.fd) {
            foreach(ref s; scheds) s.queue.event.trigger();
            return;
        }
        else if (fd == sched.queue.event.fd) {
            sched.queue.event.waitAndReset();
        }
        else if (fd == sched.signal_loop_fd) {
            logf("Intercepted our aio SIGNAL");
            ssize_t r2 = raw_read(sched.signal_loop_fd, &fdsi, fdsi.sizeof);
            logf("aio events = %d", r2 / signalfd_siginfo.sizeof);
            if (r2 % signalfd_siginfo.sizeof != 0)
                checked(r2, "ERROR: failed read on signalfd");

            for(int i = 0; i < r2 / signalfd_siginfo.sizeof; i++) { //TODO: stress test multiple signals
                logf("Processing aio event idx = %d", i);
                if (fdsi[i].ssi_signo == SIGNAL) {
                    logf("HIT our SIGNAL");
                    auto fiber = cast(FiberExt)cast(void*)fdsi[i].ssi_ptr;
                    fiber.schedule(numSched);
                }
            }
        }
        else {
            auto descriptor = descriptors.ptr + fd;
            if (descriptor.state == DescriptorState.NONBLOCKING) {
                if (events[n].events & EPOLLIN) {
                    logf("Read event for fd=%d", fd);
                    auto state = descriptor.readerState;
                    logf("read state = %d", state);
                    final switch(state) with(ReaderState) {
                        case EMPTY:
                            logf("Trying to schedule readers");
                            descriptor.changeReader(EMPTY, READY);
                            descriptor.scheduleReaders(fd, numSched);
                            logf("Scheduled readers");
                            break;
                        case UNCERTAIN:
                            descriptor.changeReader(UNCERTAIN, READY);
                            descriptor.scheduleReaders(fd, numSched);
                            logf("Scheduled readers");
                            break;
                        case READING:
                            if (!descriptor.changeReader(READING, UNCERTAIN)) {
                                if (descriptor.changeReader(EMPTY, UNCERTAIN)) // if became empty - move to UNCERTAIN and wake readers
                                    descriptor.scheduleReaders(fd, numSched);
                            }
                            break;
                        case READY:
                            descriptor.scheduleReaders(fd, numSched);
                            break;
                    }
                    logf("Awaits %x", cast(void*)descriptor.readWaiters);
                }
                if (events[n].events & EPOLLOUT) {
                    logf("Write event for fd=%d", fd);
                    auto state = descriptor.writerState;
                    logf("write state = %d", state);
                    final switch(state) with(WriterState) {
                        case FULL:
                            descriptor.changeWriter(FULL, READY);
                            descriptor.scheduleWriters(fd, numSched);
                            break;
                        case UNCERTAIN:
                            descriptor.changeWriter(UNCERTAIN, READY);
                            descriptor.scheduleWriters(fd, numSched);
                            break;
                        case WRITING:
                            if (!descriptor.changeWriter(WRITING, UNCERTAIN)) {
                                if (descriptor.changeWriter(FULL, UNCERTAIN)) // if became empty - move to UNCERTAIN and wake writers
                                    descriptor.scheduleWriters(fd, numSched);
                            }
                            break;
                        case READY:
                            descriptor.scheduleWriters(fd, numSched);
                            break;
                    }
                    logf("Awaits %x", cast(void*)descriptor.writeWaiters);
                }
            }
        }
    }
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
        if (epoll_ctl(scheds[n].event_loop_fd, EPOLL_CTL_ADD, fd, &event) < 0 && errno == EPERM) {
            logf("isSocket = false FD = %s", fd);
            descriptors[fd].state = DescriptorState.THREADPOOL;
        }
        else {
            logf("isSocket = true FD = %s", fd);
            descriptors[fd].state = DescriptorState.NONBLOCKING;
        }
    }
}

void deregisterFd(int fd) nothrow {
    if(fd >= 0 && fd < descriptors.length) {
        auto descriptor = descriptors.ptr + fd;
        atomicStore(descriptor._writerState, WriterState.READY);
        atomicStore(descriptor._readerState, ReaderState.EMPTY);
        size_t choice = currentFiber !is null ? currentFiber.numScheduler : -1;
        descriptor.scheduleReaders(fd, choice);
        descriptor.scheduleWriters(fd, choice);
        atomicStore(descriptor.state, DescriptorState.NOT_INITED);
    }
}

ssize_t universalSyscall(size_t ident, string name, SyscallKind kind, Fcntl fcntlStyle, ssize_t ERR, T...)
                        (int fd, T args) nothrow {
    if (currentFiber is null) {
        logf("%s PASSTHROUGH FD=%s", name, fd);
        return syscall(ident, fd, args);
    }
    else {
        logf("HOOKED %s FD=%d", name, fd);
        interceptFd!(fcntlStyle)(fd);
        shared(Descriptor)* descriptor = descriptors.ptr + fd;
        if (atomicLoad(descriptor.state) == DescriptorState.THREADPOOL) {
            logf("%s syscall THREADPOLL FD=%d", name, fd);
            //TODO: offload syscall to thread-pool
            auto result = offload(() {
                auto ret = syscall(ident, fd, args);
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
                ssize_t resp = syscall(ident, fd, args);
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
                ssize_t resp = syscall(ident, fd, args);
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
    return universalSyscall!(SYS_READ, "READ", SyscallKind.read, Fcntl.explicit, EWOULDBLOCK)
        (fd, cast(size_t)buf, count);
}

extern(C) ssize_t write(int fd, const void *buf, size_t count)
{
    return universalSyscall!(SYS_WRITE, "WRITE", SyscallKind.write, Fcntl.explicit, EWOULDBLOCK)
        (fd, cast(size_t)buf, count);
}

extern(C) ssize_t accept(int sockfd, sockaddr *addr, socklen_t *addrlen)
{
    return universalSyscall!(SYS_ACCEPT, "accept", SyscallKind.accept, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);
}

extern(C) ssize_t accept4(int sockfd, sockaddr *addr, socklen_t *addrlen, int flags)
{
    return universalSyscall!(SYS_ACCEPT4, "accept4", SyscallKind.accept, Fcntl.sock, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen, flags);
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
    return universalSyscall!(SYS_RECVFROM, "RECVFROM", SyscallKind.read, Fcntl.msg, EWOULDBLOCK)
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
            shared AwaitingFiber aw = shared(AwaitingFiber)(cast(shared)currentFiber);
            Timer tm = timer();
            descriptors[tm.fd].enqueueReader(&aw);
            scope(exit) tm.dispose();
            tm.arm(timeout.msecs);
            logf("Timer fd=%d", tm.fd);
            Fiber.yield();
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
        int timeoutFd = -1;
        if (timeout > 0) {
            Timer tm = timer();
            timeoutFd = tm.fd;
            scope(exit) tm.dispose();
            tm.arm(timeout.msecs);
            descriptors[tm.fd].enqueueReader(&aw);
            Fiber.yield();
            tm.disarm();
            atomicStore(descriptors[tm.fd]._readerWaits, cast(shared(AwaitingFiber)*)null);
        }
        else {
            Fiber.yield();
        }
        foreach (i; 0..nfds) {
            if (fds[i].events & POLLIN)
                descriptors[fds[i].fd].removeReader(&aw);
            else if(fds[i].events & POLLOUT)
                descriptors[fds[i].fd].removeWriter(&aw);
        }
        logf("Woke up after select %x. WakeFD=%d", cast(void*)currentFiber, currentFiber.wakeFd);
        if (currentFiber.wakeFd == timeoutFd) return 0;
        else {
            nonBlockingCheck(result, 0);
            return result;
        }
    }
}

extern(C) private ssize_t nanosleep(const timespec* req, const timespec* rem) {
    if (currentFiber !is null) {
        delay(req);
        return 0;
    } else {
        return syscall(SYS_NANOSLEEP, cast(size_t)req, cast(size_t)rem);
    }
}

extern(C) private ssize_t close(int fd) nothrow
{
    logf("HOOKED CLOSE FD=%d", fd);
    deregisterFd(fd);
    return cast(int)syscall(SYS_CLOSE, fd);
}
