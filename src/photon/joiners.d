module photon.joiners;

import photon.core;

class FiberJoiners {
    ThreadInfo tidInfo;
    bool terminated;
    SpinLock joinLock;
    FiberExt joiners;

    void join() shared {
        this.unshared.join();
    }

    void join() {
        return joinNothrow();
    }

    void joinNothrow() nothrow shared {
        this.unshared.joinNothrow();
    }

    void joinNothrow() nothrow {
        assert(currentFiber);
        bool suspend = false;
        joinLock.lock();
        if (!terminated) {
            currentFiber.next = joiners;
            joiners = currentFiber;
            suspend = true;
        }
        joinLock.unlock();
        if (suspend) FiberExt.yield();
        // skips rethrowing exception
    }

    void wakeUpJoiners(size_t numSched) {
        joinLock.lock();
        terminated = true;
        FiberExt f = joiners;
        while (f) {
            auto next = f.next;
            f.schedule(numSched, WAKE_JOIN);
            f = next;
        }
        joiners = null;
        joinLock.unlock();
    }
}
