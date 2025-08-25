module photon.threadpool;

package(photon):

import core.thread, core.atomic;
import std.random;

import photon.ds.intrusive_queue;

version(OSX) version = Darwin;
else version(iOS) version = Darwin;
else version(TVOS) version = Darwin;
else version(WatchOS) version = Darwin;
else version(VisionOS) version = Darwin;

// TODO: time to factor out common parts of schedulers?
version(linux) public import photon.linux.core;
else version(FreeBSD) public import photon.freebsd.core;
else version(Darwin) public import photon.macos.core;
else version(Windows) public import photon.windows.core;


alias Work = void delegate();

class WorkItem {
    this(FiberExt fiber, Work work) nothrow {
        this.fiber = fiber;
        this.work = work;
    }

    void done() {
        version (Windows)
            fiber.schedule();
        else version(FreeBSD)
            fiber.schedule();
        else
            fiber.schedule(size_t.max); // schedule from "remote scheduler"
    }

    FiberExt fiber; // if waking up fiber
    Work work; // universal work
    WorkItem next; // for intrusive queue
}

struct WorkQueue {
    IntrusiveQueue!(WorkItem, RawEvent) runq;
    shared int assigned;
    ubyte[64 - runq.sizeof - assigned.sizeof] padding;
}

static assert (WorkQueue.sizeof == 64);

__gshared WorkQueue[] queues;
shared bool workQueueTerminated = false;

void initWorkQueues(size_t threads) {
    queues = new WorkQueue[threads];
    foreach (ref q; queues) {
        q.runq = IntrusiveQueue!(WorkItem, RawEvent)(RawEvent(0));
    }
    void run(size_t n) {
        auto t = new Thread(() => processWorkQueue(n));
        t.isDaemon = true;
        t.start();
    }
    foreach (i; 0..threads) {
        run(i);
    }
}

void terminateWorkQueues() {
    workQueueTerminated = true;
    foreach (ref q; queues) {
        q.runq.event.trigger();
    }
}

void processWorkQueue(size_t i) {
    while (!workQueueTerminated) {
        queues[i].runq.event.waitAndReset();
        WorkItem w = queues[i].runq.drain();
        while(w !is null) {
            auto next = w.next;
            w.work();
            w.done();
            atomicOp!"-="(queues[i].assigned, 1);
            w = next;
        }
    }
}

void pushWork(WorkItem item) nothrow {
    uint choice;
    try {
        if (queues.length == 1) choice = 0;
        else {
            uint a = uniform!"[)"(0, cast(uint)queues.length);
            uint b = uniform!"[)"(0, cast(uint)queues.length-1);
            if (a == b) b = cast(uint)queues.length-1;
            uint loadA = queues[a].assigned;
            uint loadB = queues[b].assigned;
            if (loadA < loadB) choice = a;
            else choice = b;
        }
        atomicOp!"+="(queues[choice].assigned, 1);
        bool wasEmpty = queues[choice].runq.push(item);
        if (wasEmpty) queues[choice].runq.event.trigger();
    } catch(Throwable t) {
    }
}

public:

T offload(T)(T function() work) {
    return offload(() => work());
}

T offload(T)(T delegate() work) {
    if (currentFiber is null) return work();
    static if (!is(T == void)) {
        T result;
    }
    Throwable thr;
    //TODO: pool items?
    auto item = new WorkItem(currentFiber, () {
        try {
            static if (is(T == void)) {
                work();
            } else {
                result = work();
            }
        } catch(Throwable t) {
            thr = t;
        }
    });
    pushWork(item);
    FiberExt.yield();
    if (thr) throw thr;
    static if (!is(T == void)) {
        return result;
    }
}

T offload(T)(T delegate() nothrow work) nothrow{
    if (currentFiber is null) return work();
    static if (!is(T == void)) {
        T result;
    }
    //TODO: pool items?
    auto item = new WorkItem(currentFiber, () {
        static if (is(T == void)) {
            work();
        } else {
            result = work();
        }
    });
    pushWork(item);
    FiberExt.yield();
    static if (!is(T == void)) {
        return result;
    }
}