module photon.ds.intrusive_queue;

import photon.ds.common;
import core.internal.spinlock;

shared struct IntrusiveQueue(T, Event)
if (is(T : Object)) {
private:
    SpinLock lock = SpinLock(SpinLock.Contention.brief);
    T head;
    T tail;
    bool exhausted = true;
public:
    Event event;

    this(Event ev) {
        event = ev;
    }

    bool push(T item) {
        item.next = null;
        lock.lock();
        bool wasEmpty = tail is null;
        if (wasEmpty) {
            head = tail = cast(shared)item;
        }
        else {
            tail.next = cast(shared)item;
            tail = cast(shared)item;
        }
        lock.unlock();
        return wasEmpty;
    }

    bool tryPop(ref T item) nothrow {
        lock.lock();
        if (!head) {
            lock.unlock();
            return false;
        }
        else {
            item = head.unshared;
            head = head.next;
            if (head is null) tail = null;
            lock.unlock();
            return true;
        }
    }

    // drain the whole queue in one go
    T drain() nothrow {
        lock.lock();
        if (head is null) {
            lock.unlock();
            return null;
        }
        else {
            auto r = head.unshared;
            head = tail = null;
            lock.unlock();
            return r;
        }
    }
}

unittest {
    static class Box(T) {
        Box next;
        T item;
        this(T k) {
            item = k;
        }
    }

    static struct EmptyEvent {
        shared nothrow void trigger(){}
    }
    shared q = IntrusiveQueue!(Box!int, EmptyEvent)();
    q.push(new Box!int(1));
    q.push(new Box!int(2));
    q.push(new Box!int(3));
    Box!int ret;
    q.tryPop(ret);
    assert(ret.item == 1);
    q.tryPop(ret);
    assert(ret.item == 2);

    q.push(new Box!int(4));
    q.tryPop(ret);
    assert(ret.item == 3);
    q.tryPop(ret);
    assert(ret.item == 4);
    q.push(new Box!int(5));

    q.tryPop(ret);
    assert(ret.item == 5);
    assert(q.tryPop(ret) == false);
}
