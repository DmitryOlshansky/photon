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
