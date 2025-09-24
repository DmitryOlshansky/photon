module photon.windows.core;
version(Windows):
package(photon):

import core.sys.windows.core;
import core.sys.windows.winsock2;
import core.atomic;
import core.thread;
import core.internal.spinlock;
import std.exception;
import std.windows.syserror;
import core.stdc.stdlib;
import std.random;
import std.stdio;
import std.traits;
import std.meta;
import std.concurrency;

import rewind.map;

import mecca.time_queue;

import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.windows.support;
import photon.task;
import photon.threadpool;

shared struct RawEvent {
nothrow:
    this(bool signaled) {
        ev = cast(shared(HANDLE))CreateEventA(null, FALSE, signaled, null);
        assert(ev != null, "Failed to create RawEvent");
    }

    void waitAndReset() {
        auto ret = WaitForSingleObject(cast(HANDLE)ev, INFINITE);
        assert(ret == WAIT_OBJECT_0, "Failed while waiting on event");
    }
    
    void trigger() { 
        auto ret = SetEvent(cast(HANDLE)ev);
        assert(ret != 0);
    }
    
    HANDLE ev;
}

struct MultiAwait
{
    int n;
    void delegate() trigger; 
    MultiAwaitBox* box;
}

struct MultiAwaitBox {
    shared size_t refCount;
    shared FiberExt fiber;
}

extern(Windows) VOID waitCallback(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WAIT  Wait, TP_WAIT_RESULT WaitResult) {
    auto fiber = cast(FiberExt)Context;
    fiber.schedule(size_t.max, WAKE_TRIGGER);
}


extern(Windows) VOID waitAnyCallback(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WAIT  Wait, TP_WAIT_RESULT WaitResult) {
    auto await = cast(MultiAwait*)Context;
    auto fiber = cast()steal(await.box.fiber);
    if (fiber) {
        logf("AwaitAny callback waking up on %d object", await.n);
        fiber.schedule(size_t.max, await.n);
    }
    else {
        logf("AwaitAny callback - triggering awaitable again");
        await.trigger();
    }
    auto cnt = atomicFetchSub(await.box.refCount, 1);
    if (cnt == 1) free(await.box);    
    free(await);
    CloseThreadpoolWait(Wait);
}

/// Event object
public struct Event {
nothrow:
    @disable this(this);

    this(bool signaled) {
        ev = cast(HANDLE)CreateEventA(null, FALSE, signaled, null);
        assert(ev != null, "Failed to create Event");
    }

    /// Wait for the event to be triggered, then reset and return atomically
    void waitAndReset() {
        auto wait = CreateThreadpoolWait(&waitCallback, cast(void*)currentFiber, &environ);
        checked(wait != null, "Failed to create threadpool wait object");
        SetThreadpoolWait(wait, cast(HANDLE)ev, null);
        FiberExt.yield();
        CloseThreadpoolWait(wait);
    }

    ///
    void waitAndReset() shared {
        this.unshared.waitAndReset();
    }

    private void registerForWaitAny(int n, MultiAwaitBox* box) {
        auto context = cast(MultiAwait*)calloc(1, MultiAwait.sizeof);
        context.box = box;
        context.n = n;
        context.trigger = cast(void delegate())&this.trigger;
        auto wait = CreateThreadpoolWait(&waitAnyCallback, cast(void*)context, &environ);
        checked(wait != null, "Failed to create threadpool wait object");
        SetThreadpoolWait(wait, cast(HANDLE)ev, null);
    }

    private void registerForWaitAny(int n, MultiAwaitBox* box) shared {
        this.unshared.registerForWaitAny(n, box);
    }
    
    /// Trigger the event.
    void trigger() { 
        auto ret = SetEvent(cast(HANDLE)ev);
        assert(ret != 0);
    }

    void trigger() shared {
        this.unshared.trigger();
    }
    
private:
    HANDLE ev;
}

///
public auto event(bool signaled) {
    return cast(shared)Event(signaled);
}

/// Semaphore object
public struct Semaphore {
nothrow:
    @disable this(this);

