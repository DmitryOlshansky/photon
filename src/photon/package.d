/++
    Photon is a lightweight transparent fiber scheduler. It's inspired by Golang's green thread model and
    the spawn function is called `go` doing the same job that Golang's keyword does. 
    The framework API surface is kept to a minimum, many programs can be written using only 
    three primitives: `startloop` to initialize Photon, `runFibers` to start fiber scheduler and 
    `go` to create tasks, including the initial tasks.
    
    Example, showcasing channels and std.range interop:
    ----
    module examples.channels;

    import std.algorithm, std.datetime, std.range, std.stdio;
    import photon;

    void first(shared Channel!string work, shared Channel!int completion) {
        delay(2.msecs);
        work.put("first #1");
        delay(2.msecs);
        work.put("first #2");
        delay(2.msecs);
        work.put("first #3");
        completion.put(1);
    }

    void second(shared Channel!string work, shared Channel!int completion) {
        delay(3.msecs);
        work.put("second #1");
        delay(3.msecs);
        work.put("second #2");
        completion.put(2);
    }

    void main() {
        startloop();
        auto jobQueue = channel!string(2);
        auto finishQueue = channel!int(1);
        go({
            first(jobQueue, finishQueue);
        });
        go({ // producer # 2
            second(jobQueue, finishQueue);
        });
        go({ // consumer
            foreach (item; jobQueue) {
                delay(1.seconds);
                writeln(item);
            }
        });
        go({ // closer
            auto completions = finishQueue.take(2).array;
            assert(completions.length == 2);
            jobQueue.close(); // all producers are done
        });
        runFibers();
    }
    ----
+/
module photon;

import core.thread;
import core.atomic;
import core.internal.spinlock;
import core.lifetime;
import std.meta;

import photon.ds.common;
import photon.ds.ring_queue;

public import photon.core;
public import photon.threadpool;
public import photon.task;

version(PhotonDocs) {

/// Task result allows one fiber to wait on the other by joining the execution.
public struct Task {
    void join();
}

/// Initialize event loop and internal data structures for Photon scheduler.
public Task startloop() nothrow @trusted;

/// Setup a fiber task to run on the Photon scheduler.
public Task go(void delegate() func)  @trusted;

/// ditto
public Task go(void function() func) @safe;

/// Same as go but make sure the fiber is scheduled on the same thread of the threadpool.
/// Could be useful if there is a need to propagate TLS variable. 
public Task goOnSameThread(void delegate() func) @trusted;

/// ditto
public Task goOnSameThread(void function() func) @safe;

/**
    Run work on a dedicated thread pool and pass the result back to the calling fiber or thread.
    This avoids blocking event loop on computationally intensive tasks.
*/
T offload(T)(T delegate() work) @trusted;
}

/// Start sheduler and run fibers until all are terminated.
void runFibers() @trusted
{
    startWorkQueue(scheds.length);
    Thread runThread(size_t n){ // damned D lexical capture "semantics"
        auto t = new Thread(() => schedulerEntry(n));
        t.start();
        return t;
    }
    Thread[] threads = new Thread[scheds.length-1];
    foreach (i; 0..threads.length){
        threads[i] = runThread(i+1);
    }
    schedulerEntry(0);
    foreach (t; threads)
        t.join();
    terminateWorkQueues();
}

shared struct Mutex {
@trusted:
nothrow:
private:
    shared Semaphore sem;
    long     counter;

    this(long cnt) {
        sem = semaphore(0);
        counter = cnt;
    }

    @disable this(this);
public:
    ///
    void lock() {
        auto v = atomicFetchSub(counter, 1);
        if (v <= 0) {
            sem.wait();
        }
    }
    ///
    void unlock() {
        auto v = atomicFetchAdd(counter, 1);
        if (v < 0) {
            sem.trigger(1);
        }
    }
    ///
    void dispose() {
        sem.dispose();
    }
}

/// Create non-recursive mutex
auto mutex() {
    return cast(shared)Mutex(1);
}

///
version(Posix)
unittest {
    startloop();
    auto mtx = mutex();
    int counter = 0;
    go({
        foreach (_; 0..100) {
            mtx.lock();
            int c = counter;
            delay(1.msecs);
            counter = c + 1;
            mtx.unlock();
        }
    });
    go({
        foreach (_; 0..100) {
            mtx.lock();
            int c = counter;
            delay(1.msecs);
            counter = c + 1;
            mtx.unlock();
        }
    });
    runFibers();
    mtx.dispose();
    assert(counter == 200);
}

