#include <stdio.h>
#include <sys/types.h> 

//import core.sys.posix.sys.types; // for ssize_t, uid_t, gid_t, off_t, pid_t, useconds_t
//import core.sys.posix.unistd;

ssize_t read(int fd, void* buf, size_t len)
{
    printf("HOOKED WITH MY LIB!\n");

    return 0;
}


//~/workspace/dlang/dmd/src/dmd  -I~/workspace/dlang/druntime/import/ -I~/workspace/dlang/phobos -L-L/home/alexandru/workspace/dlang/workspace/dfibers -L-L$HOME/workspace/dlang/phobos/generated/linux/release/64/