    this(int count) {
        // set max count to MacOS pipe limit
        sem = cast(HANDLE)CreateSemaphoreA(null, count, 4096, null);
        assert(sem != null, "Failed to create semaphore");
    }

    this(int count) shared {
        // set max count to MacOS pipe limit
        sem = cast(shared(HANDLE))CreateSemaphoreA(null, count, 4096, null);
        assert(sem != null, "Failed to create semaphore");
    }
    
    /// 
    void wait() {
        auto wait = CreateThreadpoolWait(&waitCallback, cast(void*)currentFiber, &environ);
        checked(wait != null, "Failed to create threadpool wait object");
        SetThreadpoolWait(wait, cast(HANDLE)sem, null);
        FiberExt.yield();
        CloseThreadpoolWait(wait);
    }

    void wait() shared {
        this.unshared.wait();
    }

    private void registerForWaitAny(int n, MultiAwaitBox* box) {
        auto context = cast(MultiAwait*)calloc(1, MultiAwait.sizeof);
        context.box = box;
        context.n = n;
        context.trigger = { this.trigger(1); };
        auto wait = CreateThreadpoolWait(&waitAnyCallback, cast(void*)context, &environ);
        checked(wait != null, "Failed to create threadpool wait object");
        SetThreadpoolWait(wait, cast(HANDLE)sem, null);
    }

    private void registerForWaitAny(int n, MultiAwaitBox* box) shared {
        this.unshared.registerForWaitAny(n, box);
    }

    
    /// 
    void trigger(int count) { 
        auto ret = ReleaseSemaphore(cast(HANDLE)sem, count, null);
        assert(ret);
    }

    ///
    void trigger(int count) shared {
        this.unshared.trigger(count);
    }

    /// 
    void dispose() {
        CloseHandle(cast(HANDLE)sem);
    }

    ///
    void dispose() shared {
        this.unshared.dispose();
    }
    
private:
    HANDLE sem;
}

///
public auto semaphore(int count) {
    return cast(shared)Semaphore(count);
}

///
struct Timer {
@trusted:
    alias Callback = void delegate() @safe nothrow;
    void wait(Duration dur) {
        delay(dur);
    }

    void stop() nothrow {}
    bool pending() nothrow { return false; }
    void rearm(Duration dur) nothrow {}
}

///
public auto timer() {
    return Timer();
}

///
public void delay(Duration req) {
    auto tm = Timer(); // Stateless on Windows
    tm.wait(req);
}

/// 
enum isAwaitable(E) = is (E : Event) || is (E : Semaphore) 
    || is(E : Event*) || is(E : Semaphore*);

///
public size_t awaitAny(Awaitable...)(auto ref Awaitable args) 
if (allSatisfy!(isAwaitable, Awaitable)) {
    auto box = cast(MultiAwaitBox*)calloc(1, MultiAwaitBox.sizeof);
    box.refCount = args.length;
    box.fiber = cast(shared)currentFiber;
    foreach (int i, ref v; args) {
        v.registerForWaitAny(i, box);
    }
    FiberExt.yield();
    return currentFiber.wakeUpObject;
}

///
public size_t awaitAny(Awaitable)(Awaitable[] args) 
if (allSatisfy!(isAwaitable, Awaitable)) {
    auto box = cast(MultiAwaitBox*)calloc(1, MultiAwaitBox.sizeof);
    box.refCount = args.length;
    box.fiber = cast(shared)currentFiber;
    foreach (int i, ref v; args) {
        v.registerForWaitAny(i, box);
    }
    FiberExt.yield();
    return currentFiber.wakeUpObject;
}

// fiber wakeup is due to an active FD or one of the following reasons
enum int WAKE_TRIGGER = -1;
enum int WAKE_TIMER = -2;
enum int WAKE_JOIN = -3;

enum TIMER_NUM_BINS = 256;
enum TIMER_NUM_LEVELS = 4;

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    HANDLE iocp; // IO Completion port
}
static assert(SchedulerBlock.sizeof == 64);