///
struct RecursiveMutex {
nothrow:
@trusted:
private:
    shared Semaphore sem;
    long counter;
    FiberExt owner;
    long recCount;
    SpinLock splk;

    this(long cnt) {
        sem = semaphore(0);
        counter = cnt;
        recCount = 0;
        splk = SpinLock(SpinLock.Contention.brief);
    }

    @disable this(this);
public:
    ///
    void lock() shared {
        assert(currentFiber);
        splk.lock();
        if (owner is cast(shared)currentFiber) {
            this.unshared.recCount++;
            splk.unlock();
            return;
        }
        auto v = this.unshared.counter--;
        bool suspend;
        if (v <= 0) {
            suspend = true;
        } else {
            this.unshared.owner = currentFiber;
            assert(this.recCount == 0);
        }
        splk.unlock();
        if (suspend) {
            sem.wait();
            splk.lock();
            this.unshared.owner = currentFiber;
            assert(this.recCount == 0);
            splk.unlock();
        }
    }

    ///
    void unlock() shared {
        assert(currentFiber);
        splk.lock();
        assert(owner is cast(shared)currentFiber);
        if (this.unshared.recCount != 0) {
            this.unshared.recCount--;
            splk.unlock();
            return;
        } 
        this.unshared.owner = null;
        auto v = this.unshared.counter++;
        bool notify;
        if (v < 0) {
            notify = true;
        }
        splk.unlock();
        if (notify) {
            sem.trigger(1);
        }
    }
    ///
    void dispose() shared {
        sem.dispose();
    }
}

/// Create recursive mutex
auto recursiveMutex() {
    return cast(shared)RecursiveMutex(1);
}

version(Posix)
unittest {
    enum ITERS = 1000;
    enum COUNT = 10;
    enum LOCK_CNT = 3;
    enum JOBS = 20;
    static void testMutex(M, alias createM)(int iters, int count, int lockingTimes, int jobs) {
        startloop();
        auto mtxs = new shared(M)[count];
        int[] counters = new int[count];
        foreach (i; 0..count) {
            mtxs[i] = createM();
        }
        shared size_t cnt = 0;
        void task() {
            foreach(_; 0..iters){
                foreach (i; 0..count) {
                    foreach (__; 0..lockingTimes)
                        mtxs[i].lock();
                    counters[i]++;
                    foreach(__;0..lockingTimes)
                        mtxs[i].unlock();
                }
            }
        }
        foreach(_; 0..jobs) {
            go(&task);
        }
        runFibers();
        foreach (i; 0..COUNT) {
            assert(counters[i] == ITERS * JOBS);
        }
    }
    testMutex!(Mutex, mutex)(ITERS, COUNT, 1, JOBS);
    testMutex!(RecursiveMutex, recursiveMutex)(ITERS, COUNT, LOCK_CNT, JOBS);
}

version(Posix)
public struct CondVar {
private:
    FiberExt waiters;
    SpinLock splk;
public:
    void wait(M)(ref M mutex) shared {
        assert(currentFiber !is null);
        splk.lock();
        mutex.unlock();
        auto f = currentFiber;
        if (waiters !is null) {
            f.next = waiters;
            f.back = waiters.back;
            waiters.back = f;
            waiters = f;
        } else {
            f.next = null;
            f.back = null;
            waiters = f;
        }
        splk.unlock();
        FiberExt.yield();
        mutex.lock();
    }

    void wait(M)(ref M mutex, Duration d) shared {
        assert(currentFiber !is null);
        splk.lock();
        mutex.unlock();
        auto f = currentFiber;
        if (waiters !is null) {
            f.next = waiters;
            f.back = waiters.back;
            waiters = f;
        } else {
            currentFiber.next = null;
            currentFiber.back = null;
        }
        f.wakeFd = 0;
        TimedFiber tf = timerEntry(f, d);
        timerQueue.insert(tf);
        splk.unlock();
        FiberExt.yield();
        if (f.wakeFd == TIMER_WAKE) {
            splk.lock();
            if (f == this.unshared.waiters) {
                this.unshared.waiters = f.next;
                if (this.unshared.waiters !is null) {
                    waiters.prev = f.prev;
                }
            } else {
                if (f.prev !is null) {
                    f.prev.next = f.next;
                }
                if (f.next !is null) {
                    f.next.prev = f.prev;
                }
            }
            splk.unlock();
        }
        mutex.lock();
    }

