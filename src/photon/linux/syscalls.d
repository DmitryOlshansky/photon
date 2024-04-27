///Syscall definitions and direct calls that bypass our libc intercepts
module photon.linux.syscalls;
version(linux):
import core.sys.posix.sys.types;
import core.sys.posix.netinet.in_;
import core.sys.posix.poll;
import core.sys.linux.epoll;
import core.sys.linux.timerfd;

import photon.linux.support;

nothrow:

version (X86) {
    enum int SYS_READ = 0x3, SYS_SOCKETPAIR = 0x168; //TODO test on x86
    int syscall(int ident, int n, int arg1, int arg2)
    {
        int ret;

        asm nothrow
        {
            mov EAX, ident;
            mov EBX, n[EBP];
            mov ECX, arg1[EBP];
            mov EDX, arg2[EBP];
            int 0x80;
            mov ret, EAX;
        }
        return ret;
    }

    int syscall(int ident, int n, int arg1, int arg2, int arg3)
    {
        int ret;

        asm nothrow
        {
            mov EAX, ident;
            mov EBX, n[EBP];
            mov ECX, arg1[EBP];
            mov EDX, arg2[EBP];
            mov ESI, arg3[EBP];
            int 0x80;
            mov ret, EAX;
        }
        return ret;
    }

    int syscall(int ident, int n, int arg1, int arg2, int arg3, int arg4)
    {
        int ret;

        asm nothrow
        {
            mov EAX, ident;
            mov EBX, n[EBP];
            mov ECX, arg1[EBP];
            mov EDX, arg2[EBP];
            mov ESI, arg3[EBP];
            mov EDI, arg4[EBP];
            int 0x80;
            mov ret, EAX;
        }
        return ret;
    }
} else version (X86_64) {
    enum int
        SYS_READ = 0x0,
        SYS_WRITE = 0x1,
        SYS_CLOSE = 3,
        SYS_POLL = 7,
        SYS_GETTID = 186,
        SYS_SOCKETPAIR = 0x35,
        SYS_ACCEPT = 0x2b,
        SYS_ACCEPT4 = 0x120,
        SYS_CONNECT = 0x2a,
        SYS_SENDTO = 0x2c,
        SYS_RECVFROM = 45;

    size_t syscall(size_t ident) nothrow
    {
        size_t ret;

        asm nothrow
        {
            mov RAX, ident;
            syscall;
            mov ret, RAX;
        }
        return ret;
    }

    size_t syscall(size_t ident, size_t n) nothrow
    {
        size_t ret;

        asm nothrow
        {
            mov RAX, ident;
            mov RDI, n;
            syscall;
            mov ret, RAX;
        }
        return ret;
    }

    size_t syscall(size_t ident, size_t n, size_t arg1, size_t arg2) nothrow
    {
        size_t ret;

        asm nothrow
        {
            mov RAX, ident;
            mov RDI, n;
            mov RSI, arg1;
            mov RDX, arg2;
            syscall;
            mov ret, RAX;
        }
        return ret;
    }

    size_t syscall(size_t ident, size_t n, size_t arg1, size_t arg2, size_t arg3) nothrow
    {
        size_t ret;

        asm nothrow
        {
            mov RAX, ident;
            mov RDI, n;
            mov RSI, arg1;
            mov RDX, arg2;
            mov R10, arg3;
            syscall;
            mov ret, RAX;
        }
        return ret;
    }

    size_t syscall(size_t ident, size_t n, size_t arg1, size_t arg2, size_t arg3, size_t arg4) nothrow
    {
        size_t ret;

        asm nothrow
        {
            mov RAX, ident;
            mov RDI, n;
            mov RSI, arg1;
            mov RDX, arg2;
            mov R10, arg3;
            mov R8, arg4;
            syscall;
            mov ret, RAX;
        }
        return ret;
    }

    size_t syscall(size_t ident, size_t n, size_t arg1, size_t arg2, size_t arg3, size_t arg4, size_t arg5) nothrow
    {
        size_t ret;

        asm nothrow
        {
            mov RAX, ident;
            mov RDI, n;
            mov RSI, arg1;
            mov RDX, arg2;
            mov R10, arg3;
            mov R8, arg4;
            mov R9, arg5;
            syscall;
            mov ret, RAX;
        }
        return ret;
    }
}

int gettid()
{
    return cast(int)syscall(SYS_GETTID);
}

ssize_t raw_read(int fd, void *buf, size_t count) nothrow {
    logf("Raw read on FD=%d", fd);
    return syscall(SYS_READ, fd, cast(ssize_t) buf, cast(ssize_t) count).withErrorno;
}

ssize_t raw_write(int fd, const void *buf, size_t count) nothrow
{
    logf("Raw write on FD=%d", fd);
    return syscall(SYS_WRITE, fd, cast(size_t) buf, count).withErrorno;
}

ssize_t raw_poll(pollfd *fds, nfds_t nfds, int timeout)
{
    logf("Raw poll");
    return syscall(SYS_POLL, cast(size_t)fds, cast(size_t) nfds, timeout).withErrorno;
}

