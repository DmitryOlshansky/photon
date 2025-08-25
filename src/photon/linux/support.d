module photon.linux.support;
version(linux):
import core.sys.posix.unistd;
import core.sys.linux.timerfd;
import core.stdc.errno;
import core.stdc.stdlib;
import core.thread;
import core.stdc.config;
import core.sys.posix.pthread;
import photon.linux.syscalls;

enum int MSG_DONTWAIT = 0x40;
enum int SOCK_NONBLOCK = 0x800;

extern(C) void perror(const(char) *s) nothrow;

T checked(T: ssize_t)(T value, const char* msg="unknown place") nothrow {
    if (value < 0) {
        perror(msg);
        _exit(cast(int)-value);
    }
    return value;
}

void logf(string file = __FILE__, int line = __LINE__, T...)(string msg, T args)
{
    debug(photon) {
        try {
            import std.stdio;
            stderr.writefln(msg, args);
            stderr.writefln("\tat %s:%s:[LWP:%s]", file, line, pthread_self());
        }
        catch(Throwable t) {
            abort();
        }
    }
}


@nogc:
nothrow:


private // helpers
{

    /* Size definition for CPU sets.  */
    enum
    {
        __CPU_SETSIZE = 1024,
        __NCPUBITS  = 8 * cpu_mask.sizeof,
    }

    /* Macros */

    /* Basic access functions.  */
    size_t __CPUELT()(size_t cpu) pure
    {
        return cpu / __NCPUBITS;
    }
    cpu_mask __CPUMASK()(size_t cpu) pure
    {
        return 1UL << (cpu % __NCPUBITS);
    }

    cpu_mask __CPU_SET_S()(size_t cpu, size_t setsize, cpu_set_t* cpusetp) pure
    {
        if (cpu < 8 * setsize)
        {
            cpusetp.__bits[__CPUELT(cpu)] |= __CPUMASK(cpu);
            return __CPUMASK(cpu);
        }

        return 0;
    }

    cpu_mask __CPU_GET_S()(size_t cpu, size_t setsize, cpu_set_t* cpusetp) pure
    {
        if (cpu < 8 * setsize)
        {
            if (cpusetp.__bits[__CPUELT(cpu)] & __CPUMASK(cpu))
                return __CPUMASK(cpu);
        }

        return 0;
    }
}

/// Type for array elements in 'cpu_set_t'.
alias c_ulong cpu_mask;

/// Data structure to describe CPU mask.
struct cpu_set_t
{
    cpu_mask[__CPU_SETSIZE / __NCPUBITS] __bits;
}

/// Access macros for 'cpu_set' (missing a lot of them)

cpu_mask CPU_SET()(size_t cpu, cpu_set_t* cpusetp) pure
{
     return __CPU_SET_S(cpu, cpu_set_t.sizeof, cpusetp);
}

cpu_mask CPU_GET()(size_t cpu, cpu_set_t* cpusetp) pure
{
    return __CPU_GET_S(cpu, cpu_set_t.sizeof, cpusetp);
}

/* Functions */
extern(C):
int sched_setaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *mask);
int sched_getaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *mask);