    void signal() {
        splk.lock();

        splk.unlock();
    }
}

/++
    A ref-counted channel that is safe to share between multiple fibers.
    In essence it's a multiple producer single consumer queue, that implements
    `OutputRange` and `InputRange` concepts.
+/
struct Channel(T) {
@trusted:
private:
    shared RingQueue!(T, Event)* buf_;
    shared T item_;
    bool loaded;

    ref T item() shared {
        return *cast(T*)&item_;
    }

    ref buf() shared {
        return *cast(RingQueue!(T, Event)**)&buf_;
    }
    
    ref T item() {
        return *cast(T*)&item_;
    }

    ref buf() {
        return *cast(RingQueue!(T, Event)**)&buf_;
    }
public:
    this(size_t capacity) {
        buf_ = cast(shared)allocRingQueue!T(capacity, Event(false), Event(false));
    }

    this(this) {
        buf.retain();
    }

    /// OutputRange contract - puts a new item into the channel.
    void put(T value) {
        buf.push(move(value));
    }

    void put(T value) shared {
        buf.push(move(value));
    }

    void close() shared {
        buf.close();
    }

    /++
        Part of InputRange contract - checks if there is an item in the queue.
        Returns `true` if channel is closed and its buffer is exhausted.
    +/
    bool empty() {
        if (loaded) return false;
        loaded = buf.tryPop(item);
        return !loaded;
    }

    bool empty() shared {
        if (loaded) return false;
        loaded = buf.tryPop(item);
        return !loaded;
    }

    /++
        Part of InputRange contract - returns an item available in the channel.
    +/
    ref T front() {
        return cast()item;
    }

    ref T front() shared {
        return item;
    }

    /++
        Part of InputRange contract - advances range forward.
    +/
    void popFront() {
        loaded = false;
    }

    void popFront() shared {
        loaded = false;
    }

    ~this() {
        if (buf) {
            if (buf.release) {
                disposeRingQueue(buf);
                buf_ = null;
            }
        }
    }
}

/++
    Create a new shared `Channel` with given capacity.
+/
auto channel(T)(size_t capacity = 1) @safe {
    return cast(shared)Channel!T(capacity);
}

unittest {
    import std.range.primitives, std.traits;
    import std.algorithm;
    static assert(isInputRange!(Channel!int));
    static assert(isInputRange!(Unqual!(shared Channel!int)));
    static assert(isOutputRange!(shared Channel!int, int));
    //
    auto ch = channel!int(10);
    foreach (i; 0..10){
        ch.put(i);
    }
    ch.close();
    auto sum = ch.sum;
    assert(sum == 45);
}



/++
    Multiplex between multiple channels, executes a lambda attached to the first
    channel that becomes ready to read.
+/
void select(Args...)(auto ref Args args) @trusted
if (allSatisfy!(isChannel, Even!Args) && allSatisfy!(isHandler, Odd!Args)) {
    void delegate()[args.length/2] handlers = void;
    Event*[args.length/2] events = void;
    static foreach (i, v; args) {
        static if(i % 2 == 0) {
            events[i/2] = &v.buf.rtr;
        }
        else {
            handlers[i/2] = v;
        }
    }
    foreach (i, channel; Even!(args)) {
        if (channel.buf.readyToRead())
            return handlers[i]();
    }
    for (;;) {
        auto n = awaitAny(events[]);
    L_dispatch:
        switch(n) {
            static foreach (i, channel; Even!(args)) {
                case i:
                    if (channel.buf.readyToRead())
                        return handlers[n]();
                    break L_dispatch;
            }
            default:
                assert(0);
        }
    }
}

/// Trait for testing if a type is Channel
enum isChannel(T) = is(T == Channel!(V), V);

enum isHandler(T) = is(T : void delegate());

