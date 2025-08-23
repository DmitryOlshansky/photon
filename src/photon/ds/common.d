module photon.ds.common;

import core.atomic;


// T becomes thread-local b/c it's stolen from shared resource
auto steal(T)(ref shared T arg)
{
    for (;;) {
        auto v = atomicLoad(arg);
        if(cas(&arg, v, cast(shared(T))null)) return v;
    }
}

ref T unshared(T)(ref shared T value) 
if (!is(T : U*, U)) {
     return *cast(T*)&value;
}

T unshared(T)(shared T value) 
if (is(T == class)){
	return *cast(T*)&value;
}

ref T* unshared(T)(ref shared(T)* value) {
     return *cast(T**)&value;
}


// intrusive list helper
T removeFromList(T)(T head, T item) {
	if (head == item) return head.next;
	else {
		auto p = head;
		while(p.next) {
			if (p.next == item)
				p.next = item.next;
			else 
				p = p.next;
		}
		return head;
	}
}

struct FreeList(E) {
	static if(is(E == class)) {
		alias T = E;
	} else {
		alias T = E*;
	}
	shared static T head;

	static T alloc() {
		shared T h;
		for (;;) {
			h = atomicLoad(head);
			if (h is null) break;
			if (cas(&head, h, h.next)) {
				break;
			}
		}
		if (h) return cast(T)h;
		else return new E;
	}

	static void dispose(T item) {
		for (;;) {
			auto h = atomicLoad(head);
			item.next = h;
			if (cas(&head, h, cast(shared)item)) {
				break;
			}
		}
	}
}

alias Seq(T...) = T;

unittest {
	static class Entry {
		size_t value;
		shared Entry next;
	}
	static struct SEntry {
		size_t value;
		shared SEntry* next;
	}
	foreach (E; Seq!(Entry, SEntry)) {
		static if(is(E == class)) {
			alias T = E;
		} else {
			alias T = E*;
		}
		T[] entries = new T[10];
		foreach (i, ref e; entries) {
			e = FreeList!E.alloc();
			e.value = i;
		}
		FreeList!E.dispose(entries[9]);
		FreeList!E.dispose(entries[8]);
		auto e = FreeList!E.alloc();
		assert(e.value == 8);
		e = FreeList!E.alloc();
		assert(e.value == 9);
	}
}
