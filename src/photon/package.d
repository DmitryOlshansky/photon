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

import photon.ds.ring_queue;

version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;

version(Windows) public import photon.windows.core;
else version(linux) public import photon.linux.core;
else version(Darwin) public import photon.macos.core;
else version(FreeBSD) public import photon.freebsd.core;
else static assert(false, "Target OS not supported by Photon yet!");

public import photon.threadpool;

version(PhotonDocs) {

/// Initialize event loop and internal data structures for Photon scheduler.
public void startloop();

/// Setup a fiber task to run on the Photon scheduler.
public void go(void delegate() func);

/// ditto
public void go(void function() func);

/// Same as go but make sure the fiber is scheduled on the same thread of the threadpool.
/// Could be useful if there is a need to propagate TLS variable. 
public void goOnSameThread(void delegate() func);

/// ditto
public void goOnSameThread(void function() func);

/**
    Run work on a dedicated thread pool and pass the result back to the calling fiber or thread.
    This avoids blocking event loop on computationally intensive tasks.
*/
T offload(T)(T delegate() work);
}

/// Start sheduler and run fibers until all are terminated.
void runFibers()
{
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
}

/++
    A ref-counted channel that is safe to share between multiple fibers.
    In essence it's a multiple producer single consumer queue, that implements
    `OutputRange` and `InputRange` concepts.
+/
struct Channel(T) {
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
auto channel(T)(size_t capacity = 1) {
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
void select(Args...)(auto ref Args args)
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

enum isHandler(T) = is(T == void delegate());

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
auto pool(T)(size_t size, Duration maxIdle, T delegate() open, void delegate(ref T) close) {
    return cast(shared) new Pool!T(size, maxIdle, open, close);
}