module photon.ds.ring_queue;

import core.atomic;
import core.internal.spinlock;
import core.stdc.stdlib;
import core.lifetime;

import photon.exceptions;


struct RingQueue(T, Event)
{
    T* store;
    size_t length;
    size_t fetch, insert, size;
    Event cts, rtr; // clear to send, ready to recieve
    bool closed;
    shared size_t refCount;
    AlignedSpinLock lock;

    this(size_t capacity, Event cts, Event rtr)
    {
        store = cast(T*)malloc(T.sizeof * capacity);
        length = capacity;
        size = 0;
        fetch = insert = 0;
        this.cts = move(cts);
        this.rtr = move(rtr);
        closed = false;
        refCount = 1;
        lock = AlignedSpinLock(SpinLock.Contention.brief);
    }

    void push(T ctx)
    {
        lock.lock();
        while (size == length) {
            lock.unlock();
            cts.waitAndReset();
            lock.lock();
        }
        if (closed) {
            lock.unlock();
            throw new ChannelClosed();
        }
        bool notify = false;
        move(ctx, store[insert++]);
        if (insert == length) insert = 0;
        if (size == 0) notify = true;
        size += 1;
        lock.unlock();
        if (notify) rtr.trigger();
    }

    bool tryPop(out T output)
    {
        lock.lock();
        while (size == 0 && !closed) {
            lock.unlock();
            rtr.waitAndReset();
            lock.lock();
        }
        if (size == 0 && closed) {
            lock.unlock();
            return false;
        }
        move(store[fetch++], output);
        if (fetch == length) fetch = 0;
        size -= 1;
        lock.unlock();
        cts.trigger();
        return true;
    }

    bool readyToRead() {
        lock.lock();
        scope(exit) lock.unlock();
        return size > 0;
    }

    bool empty() {
        lock.lock();
        scope(exit) lock.unlock();
        if (closed && size == 0) return true;
        return false;
    }

    void close() {
        lock.lock();
        closed = true;
        lock.unlock();
        cts.trigger();
        rtr.trigger();
    }

    void retain() {
        auto cnt = atomicFetchAdd(refCount, 1);
        assert(cnt != 0);
    }

    // true if time to release
    bool release() {
        auto cnt = atomicFetchSub(refCount, 1);
        if (cnt == 1) return true;
        return false;
    }
}

auto allocRingQueue(T, Event)(size_t capacity, Event cts, Event rtr){
    alias Q = RingQueue!(T,Event);
    auto ptr = cast(Q*)malloc(Q.sizeof);
    emplace(ptr, capacity, move(cts), move(rtr));
    return ptr;
}

void disposeRingQueue(T, Event)(RingQueue!(T, Event)* q) {
    free(q.store);
    free(q);
}

unittest {
    import photon;
    import std.exception;
    auto cts = Event(false);
    auto rtr = Event(false);
    auto q = allocRingQueue!(int, Event)(2, move(cts), move(rtr));
    q.push(1);
    q.push(2);
    int result;
    assert(q.tryPop(result) && result == 1);
    assert(q.tryPop(result) && result == 2);
    q.retain();
    assert(!q.release());
    assert(q.release());
    q.close();
    assert(!q.tryPop(result));
    assertThrown!ChannelClosed(q.push(3));
    disposeRingQueue(q);
}

unittest {
    import photon;
    auto cts = Event(false);
    auto rtr = Event(false);
    auto q = allocRingQueue!(string, Event)(1, move(cts), move(rtr));
    assert(!q.empty);
    q.push("hello");
    string result;
    assert(q.tryPop(result) && result == "hello");
    assert(!q.empty);
    q.push("world");
    q.close();
    assert(q.tryPop(result) && result == "world");
    assert(!q.tryPop(result));
    assert(q.empty);
}
