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

import rewind.map;

import photon.ds.common;
import photon.ds.intrusive_queue;
import photon.windows.support;
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
    fiber.schedule();
}


extern(Windows) VOID waitAnyCallback(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WAIT  Wait, TP_WAIT_RESULT WaitResult) {
    auto await = cast(MultiAwait*)Context;
    auto fiber = cast()steal(await.box.fiber);
    if (fiber) {
        logf("AwaitAny callback waking up on %d object", await.n);
        fiber.wakeUpObject = await.n;
        fiber.schedule();
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

    @disable this(this);

    this(bool signaled) {
        ev = cast(HANDLE)CreateEventA(null, FALSE, signaled, null);
        assert(ev != null, "Failed to create Event");
    }

    /// Wait for the event to be triggered, then reset and return atomically
    void waitAndReset() {
        auto wait = CreateThreadpoolWait(&waitCallback, cast(void*)currentFiber, &environ);
        wenforce(wait != null, "Failed to create threadpool wait object");
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
        wenforce(wait != null, "Failed to create threadpool wait object");
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
        wenforce(wait != null, "Failed to create threadpool wait object");
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
        wenforce(wait != null, "Failed to create threadpool wait object");
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

extern(Windows) VOID timerCallback(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_TIMER Timer) {
    FiberExt fiber = cast(FiberExt)Context;
    fiber.schedule();
}

///
struct Timer {
    void wait(Duration dur) {
        auto timer = CreateThreadpoolTimer(&timerCallback, cast(void*)currentFiber, &environ);
        wenforce(timer != null, "Failed to create threadpool timer");
        FILETIME time;
        long hnsecs = -dur.total!"hnsecs";
        time.dwHighDateTime = cast(DWORD)(hnsecs >> 32);
        time.dwLowDateTime = hnsecs & 0xFFFF_FFFF;
        SetThreadpoolTimer(timer, &time, 0, 0);
        FiberExt.yield();
        CloseThreadpoolTimer(timer);
    }
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

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    size_t[1] padding;
}
static assert(SchedulerBlock.sizeof == 64);

class FiberExt : Fiber {
    FiberExt next;
    uint numScheduler;
    int bytesTransfered;
    int wakeUpObject;

    enum PAGESIZE = 4096;

    this(void function() fn, uint numSched) nothrow {
        super(fn);
        numScheduler = numSched;
    }

    this(void delegate() dg, uint numSched) nothrow {
        super(dg);
        numScheduler = numSched;
    }

    void schedule() nothrow
    {
        scheds[numScheduler].queue.push(this);
    }
}

package(photon) shared SchedulerBlock[] scheds;

enum MAX_THREADPOOL_SIZE = 100;
FiberExt currentFiber;
__gshared Map!(SOCKET, FiberExt) ioWaiters = new Map!(SOCKET, FiberExt); // mapping of sockets to awaiting fiber
__gshared RawEvent termination; // termination event, triggered once last fiber exits
__gshared HANDLE iocp; // IO Completion port
__gshared PTP_POOL threadPool; // for synchronious syscalls
__gshared TP_CALLBACK_ENVIRON_V3 environ; // callback environment for the pool
shared int alive; // count of non-terminated Fibers scheduled


public void startloop() {
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
    }
    threadPool = CreateThreadpool(null);
    wenforce(threadPool != null, "Failed to create threadpool");
    SetThreadpoolThreadMaximum(threadPool, MAX_THREADPOOL_SIZE);
    wenforce(SetThreadpoolThreadMinimum(threadPool, 1) == TRUE, "Failed to set threadpool minimum size");
    InitializeThreadpoolEnvironment(&environ);
    SetThreadpoolCallbackPool(&environ, threadPool);

    termination = RawEvent(false);
    iocp = CreateIoCompletionPort(cast(HANDLE)INVALID_HANDLE_VALUE, null, 0, 1);
    wenforce(iocp != null, "Failed to create IO Completion Port");
    wenforce(CreateThread(null, 0, &eventLoop, null, 0, null) != null, "Failed to start event loop");
    initWorkQueues(threads);
}

/// Convenience overload for functions
public void go(void function() func) {
    go({ func(); });
}

/// Setup a fiber task to run on the Photon scheduler.
public void go(void delegate() func) {
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
    f.schedule();
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
    f.schedule();
}

package(photon) void schedulerEntry(size_t n)
{
    // TODO: handle NUMA case
    wenforce(SetThreadAffinityMask(GetCurrentThread(), 1L<<n), "failed to set affinity");
    shared SchedulerBlock* sched = scheds.ptr + n;
    while (alive > 0) {
        sched.queue.event.waitAndReset();
        for(;;) {
            FiberExt f = sched.queue.drain();
            if (f is null) break; // drained an empty queue, time to sleep
            do {
                auto next = f.next; //save next, it will be reused on scheduling
                currentFiber = f;
                logf("Fiber %x started", cast(void*)f);
                try {
                    f.call();
                }
                catch (Throwable e) {
                    stderr.writeln(e);
                    atomicOp!"-="(alive, 1);
                }
                if (f.state == FiberExt.State.TERM) {
                    logf("Fiber %s terminated", cast(void*)f);
                    atomicOp!"-="(alive, 1);
                }
                f = next;
            } while(f !is null);
        }
    }
    termination.trigger();
    foreach (ref s; scheds) {
        s.queue.event.trigger();
    }
}

enum int MAX_COMPLETIONS = 500;

extern(Windows) uint eventLoop(void* param) {
    HANDLE[2] events;
    events[0] = iocp;
    events[1] = cast(HANDLE)termination.ev;
    logf("Started event loop! IOCP = %x termination = %x", iocp, termination.ev);
    for (;;) {
        auto ret = WaitForMultipleObjects(2, events.ptr, FALSE, INFINITE);
        logf("Got signalled in event loop %d", ret);
        if (ret == WAIT_OBJECT_0) { // iocp
            OVERLAPPED_ENTRY[MAX_COMPLETIONS] entries = void;
            uint count = 0;
            while(GetQueuedCompletionStatusEx(iocp, entries.ptr, MAX_COMPLETIONS, &count, 0, FALSE)) {
                logf("Dequeued I/O events=%d", count);
                foreach (e; entries[0..count]) {
                    SOCKET sock = cast(SOCKET)e.lpCompletionKey;
                    FiberExt fiber = ioWaiters[sock];
                    fiber.bytesTransfered = cast(int)e.dwNumberOfBytesTransferred;
                    fiber.schedule();
                }
                if (count < MAX_COMPLETIONS) break;
            }
        }
        else if (ret == WAIT_OBJECT_0 + 1) { // termination
            break;
        }
        else {
            logf("Failed to wait for multiple objects: %x", ret);
            break;
        }
    }
    ExitThread(0);
    return 0;
}


// ===========================================================================
// INTERCEPTS
// ===========================================================================

extern(Windows) SOCKET socket(int af, int type, int protocol) {
    logf("Intercepted socket!");
    SOCKET s = WSASocketW(af, type, protocol, null, 0, WSA_FLAG_OVERLAPPED);
    registerSocket(s);
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
    if (resp != INVALID_SOCKET) {
        registerSocket(resp);
    }
    state.socket = resp;
    state.fiber.schedule();
}

extern(Windows) SOCKET accept(SOCKET s, sockaddr* addr, LPINT addrlen) {
    logf("Intercepted accept!");
    AcceptState state;
    state.socket = s;
    state.addr = addr;
    state.addrlen = addrlen;
    state.fiber = currentFiber;
    PTP_WORK work = CreateThreadpoolWork(&acceptJob, &state, &environ);
    wenforce(work != null, "Failed to create work for threadpool");
    SubmitThreadpoolWork(work);
    FiberExt.yield();
    CloseThreadpoolWork(work);
    return state.socket;
}

void registerSocket(SOCKET s) {
    HANDLE port = iocp;
    wenforce(CreateIoCompletionPort(cast(void*)s, port, cast(size_t)s, 0) == port, "failed to register I/O completion");
}

extern(Windows) int recv(SOCKET s, void* buf, int len, int flags) {
    OVERLAPPED overlapped;
    WSABUF wsabuf = WSABUF(cast(uint)len, buf);
    ioWaiters[s] = currentFiber;
    uint received = 0;
    int ret = WSARecv(s, &wsabuf, 1, &received, cast(uint*)&flags, cast(LPWSAOVERLAPPED)&overlapped, null);
    logf("Got recv %d", ret);
    if (ret >= 0) {
        FiberExt.yield();
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
    ioWaiters[s] = currentFiber;
    uint sent = 0;
    int ret = WSASend(s, &wsabuf, 1, &sent, flags, cast(LPWSAOVERLAPPED)&overlapped, null);
    logf("Get send %d", ret);
    if (ret >= 0) {
        FiberExt.yield();
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
        auto tm = timer();
        tm.wait(dwMilliseconds.msecs);
    } else {
        SleepEx(dwMilliseconds, FALSE);
    }
}
