module photon.windows.core;
version(Windows):
package(photon):
import core.sys.posix.time;
import core.sys.posix.fcntl;
import core.sys.windows.winnt;
import core.stdc.errno;
import core.sys.windows.core;
import core.sys.windows.winsock2;
import core.atomic;
import core.thread;
import core.internal.spinlock;
import std.exception;
import std.windows.syserror;
import core.stdc.stdlib;
import core.stdc.string;
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
import photon.joiners;
import photon.exceptions;
import photon.threadpool;
import std.file;

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

extern(Windows) VOID waitCallback(PTP_CALLBACK_INSTANCE Instance, PVOID Context, PTP_WAIT  Wait, TP_WAIT_RESULT WaitResult) {
    auto fiber = cast(FiberExt*)Context;
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
@trusted:
    @disable this(this);

    this(bool signaled) {
        ev = cast(HANDLE)CreateEventA(null, FALSE, signaled, null);
        assert(ev != null, "Failed to create Event");
    }

    /// Wait for the event to be triggered, then reset and return atomically
    void waitAndReset() {
        FiberExt fiber = currentFiber;
        auto wait = CreateThreadpoolWait(&waitCallback, cast(void*)&fiber, &environ);
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

    void dispose() {
        CloseHandle(ev);
    }

    void dispose() shared {
        this.unshared.dispose();
    }
    
private:
    HANDLE ev;
}

///
public auto event(bool signaled) @trusted {
    return cast(shared)Event(signaled);
}

/// Semaphore object
public struct Semaphore {
nothrow:
@trusted:
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
        FiberExt fiber = currentFiber;
        auto wait = CreateThreadpoolWait(&waitCallback, cast(void*)&fiber, &environ);
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
public auto semaphore(int count) @trusted {
    return cast(shared)Semaphore(count);
}

///
public struct Timer {
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
public auto timer() @trusted {
    return Timer();
}

///
public void delay(Duration req) nothrow @trusted {
    if (currentFiber !is null) {
        FiberExt fiber = currentFiber;
        auto tm = timerEntry(&fiber, req);
        timeQueue.insert(&tm);
        FiberExt.yield();
    } else {
        SleepEx(cast(int)req.total!"msecs", FALSE);
    }
}

///
public void yield() nothrow @trusted {
    if (currentFiber !is null) {
        currentFiber.schedule(currentFiber.numScheduler, WAKE_TRIGGER);
        FiberExt.yield();
    } else {
        Thread.yield();
    }
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
    return currentFiber.wakeFd;
}

///
public size_t awaitAny(Awaitable)(Awaitable[] args) 
if (allSatisfy!(isAwaitable, Awaitable)) {
    auto box = cast(MultiAwaitBox*)calloc(1, MultiAwaitBox.sizeof);
    box.refCount = args.length;
    box.fiber = cast(shared)currentFiber;
    foreach (i, ref v; args) {
        v.registerForWaitAny(cast(int)i, box);
    }
    FiberExt.yield();
    return currentFiber.wakeFd;
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
    uint numScheduler;
    int wakeFd;
    FiberJoiners joiners;
    struct FlsEntry {
        void* pointer;
        void function(void*) dtor;
    }
    FlsEntry[] fls;
    static size_t flsOffset;

    enum PAGESIZE = 4096;
    
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

    void schedule(size_t from, int wake) nothrow {
        wakeFd = wake;
        scheds[numScheduler].queue.push(this);
        if (from != numScheduler) {
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

struct Overlapped {
    OVERLAPPED overlapped;
    shared FiberExt fiber;
    int bytes;
}

shared SchedulerBlock[] scheds;

enum MAX_THREADPOOL_SIZE = 100;
FiberExt currentFiber;
__gshared Map!(SOCKET, bool) ioWaiters = new Map!(SOCKET, bool); // mapping of sockets to awaiting fiber
__gshared Map!(int, FiberExt) fileWaiters = new Map!(int, FiberExt); // mapping of 'fd's to awaiting fiber, actually keyed by -fd to differ from SOCKET-s
__gshared PTP_POOL threadPool; // for synchronious syscalls
__gshared TP_CALLBACK_ENVIRON_V3 environ; // callback environment for the pool
__gshared typeof(&closesocket) originalCloseSocket;
__gshared typeof(&send) originalSend;
__gshared typeof(&recv) originalRecv;
__gshared typeof(&accept) originalAccept;
shared int alive; // count of non-terminated Fibers scheduled

CascadingTimeQueue!(TimedFiber*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue; // thread-local

TimedFiber timerEntry(FiberExt* fiber, Duration delay) nothrow {
    return TimedFiber(cast(shared)fiber, TscTimePoint.hardNow() + delay);
}

shared bool inited;

public void initPhoton() @trusted {
    if (!cas(&inited, false, true)) return;
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    HMODULE hInst = LoadLibraryA("wsock32.dll");
    wenforce(hInst, "Failed to upen wsock32.dll");
    originalCloseSocket = cast(typeof(&closesocket))GetProcAddress(hInst, "closesocket");
    wenforce(originalCloseSocket, "failed to lookup closesocket");
    originalSend = cast(typeof(&send))GetProcAddress(hInst, "send");
    wenforce(originalSend, "failed to lookup send");
    originalRecv = cast(typeof(&recv))GetProcAddress(hInst, "recv");
    wenforce(originalRecv, "failed to lookup recv");
    originalAccept = cast(typeof(&accept))GetProcAddress(hInst, "accept");
    wenforce(originalAccept, "failed to lookup accept");
    
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
public Task go(void function() func) @trusted nothrow {
    return go({ func(); });
}

/// Setup a fiber task to run on the Photon scheduler.
public Task go(void delegate() func) @trusted nothrow {
    import std.random;
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
        } catch (Exception e) { assert(false, e.msg); }
    }
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    logf("Assigned %x -> %d scheduler", cast(void*)f, choice);
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
    // TODO: handle NUMA case
    //wenforce(SetThreadAffinityMask(GetCurrentThread(), cast(size_t)(1L<<n)) != 0, "failed to set affinity");
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
    currentFiber = null;
}

enum int MAX_COMPLETIONS = 500;

void processEventsEntry(size_t n, Duration wait) {
    OVERLAPPED_ENTRY[MAX_COMPLETIONS] entries = void;
    uint count = 0;
    uint ms = wait > 10.hours ? INFINITE  : cast(uint) wait.total!"msecs";
    bool notify = false;
    while(GetQueuedCompletionStatusEx(cast(HANDLE)scheds[n].iocp, entries.ptr, MAX_COMPLETIONS, &count, ms, FALSE)) {
        logf("Dequeued I/O scheduler %d events=%d", n, count);
        foreach (e; entries[0..count]) {
            if (e.lpCompletionKey == 0) {
                notify = true;
                continue; // user event to wake up event loop
            }
            auto overlapped = cast(Overlapped*)e.lpOverlapped;
            FiberExt fiber = cast(FiberExt)steal(overlapped.fiber);
            if (fiber !is null) {
                logf("i/o done completionKey=%d bytes=%d", e.lpCompletionKey, e.dwNumberOfBytesTransferred);
                overlapped.bytes = cast(int)e.dwNumberOfBytesTransferred;
                fiber.schedule(n, WAKE_TRIGGER);
            }
        }
        if (count < MAX_COMPLETIONS || notify) break;
    }
}

void notifyEventloop(size_t n) nothrow {
    HANDLE iocp = cast(HANDLE)scheds[n].iocp;
    PostQueuedCompletionStatus(iocp, 0, 0, null);
}

// ===========================================================================
// Posix Files API
// ===========================================================================

__gshared SpinLock fdsLock;
__gshared HANDLE[] fds;

int getNextFd(HANDLE h) nothrow {
    fdsLock.lock();
    scope(exit) fdsLock.unlock();
    foreach (i, ref fd; fds) {
        if (fd == INVALID_HANDLE_VALUE) {
            fd = h;
            return cast(int)i+1;
        }
    }
    fds ~= h;
    return cast(int)fds.length;
}

HANDLE fromFd(int fd) nothrow {
    if (fd < 1 || fd > fds.length) return INVALID_HANDLE_VALUE;
    fdsLock.lock();
    scope(exit) fdsLock.unlock();
    return fds[fd-1];
}

HANDLE freeFd(int fd) nothrow {
    if (fd < 1 || fd > fds.length) return INVALID_HANDLE_VALUE;
    fdsLock.lock();
    scope(exit) fdsLock.unlock();
    auto h = fds[fd-1];
    fds[fd-1] = INVALID_HANDLE_VALUE;
    return h;
}

timespec fileTimeToUnix(FILETIME ft) nothrow {
    ULARGE_INTEGER ui;
    ui.LowPart = ft.dwLowDateTime;
    ui.HighPart = ft.dwHighDateTime;
    ui.QuadPart -= 116_444_736_000_000_000L;
    long sec = ui.QuadPart / 10_000_000L;
    int nsec = (ui.QuadPart % 10_000_000) * 100;
    return timespec(sec, nsec);
}

public @trusted nothrow {
    alias blksize_t = long;
    alias dev_t = ulong;
    alias gid_t = uint;
    alias mode_t = uint;
    alias nlink_t = ulong;
    alias pid_t = int;
    alias uid_t = uint;
    alias blkcnt_t = long;
    alias ino_t = ulong;
    alias off_t = long;
    struct timespec {
        long   tv_sec;
        int    tv_nsec;
    }

    struct stat_t {
        dev_t     st_dev;     // ID of device containing file
        ino_t     st_ino;     // Inode number
        mode_t    st_mode;    // File type and mode (permissions)
        nlink_t   st_nlink;   // Number of hard links
        uid_t     st_uid;     // User ID of owner
        gid_t     st_gid;     // Group ID of owner
        dev_t     st_rdev;    // Device ID (if special file)
        off_t     st_size;    // Total size, in bytes
        blksize_t st_blksize; // Block size for filesystem I/O
        blkcnt_t  st_blocks;  // Number of 512B blocks allocated

        // Timestamps
        timespec st_atim; // Time of last access
        timespec st_mtim; // Time of last modification
        timespec st_ctim; // Time of last status change
    };

    extern(C) int open(const char *path, int flags, mode_t mode) {
        DWORD access = 0;
        if (flags & O_RDONLY)
            access |= GENERIC_READ;
        if (flags & O_WRONLY)
            access |= GENERIC_WRITE;
        if (flags & O_RDWR)
            access |= GENERIC_READ | GENERIC_WRITE;
        DWORD disposition = 0;
        if(flags & O_TRUNC) {
            disposition = CREATE_ALWAYS;
        } else if (flags & O_CREAT) {
            disposition = CREATE_NEW;
        } else {
            disposition = OPEN_EXISTING;
        }
        HANDLE file = offload(() => CreateFileA(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, null, disposition, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, null));
        if (file == INVALID_HANDLE_VALUE) {
            _errno = cast(int)GetLastError();
            return -1;
        }
        return getNextFd(file);
    }

    extern(C) int ftruncate(int fd, off_t length) {
        LARGE_INTEGER offset;
        offset.QuadPart = length;
        bool success = offload(() {
            HANDLE h = fromFd(fd);
            if (!SetFilePointerEx(h, offset, null, FILE_BEGIN)) return false;
            if (!SetEndOfFile(h)) return false;
            return true;
        });
        return success ? 0 : -1;
    }

    extern(C) int fstat(int fd, stat_t* st) {
        HANDLE h = fromFd(fd);
        BY_HANDLE_FILE_INFORMATION fileInfo;
        if (!GetFileInformationByHandle(h, &fileInfo)) return -1;
        memset(st, 0, stat_t.sizeof);
        st.st_size = (cast(long)fileInfo.nFileSizeHigh << 32) + fileInfo.nFileSizeLow;
        st.st_mode = _S_IREAD;
        if (!(fileInfo.dwFileAttributes & FILE_ATTRIBUTE_READONLY)) {
            st.st_mode |= _S_IWRITE;
        }
        st.st_atim = fileTimeToUnix(fileInfo.ftLastAccessTime);
        st.st_mtim = fileTimeToUnix(fileInfo.ftLastWriteTime);
        st.st_ctim = fileTimeToUnix(fileInfo.ftCreationTime);
        return 0;
    }

    extern(C) ptrdiff_t pwrite(int fd, const(void) *buf, size_t count, ulong offset) {
        static HANDLE ev = INVALID_HANDLE_VALUE;
        auto h = fromFd(fd);
        Overlapped* overlapped = cast(Overlapped*)calloc(1, Overlapped.sizeof);
        scope(exit) free(overlapped);
        overlapped.overlapped.Offset = offset & 0xffff_ffff;
        overlapped.overlapped.OffsetHigh = offset >> 32;
        overlapped.fiber = cast(shared)currentFiber;
        if (currentFiber) {
            if (-fd !in fileWaiters) {
                try {
                    registerFile(fd, h);
                } catch(Exception e) {
                    assert(false, e.msg);
                }
            }
            fileWaiters[-fd] = currentFiber;
        } else {
            if (ev == INVALID_HANDLE_VALUE) {
                ev = cast(HANDLE)CreateEventA(null, FALSE, FALSE, null);
            }
            overlapped.overlapped.hEvent = ev;
        }
        if (!WriteFile(h, buf, cast(uint)count, null, cast(OVERLAPPED*)overlapped) && GetLastError() != ERROR_IO_PENDING) {
            return -1;
        }
        if (currentFiber) {
            FiberExt.yield();
            return overlapped.bytes;
        } else {
            WaitForSingleObject(ev, INFINITE);
            return count;
        }
    }

    extern(C) ptrdiff_t pread(int fd, void *buf, size_t count, ulong offset) {
        static HANDLE ev = INVALID_HANDLE_VALUE;
        auto h = fromFd(fd);
        Overlapped* overlapped = cast(Overlapped*)calloc(1, Overlapped.sizeof);
        scope(exit) free(overlapped);
        overlapped.overlapped.Offset = offset & 0xffff_ffff;
        overlapped.overlapped.OffsetHigh = offset >> 32;
        overlapped.fiber = cast(shared)currentFiber;
        if (currentFiber) {
            if (-fd !in fileWaiters) {
                try {
                    registerFile(fd, h);
                } catch(Exception e) { 
                    assert(false, e.msg); 
                }
            }
            fileWaiters[-fd] = currentFiber;
        } else {
            if (ev == INVALID_HANDLE_VALUE) {
                ev = cast(HANDLE)CreateEventA(null, FALSE, FALSE, null);
            }
            overlapped.overlapped.hEvent = ev;
        }
        if (!ReadFile(h, buf, cast(uint)count, null, cast(OVERLAPPED*)overlapped) && GetLastError() != ERROR_IO_PENDING) return -1;
        if (currentFiber) {
            FiberExt.yield();
            return overlapped.bytes;
        } else {
            WaitForSingleObject(ev, INFINITE);
            return count;
        }
    }

    extern(C) int close(int fd) {
        try {
            fileWaiters.remove(-fd);
        } catch(Exception e) { assert(false, e.msg); }
        if (!CloseHandle(freeFd(fd))) return -1;
        return 0;
    }

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
    if (currentFiber is null) return originalAccept(s, addr, addrlen);
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
    ioWaiters[s] = true;
    HANDLE port = cast(HANDLE)scheds[currentFiber.numScheduler].iocp;
    wenforce(CreateIoCompletionPort(cast(void*)s, port, cast(size_t)s, 0) == port, "failed to register I/O completion");
}

void registerFile(int fd, HANDLE h) {
    HANDLE port = cast(HANDLE)scheds[currentFiber.numScheduler].iocp;
    wenforce(CreateIoCompletionPort(cast(void*)h, port, cast(size_t)-fd, 0) == port, "failed to register I/O completion");
}

extern(Windows) int recv(SOCKET s, void* buf, int len, int flags) {
    if (currentFiber is null) return originalRecv(s, buf, len, flags);
    Overlapped* overlapped = cast(Overlapped*)calloc(1, Overlapped.sizeof);
    scope(exit) free(overlapped);
    overlapped.fiber = cast(shared)currentFiber;
    WSABUF wsabuf = WSABUF(cast(uint)len, buf);
    uint received = 0;
    if (s !in ioWaiters) {
        registerSocket(s);
    }
    
    int ret = WSARecv(s, &wsabuf, 1, &received, cast(uint*)&flags, cast(LPWSAOVERLAPPED)overlapped, null);
    logf("Got recv %d", ret);
    if (ret >= 0 && received > 0) {
        FiberExt.yield();
        return overlapped.bytes;
    }
    else {
        auto lastError = GetLastError();
        logf("Last error = %d", lastError);
        if (lastError == ERROR_IO_PENDING || ret == 0) {
            FiberExt.yield();
            return overlapped.bytes;
        }
        else
            return ret;
    }
}

public int recvWithTimeout(SOCKET s, void* buf, int len, int flags, Duration timeout) {
    assert(currentFiber, "recvWithTimeout is only supported for fibers at the moment");
    if (timeout == Duration.max) return recv(s, buf, len, flags);
    Overlapped* overlapped = cast(Overlapped*)calloc(1, Overlapped.sizeof);
    scope(exit) free(overlapped);
    overlapped.fiber = cast(shared)currentFiber;
    WSABUF wsabuf = WSABUF(cast(uint)len, buf);
    if (s !in ioWaiters) {
        registerSocket(s);
    }
    auto entry = timerEntry(cast(FiberExt*)&overlapped.fiber, timeout);
    timeQueue.insert(&entry);
    uint received = 0;
    int ret = WSARecv(s, &wsabuf, 1, &received, cast(uint*)&flags, cast(LPWSAOVERLAPPED)overlapped, null);
    logf("Got recv %d", ret);
    if (ret >= 0 && received > 0) {
        timeQueue.cancel(&entry);
        FiberExt.yield();
        return overlapped.bytes;
    }
    else {
        auto lastError = GetLastError();
        logf("Last error = %d", lastError);
        if (lastError == ERROR_IO_PENDING || ret == 0) {
            FiberExt.yield();
            if (currentFiber.wakeFd == WAKE_TIMER) {
                CancelIoEx(cast(HANDLE)s, cast(LPOVERLAPPED)overlapped);
                FiberExt.yield();
                return -2;
            } else {
                timeQueue.cancel(&entry);
            }
            return overlapped.bytes;
        }
        else
            return ret;
    }
}

extern(Windows) int send(SOCKET s, void* buf, int len, int flags) {
    if (currentFiber is null) return originalSend(s, buf, len, flags);
    Overlapped* overlapped = cast(Overlapped*)calloc(1, Overlapped.sizeof);
    scope(exit) free(overlapped);
    overlapped.fiber = cast(shared)currentFiber;
    WSABUF wsabuf = WSABUF(cast(uint)len, buf);
    if (s !in ioWaiters) {
        registerSocket(s);
    }
    uint sent = 0;
    int ret = WSASend(s, &wsabuf, 1, &sent, flags, cast(LPWSAOVERLAPPED)overlapped, null);
    logf("Get send %d", ret);
    if (ret >= 0 && sent > 0) {
        FiberExt.yield();
        return overlapped.bytes;
    }
    else {
        auto lastError = GetLastError();
        logf("Last error = %d", lastError);
        if (lastError == ERROR_IO_PENDING || ret == 0) {
            FiberExt.yield();
            return overlapped.bytes;
        }
        else 
            return ret;
    }
}

extern(Windows) int closesocket(SOCKET s) {
    ioWaiters.remove(s);
    return originalCloseSocket(s);
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