class FiberExt : Fiber { 
    FiberExt next;
    FiberExt back;
    ThreadInfo tidInfo;
    uint numScheduler;
    int bytesTransfered;
    int wakeUpObject;
    Throwable thr;
    size_t fastPathSkip;
    size_t fastPathSkipAck;
    SpinLock joinLock;
    FiberExt joiners;

    enum PAGESIZE = 4096;
    
    this(void function() fn, uint numSched) nothrow {
        super(fn);
        numScheduler = numSched;
    }

    this(void delegate() dg, uint numSched) nothrow {
        super(dg);
        numScheduler = numSched;
    }

    void schedule(size_t from, int wake) nothrow
    {
        wakeUpObject = wake;
        scheds[numScheduler].queue.push(this);
        if (from != numScheduler) {
            notifyEventloop(numScheduler);
        }
    }

    void join() shared {
        this.unshared.join();
    }

    void join() {
        assert(currentFiber);
        bool suspend = false;
        joinLock.lock();
        if (state != Fiber.State.TERM) {
            joiners = currentFiber;
            suspend = true;
        }
        joinLock.unlock();
        if (suspend) yield();
        if (thr) throw thr;
    }

    void joinNothrow() nothrow shared {
        this.unshared.joinNothrow();
    }

    void joinNothrow() nothrow {
        assert(currentFiber);
        bool suspend = false;
        joinLock.lock();
        if (state != Fiber.State.TERM) {
            joiners = currentFiber;
            suspend = true;
        }
        joinLock.unlock();
        if (suspend) yield();
        // skips rethrowing exception
    }

    void wakeUpJoiners(size_t numSched) {
        joinLock.lock();
        FiberExt f = joiners;
        if (joiners) {
            joiners.schedule(numSched, WAKE_JOIN);
        }
        joinLock.unlock();
    }
}

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

shared SchedulerBlock[] scheds;

enum MAX_THREADPOOL_SIZE = 100;
FiberExt currentFiber;
__gshared Map!(SOCKET, FiberExt) ioWaiters = new Map!(SOCKET, FiberExt); // mapping of sockets to awaiting fiber
__gshared PTP_POOL threadPool; // for synchronious syscalls
__gshared TP_CALLBACK_ENVIRON_V3 environ; // callback environment for the pool
shared int alive; // count of non-terminated Fibers scheduled

CascadingTimeQueue!(TimedFiber*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue; // thread-local

TimedFiber timerEntry(FiberExt* fiber, Duration delay) nothrow {
    return TimedFiber(cast(shared)fiber, TscTimePoint.hardNow() + delay);
}

public void initPhoton() {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    // TODO: handle NUMA case
    uint threads = info.dwNumberOfProcessors;
    debug(photon_single) {
        threads = 1;
    }
    scheds = new SchedulerBlock[threads];
    foreach(ref sched; scheds) {
        sched.queue = IntrusiveQueue!(FiberExt, RawEvent)(RawEvent(0));
        sched.iocp = cast(shared)CreateIoCompletionPort(cast(HANDLE)INVALID_HANDLE_VALUE, null, 0, 1);
        wenforce(sched.iocp != null, "Failed to create IO Completion Port");
    }
    threadPool = CreateThreadpool(null);
    wenforce(threadPool != null, "Failed to create threadpool");
    SetThreadpoolThreadMaximum(threadPool, MAX_THREADPOOL_SIZE);
    wenforce(SetThreadpoolThreadMinimum(threadPool, 1) == TRUE, "Failed to set threadpool minimum size");
    InitializeThreadpoolEnvironment(&environ);
    SetThreadpoolCallbackPool(&environ, threadPool);
    initWorkQueues(threads);
}

/// Convenience overload for functions
public Task go(void function() func) {
    return go({ func(); });
}

/// Setup a fiber task to run on the Photon scheduler.
public Task go(void delegate() func) {
    import std.random;
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
    f.schedule(choice, WAKE_TRIGGER);
    notifyEventloop(choice);
    return Task(f);
}

/// Convenience overload for goOnSameThread that accepts functions 
public Task goOnSameThread(void function() func) {
    return goOnSameThread({ func(); });
}

/// Same as go but make sure the fiber is scheduled on the same thread of the threadpool.
/// Could be useful if there is a need to propagate TLS variable.
public Task goOnSameThread(void delegate() func) {
    auto choice = currentFiber !is null ? currentFiber.numScheduler : 0;
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    logf("Assigned %x -> %d / %d scheduler", cast(void*)f, choice, scheds.length);
    f.schedule(choice, WAKE_TRIGGER);
    notifyEventloop(choice);
    return Task(f);
}

package(photon) void schedulerEntry(size_t n)
{
    void onTermination(FiberExt f) {
        //f.destroyFls();
        atomicOp!"-="(alive, 1);
        if (alive == 0) {
            foreach (i; 0..scheds.length) {
                notifyEventloop(i);
            }
        }
        logf("Fiber %s terminated", cast(void*)f);
        //f.wakeUpJoiners(n);
    }
    // TODO: handle NUMA case
    wenforce(SetThreadAffinityMask(GetCurrentThread(), 1L<<n), "failed to set affinity");
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
                    f.thr = e;
                    onTermination(f);
                }
                catch (Throwable e) {
                    stderr.writeln(e);
                    abort();
                }
                f = next;
            }
        }
        processEventsEntry(n, timeQueue.timeTillNextEntry(t));
    }
    foreach (i; 0..scheds.length) {
        notifyEventloop(i);
    }
}

