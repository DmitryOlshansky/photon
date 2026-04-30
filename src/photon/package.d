/++
    Photon is a lightweight transparent fiber scheduler. It's inspired by Golang's green thread model and
    the spawn function is called `go` doing the same job that Golang's keyword does. 
    The framework API surface is kept to a minimum, many programs can be written using only 
    three primitives: `initPhoton` to initialize Photon, `runScheduler` to start fiber scheduler and 
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
        initPhoton();
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
        runScheduler();
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
import mecca.containers.lists;


public import photon.core;
public import photon.threadpool;
public import photon.task;

version(PhotonDocs) {

/// Task result allows one fiber to wait on the other by joining the execution.
public struct Task {
    void join();
}

/// Initialize event loop and internal data structures for Photon scheduler.
public Task initPhoton() nothrow @trusted;

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

/**
    Suspend the current fiber or thread for req amount of time.
    Note the resolution of wait is in milliseconds, a delay of zero will still yield the execution.
*/
public void delay(Duration req);

/// Yields the execution of current fiber or thread
public void yield();

}

/// Number of threads running the scheduler loop
size_t schedulerThreads() @safe nothrow { return scheds.length; }

/// Start sheduler and run fibers until all are terminated.
void runScheduler() @trusted
{
    assert(scheds.length > 0, "Need to initialize with initPhoton");
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

///Initialize and run fibers with the given main
void runPhoton(void delegate() main) @trusted {
    initPhoton();
    go(main);
    runScheduler();
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
    bool tryLock() {
        return cas(&counter, 1L, 0L);
    }

    ///
    bool locked() {
        return counter != 1;
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
auto mutex() @trusted nothrow {
    return cast(shared)Mutex(1);
}

///
unittest {
    initPhoton();
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
    runScheduler();
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
        if (this.unshared.owner is currentFiber) {
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
    bool tryLock() shared {
        assert(currentFiber);
        splk.lock();
        scope(exit) splk.unlock();
        if (this.unshared.owner is currentFiber) {
            this.unshared.recCount++;
            return true;
        }
        else if(this.unshared.owner is null) {
            assert(this.unshared.counter == 1);
            this.unshared.owner = currentFiber;
            this.unshared.counter = 0;
            return true;
        } else {
            return false;
        }
    }

    ///
    bool locked() shared {
        assert(currentFiber);
        splk.lock();
        scope(exit) splk.unlock();
        return this.unshared.owner !is null;
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
auto recursiveMutex() @trusted nothrow {
    return cast(shared)RecursiveMutex(1);
}


unittest {
    static void testTryLock(alias createM)(int lockTimes) {
        initPhoton();
        auto m = createM();
        auto ev = event(0);
        shared bool unlocked = false;
        go({
            m.lock();
            ev.trigger();
            go({
                ev.waitAndReset();
                assert(m.locked());
                assert(m.tryLock() == false);
                ev.waitAndReset();
                assert(!m.locked());
                foreach (_; 0..lockTimes) {
                    bool locked = m.tryLock();
                    assert(locked);
                }
                assert(m.locked());
                foreach (_; 0..lockTimes) {
                    m.unlock();
                }
                assert(!m.locked());
            });
            delay(100.msecs);
            m.unlock();
            ev.trigger();
        });
        runScheduler();
        ev.dispose();
        m.dispose();
    }
    testTryLock!(mutex)(1);
    testTryLock!(recursiveMutex)(3);
}

unittest {
    enum ITERS = 1000;
    enum COUNT = 10;
    enum LOCK_CNT = 3;
    enum JOBS = 20;
    static void testMutex(M, alias createM)(int iters, int count, int lockingTimes, int jobs) {
        initPhoton();
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
        runScheduler();
        foreach (i; 0..COUNT) {
            assert(counters[i] == ITERS * JOBS);
        }
    }
    testMutex!(Mutex, mutex)(ITERS, COUNT, 1, JOBS);
    testMutex!(RecursiveMutex, recursiveMutex)(ITERS, COUNT, LOCK_CNT, JOBS);
}

public struct Condition {
nothrow:
@trusted:
private:
    alias Waiters = LinkedList!(AwaitingFiber*, "next", "prev");
    Waiters waiters;
    SpinLock splk;
public:
    ///
    void wait(M)(ref M mutex) shared {
        try {
            assert(currentFiber !is null);
            splk.lock();
            mutex.unlock();
            auto f = currentFiber;
            auto await = AwaitingFiber(cast(shared)&f);
            this.unshared.waiters.append(&await);
            splk.unlock();
            FiberExt.yield();
            mutex.lock();
        } catch (Throwable t) { assert(false, t.toString()); }
    }

    ///
    bool wait(M)(ref M mutex, Duration d) shared {
        try {
            assert(currentFiber !is null);
            splk.lock();
            mutex.unlock();
            auto f = currentFiber;
            AwaitingFiber await = AwaitingFiber(cast(shared)&f);
            this.unshared.waiters.append(&await);
            TimedFiber tm = timerEntry(&f, d);
            timeQueue.insert(&tm);
            splk.unlock();
            FiberExt.yield();
            bool success = false;
            if (currentFiber.wakeFd == WAKE_TIMER) {
                splk.lock();
                if (await.next != null)
                    this.unshared.waiters.remove(&await);
                splk.unlock();
            } else {
                timeQueue.cancel(&tm);
                success = true;
            }
            mutex.lock();
            return success;
        } catch(Throwable t) { assert(false, t.toString()); }
    }

    ///
    void signal() shared {
        assert(currentFiber !is null);
        splk.lock();
        AwaitingFiber* waiter;
        if (!this.unshared.waiters.empty) {
            waiter = this.unshared.waiters.popHead();
        }
        splk.unlock();
        if (waiter) {
            waiter.schedule(currentFiber.numScheduler, WAKE_TRIGGER);
        }
    }

    ///
    void broadcast() shared {
        assert(currentFiber !is null);
        splk.lock();
        Waiters list = this.unshared.waiters;
        this.unshared.waiters = Waiters.init;
        splk.unlock();
        while (!list.empty) {
            AwaitingFiber* waiter = list.popHead();
            waiter.schedule(currentFiber.numScheduler, WAKE_TRIGGER);
        }
    }
}

/// Create a conditional variable
auto condition() @trusted nothrow {
    return cast(shared)Condition.init;
}

unittest {
    void simpleCondTest(alias signal, alias wait)() {
        initPhoton();
        auto cond = condition();
        auto mtx = mutex();
        int counter = 0;
        enum MAX = 10000;
        go({
            for (;;) {
                mtx.lock();
                while (counter % 2 != 0) {
                    wait(cond, mtx);
                }
                counter++;
                if (counter >= MAX) {
                    mtx.unlock();
                    signal(cond);
                    break;
                }
                mtx.unlock();
                signal(cond);
            }
        });
        go({
            for (;;) {
                mtx.lock();
                while (counter % 2 != 1) {
                    wait(cond, mtx);
                }
                counter++;
                if (counter >= MAX) {
                    mtx.unlock();
                    signal(cond);
                    break;
                }
                mtx.unlock();
                signal(cond);
            }
        });
        runScheduler();
        mtx.dispose();
        assert(counter == MAX + 1);
    }
    simpleCondTest!((ref cnd) => cnd.signal(), (ref cnd, ref mtx) => cnd.wait(mtx));
    simpleCondTest!((ref cnd) => cnd.signal(), (ref cnd, ref mtx) => cnd.wait(mtx, 100.msecs));
    simpleCondTest!((ref cnd) => cnd.broadcast(), (ref cnd, ref mtx) => cnd.wait(mtx));
    simpleCondTest!((ref cnd) => cnd.broadcast(), (ref cnd, ref mtx) => cnd.wait(mtx, 100.msecs));
}

unittest {
    initPhoton();
    auto cond = condition();
    auto mtx = mutex();
    go({
        mtx.lock();
        auto s = MonoTime.currTime;
        cond.wait(mtx, 10.msecs);
        auto s2 = MonoTime.currTime;
        assert((s2 - s).total!"msecs" >= 10);
        mtx.unlock();
    });
    runScheduler();
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
        Returns: `true` if channel is closed and its buffer is exhausted.
    +/
    bool empty() {
        if (loaded) return false;
        loaded = buf.tryPop(item);
        return !loaded;
    }

    bool empty() shared {
        return this.unshared.empty;
    }

    /++
        Quick non-blocking check to see if there any item in the queue. Unlike `empty` doesn't block.
        Returns: `true` if there is an item in the queue ready to be consumed
    +/
    bool ready() {
        if(loaded) return true;
        if(buf.readyToRead())
            return !empty();
        else
            return false;
    }

    bool ready() shared {
        if(loaded) return true;
        if(buf.readyToRead())
            return !empty();
        else
            return false;
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

///
unittest {
    runPhoton({
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
    });
}


/++
    Multiplex between multiple channels, executes a lambda attached to the first
    channel that becomes ready to read.
+/
void select(Args...)(auto ref Args args) @trusted
if (
    (Args.length % 2 == 0 && allSatisfy!(isChannel, Even!Args) && allSatisfy!(isHandler, Odd!Args)) ||
    (allSatisfy!(isChannel, Even!(Args[0..$-1])) && allSatisfy!(isHandler, Odd!(Args[0..$-1])) && isHandler!(Args[$-1]))
) {
    void delegate()[args.length / 2] handlers = void;
    Event*[args.length/2] events = void;
    alias paired = args[0 .. args.length - args.length % 2];
    static foreach (i, v; paired) {
        static if(i % 2 == 0) {
            events[i/2] = &v.buf.rtr;
        }
        else {
            static if (is(typeof(v) : void function())) {
                import std.functional;
                handlers[i/2] = v.toDelegate;
            } else {
                handlers[i/2] = v;
            }
        }
    }
    foreach (i, channel; Even!(paired)) {
        if (channel.buf.readyToRead())
            return handlers[i]();
    }
    static if (args.length % 2) {
        return args[$-1]();
    }
    for (;;) {
        auto n = awaitAny(events[]);
    L_dispatch:
        switch(n) {
            static foreach (i, channel; Even!(paired)) {
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

enum isHandler(T) = is(T : void delegate()) || is(T : void function());

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
    @property ref get() { return pointer.item; }
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