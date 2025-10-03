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
    shared FiberExt _fiber;
    static ThreadInfo s_tidInfo;
	
    this(FiberExt fiber)
	@trusted nothrow {
		this._fiber = cast(shared)fiber;
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
		package @property FiberExt taskFiber() @system { return cast()_fiber; }
		@property FiberExt fiber() @system { return cast()this._fiber; }

		/** Determines if the task is still running or scheduled to be run.
		*/
		@property bool running()
		const @trusted {
			return _fiber.unshared.state != Fiber.State.TERM;
		}

		@property ref ThreadInfo tidInfo() @system { return _fiber ? cast()_fiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!
		@property ref const(ThreadInfo) tidInfo() const @system { return _fiber ? cast()_fiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!

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
	void joinUninterruptible() @trusted nothrow { if (_fiber) _fiber.joinNothrow(); }
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

/// Task local storage
struct TaskLocal(T) {
private:
	size_t offset = size_t.max;
	T initial;

	static void dtor(void* pointer) {
		destroy(*cast(T*)pointer);
	}
public:	
	this(T value) {
		initial = value;
	}

	@disable this(this);

	ref opAssign(T value) {
		storage = value;
	}

	ref storage() {
		size_t size = (T.sizeof + 0xf) & ~0xf;
		if (offset == size_t.max) {
			offset = FiberExt.flsAlloc();
		}
		void* data = currentFiber.flsGet(offset, &initial, size, &dtor);
		return *cast(T*)data;
	}

	alias this = storage;
}