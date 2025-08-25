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
        SYS_PPOLL = 271,
        SYS_GETTID = 186,
        SYS_SOCKETPAIR = 0x35,
        SYS_ACCEPT = 0x2b,
        SYS_ACCEPT4 = 0x120,
        SYS_CONNECT = 0x2a,
        SYS_SENDTO = 0x2c,
        SYS_RECVFROM = 45,
        SYS_NANOSLEEP = 35;

    extern(C) ssize_t syscall(size_t number, ...);
} else version(AArch64){
    enum int
        SYS_READ = 0x3f,
        SYS_WRITE = 0x40,
        SYS_CLOSE = 0x39,
        SYS_PPOLL = 0x49,
        SYS_GETTID = 0xb0,
        SYS_SOCKETPAIR = 0xc7,
        SYS_ACCEPT = 0xca,
        SYS_ACCEPT4 = 0xf2,
        SYS_CONNECT = 0xcb,
        SYS_SENDTO = 0xce,
        SYS_RECVFROM = 0xcf,
        SYS_NANOSLEEP = 0x65;

    extern(C) ssize_t syscall(size_t number, ...);
}

extern(C) int gettid();

ssize_t raw_read(int fd, void *buf, size_t count) nothrow {
    logf("Raw read on FD=%d", fd);
    return syscall(SYS_READ, fd, cast(ssize_t) buf, cast(ssize_t) count);
}

ssize_t raw_write(int fd, const void *buf, size_t count) nothrow
{
    logf("Raw write on FD=%d", fd);
    return syscall(SYS_WRITE, fd, cast(size_t) buf, count);
}

ssize_t raw_poll(pollfd *fds, nfds_t nfds, int timeout)
{
    logf("Raw poll");
    timespec ts;
    ts.tv_sec = timeout/1000;
    ts.tv_nsec = (timeout % 1000) * 1000000;
    return syscall(SYS_PPOLL, cast(size_t)fds, cast(size_t) nfds, timeout < 0 ? null : &ts, null);
}