enum int MAX_COMPLETIONS = 500;

void processEventsEntry(size_t n, Duration wait) {
    OVERLAPPED_ENTRY[MAX_COMPLETIONS] entries = void;
    uint count = 0;
    uint ms = wait > 10.hours ? 0 : cast(uint) wait.total!"msecs";
    while(GetQueuedCompletionStatusEx(cast(HANDLE)scheds[n].iocp, entries.ptr, MAX_COMPLETIONS, &count, ms, FALSE)) {
        logf("Dequeued I/O events=%d", count);
        foreach (e; entries[0..count]) {
            if (e.lpCompletionKey == 0) {
                continue; // user event to wake up event loop
            }
            SOCKET sock = cast(SOCKET)e.lpCompletionKey;
            auto fiber = ioWaiters[sock];
            // handle cases where data was available right away
            if (fiber.fastPathSkip != fiber.fastPathSkipAck) {
                fiber.fastPathSkipAck++;
                continue;
            }
            fiber.bytesTransfered = cast(int)e.dwNumberOfBytesTransferred;
            fiber.schedule(n, WAKE_TRIGGER);
        }
        if (count < MAX_COMPLETIONS) break;
    }
}

void notifyEventloop(size_t n) nothrow {
    HANDLE iocp = cast(HANDLE)scheds[n].iocp;
    PostQueuedCompletionStatus(iocp, 0, 0, null);
}


// ===========================================================================
// FAST SOCKETS
// ===========================================================================

__gshared RIO_EXTENSION_FUNCTION_TABLE rio;

class FastSocket {
    this() {
        
    }
}

struct Buffer {
    RIO_BUF buf;
    
    this(RIO_BUF rioBuf) {
        buf = rioBuf;
    }

    this(ubyte[] source) {
        auto id = rio.RIORegisterBuffer(cast(CHAR*)source.ptr, cast(uint)source.length);
        buf.BufferId = id;
        buf.Offset = 0;
        buf.Length = cast(uint)source.length;
    }

    bool empty() { return buf.Length == 0; }

    Buffer opIndex(size_t from, size_t to)
    {
        return Buffer(RIO_BUF(buf.BufferId, cast(uint)(buf.Offset + from), cast(uint)(to - from)));
    }

    void dispose() {
        rio.RIODeregisterBuffer(buf.BufferId);
    }
}

void initFastSockets() {
    GUID guid = WSAID_MULTIPLE_RIO;
    auto sock = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_REGISTERED_IO | WSA_FLAG_OVERLAPPED);
    wenforce(sock != INVALID_SOCKET);
    stderr.writeln("sock = ", sock);
    DWORD bytesReturned = 0;
    int result = WSAIoctl(
        sock,
        SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
        &guid,
        guid.sizeof,
        &rio,
        rio.sizeof,
        &bytesReturned,
        null,
        null
    );
    if (result != 0) {
        stderr.writeln("Error: ", GetLastError());
    }
    assert(result == 0);
    closesocket(sock);
}



