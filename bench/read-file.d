module read_file;
import std.stdio;
import std.file;
import std.utf : byChar;
import std.string;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import photon;

void main(){
    initPhoton();
    std.file.write("file.txt", "Read Test");
    go({

        int fd = open("file.txt", O_RDONLY);
        char[20] buf;
        long r = core.sys.posix.unistd.read(fd, buf.ptr, buf.length);
        writef("return r = %d\n", r);
        if (r >= 0)
            writef("return  = %s\n", buf[0..r]);

    });
    runScheduler();
}