private template Even(T...) {
    static assert(T.length % 2 == 0);
    static if (T.length > 0) {
        alias Even = AliasSeq!(T[0], Even!(T[2..$]));
    }
    else {
        alias Even = AliasSeq!();
    }
}

private template Odd(T...) {
    static assert(T.length % 2 == 0);
    static if (T.length > 0) {
        alias Odd = AliasSeq!(T[1], Odd!(T[2..$]));
    }
    else {
        alias Odd = AliasSeq!();
    }
}

unittest {
    static assert(Even!(1, 2, 3, 4) == AliasSeq!(1, 3));
    static assert(Odd!(1, 2, 3, 4) == AliasSeq!(2, 4));
    static assert(isChannel!(Channel!int));
    static assert(isChannel!(shared Channel!int));
}

struct PooledEntry(T) {
    import std.datetime;
private:
    PooledEntry* next;
    SysTime lastUsed;
    T item;
}

struct Pooled(T) {
    alias get this;
    @property ref get() const { return pointer.item; }
    private PooledEntry!T* pointer;
}

/// Generic pool
class Pool(T) {
    import std.datetime, photon.ds.common;
    private this(size_t size, Duration maxIdle, T delegate() open, void delegate(ref T) close) {
        this.size = size;
        this.maxIdle = maxIdle;
        this.open = open;
        this.close = close;
        this.allocated = 0;
        this.ready = event(0);
        this.working = true;
        this.lock = SpinLock(SpinLock.Contention.brief);
        go({
            while(this.working) {
                delay(1.seconds);
                auto time = Clock.currTime();
                lock.lock();
                PooledEntry!T* stale;
                PooledEntry!T* fresh;
                PooledEntry!T* current = pool;
                while (current != null) {
                    if (current.lastUsed + maxIdle < time) {
                        auto next = current.next;
                        current.next = stale;
                        stale = current;
                        current = next;
                    }
                    else {
                        auto next = current.next;
                        current.next = fresh;
                        fresh = current;
                        current = next;
                    }
                }
                pool = fresh;
                lock.unlock();
                current = stale;
                size_t count = 0;
                while (current != null) {
                    close(current.item);
                    current = current.next;
                    count++;
                }
                atomicFetchSub(allocated, count);
                if (count > 0) ready.trigger();
            }
        });
    }

    // Acquire resource from the pool
    Pooled!T acquire() {
        for (;;) {
            lock.lock();
            if (pool != null) {
                auto next = pool.next;
                auto ret = pool;
                ret.next = null;
                pool = next;
                lock.unlock();
                return Pooled!T(ret);
            }
            lock.unlock();
            if (allocated < size) {
                size_t current = allocated;
                size_t next = current + 1;
                if (cas(&allocated, current, next)) {
                    // since we are not in the pool yet, lastUsed is ignored
                    auto item = new PooledEntry!T(null, SysTime.init, open());
                    return Pooled!T(item);
                }
            }
            ready.waitAndReset();
        }
    }

    Pooled!T acquire() shared {
        return this.unshared.acquire();
    }

    /// Put pooled item to reuse
    void release(Pooled!T item) {
        item.pointer.lastUsed = Clock.currTime();
        lock.lock();
        item.pointer.next = pool;
        pool = item.pointer;
        lock.unlock();
        ready.trigger();
    }

    void release(Pooled!T item) shared {
        this.unshared.release(item);
    }

    /// call on items that errored or cannot be reused for some reason
    void dispose(Pooled!T item) {
        atomicFetchSub(allocated, 1);
        close(item.pointer.item);
        ready.trigger();
    }

    void dispose(Pooled!T item) shared {
        return this.unshared.dispose(item);
    }

    void shutdown() {
        working = false;
        auto current = pool;
        while (current != null) {
            close(current.item);
            current = current.next;
        }
    }

    void shutdown() shared {
        return this.unshared.shutdown();
    }
private:
    SpinLock lock;
    shared Event ready;
    PooledEntry!T* pool;
    shared size_t allocated;
    size_t size;
    Duration maxIdle;    
    T delegate() open;
    void delegate(ref T) close;
    shared bool working;
}


/// Create generic pool for resources, open creates new resource, close releases the resource.
auto pool(T)(size_t size, Duration maxIdle, T delegate() open, void delegate(ref T) close) @trusted {
    return cast(shared) new Pool!T(size, maxIdle, open, close);
}