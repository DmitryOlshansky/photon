module photon.task;

import photon.core;
import std.concurrency;

/** Represents a single task started with photon.go 

	Note that the Task type is considered weakly isolated and thus can be
	passed between threads using vibe.core.concurrency.send or by passing
	it as a parameter to vibe.core.core.runWorkerTask.
*/
struct Task {
package:
    FiberExt _fiber;
    static ThreadInfo s_tidInfo;
	
    this(FiberExt fiber)
	@safe nothrow {
		this._fiber = fiber;
	}

public:
    enum basePriority = 0x00010000;
	// NOTE: this is a template function to avoid the compiler treating it as a
	//       move constructor
	this()(Task other)
	@safe nothrow {
		_fiber = other._fiber;
	}

	/** Returns the Task instance belonging to the calling task.
	*/
	static Task getThis() @safe nothrow
	{
		return Task(currentFiber);
	}

	nothrow {
		package @property FiberExt taskFiber() @system { return _fiber; }
		@property FiberExt fiber() @system { return this._fiber; }

		/** Determines if the task is still running or scheduled to be run.
		*/
		@property bool running()
		const @trusted {
			return _fiber.state != Fiber.State.TERM;
		}

		package @property ref ThreadInfo tidInfo() @system { return _fiber ? _fiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!
		package @property ref const(ThreadInfo) tidInfo() const @system { return _fiber ? _fiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!

		/** Gets the `Tid` associated with this task for use with
			`std.concurrency`.
		*/
		@property Tid tid() @trusted { return tidInfo.ident; }
		/// ditto
		@property const(Tid) tid() const @trusted { return tidInfo.ident; }
	}

	T opCast(T)() const @safe nothrow if (is(T == bool)) { return _fiber !is null; }
	T opCast(T)() const shared @safe nothrow if (is(T == bool)) { return _fiber !is null; }

	void join() @trusted { if (_fiber) _fiber.join(); }
	void joinUninterruptible() @trusted { if (_fiber) _fiber.join(); }
	void interrupt() @trusted nothrow { 
        //noop
    }

	bool opEquals(scope ref const(Task) other) const @safe nothrow {
		return _fiber is other._fiber;
	}
	bool opEquals(scope const(Task) other) const @safe nothrow {
		return _fiber is other._fiber;
	}
	bool opEquals(scope shared(const(Task)) other) const shared @safe nothrow {
		return _fiber is other._fiber;
	}
}