// ===========================================================================
// INTERCEPTS
// ===========================================================================

extern(Windows) SOCKET socket(int af, int type, int protocol) {
    logf("Intercepted socket!");
    SOCKET s = cast(SOCKET)WSASocketW(af, type, protocol, null, 0, WSA_FLAG_OVERLAPPED);
    return s;
}

struct AcceptState {
    SOCKET socket;
    sockaddr* addr;
    LPINT addrlen;
    FiberExt fiber;
}

extern(Windows) VOID acceptJob(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WORK Work)
{
    AcceptState* state = cast(AcceptState*)Context;
    logf("Started threadpool job");
    SOCKET resp = WSAAccept(state.socket, state.addr, state.addrlen, null, 0);
    logf("Got accept response %s", resp);
    state.socket = resp;
    state.fiber.schedule(size_t.max, WAKE_TRIGGER);
}

extern(Windows) SOCKET accept(SOCKET s, sockaddr* addr, LPINT addrlen) {
    logf("Intercepted accept!");
    AcceptState state;
    state.socket = s;
    state.addr = addr;
    state.addrlen = addrlen;
    state.fiber = currentFiber;
    if (s !in ioWaiters) {
        registerSocket(s);
    }
    ioWaiters[s] = currentFiber;
    PTP_WORK work = CreateThreadpoolWork(&acceptJob, &state, &environ);
    wenforce(work != null, "Failed to create work for threadpool");
    SubmitThreadpoolWork(work);
    FiberExt.yield();
    CloseThreadpoolWork(work);
    return state.socket;
}

void registerSocket(SOCKET s) {
    HANDLE port = cast(HANDLE)scheds[currentFiber.numScheduler].iocp;
    wenforce(CreateIoCompletionPort(cast(void*)s, port, cast(size_t)s, 0) == port, "failed to register I/O completion");
}

extern(Windows) int recv(SOCKET s, void* buf, int len, int flags) {
    OVERLAPPED overlapped;
    WSABUF wsabuf = WSABUF(cast(uint)len, buf);
    if (s !in ioWaiters) {
        registerSocket(s);
    }
    ioWaiters[s] = currentFiber;
    uint received = 0;
    int ret = WSARecv(s, &wsabuf, 1, &received, cast(uint*)&flags, cast(LPWSAOVERLAPPED)&overlapped, null);
    logf("Got recv %d", ret);
    if (ret >= 0) {
        currentFiber.fastPathSkip++;
        return received;
    }
    else {
        auto lastError = GetLastError();
        logf("Last error = %d", lastError);
        if (lastError == ERROR_IO_PENDING) {
            FiberExt.yield();
            return currentFiber.bytesTransfered;
        }
        else
            return ret;
    }
}

extern(Windows) int send(SOCKET s, void* buf, int len, int flags) {
    OVERLAPPED overlapped;
    WSABUF wsabuf = WSABUF(cast(uint)len, buf);
    if (s !in ioWaiters) {
        registerSocket(s);
    }
    ioWaiters[s] = currentFiber;
    uint sent = 0;
    int ret = WSASend(s, &wsabuf, 1, &sent, flags, cast(LPWSAOVERLAPPED)&overlapped, null);
    logf("Get send %d", ret);
    if (ret >= 0) {
        currentFiber.fastPathSkip++;
        return sent;
    }
    else {
        auto lastError = GetLastError();
        logf("Last error = %d", lastError);
        if (lastError == ERROR_IO_PENDING) {
            FiberExt.yield();
            return currentFiber.bytesTransfered;
        }
        else 
            return ret;
    }
}


extern(Windows) void Sleep(DWORD dwMilliseconds) {
    if (currentFiber !is null) {
        FiberExt fiber = currentFiber;
        auto tm = timerEntry(&fiber, dwMilliseconds * 1.msecs);
        timeQueue.insert(&tm);
        FiberExt.yield();
    } else {
        SleepEx(dwMilliseconds, FALSE);
    }
}
