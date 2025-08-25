// Runs a process
// dump resource usage of a process
// each ~100ms
// to a rusage.log

import std.exception, std.stdio, std.format, std.string, std.conv, std.datetime, std.process;
import core.thread;
import core.sys.posix.unistd;
import core.sys.posix.signal;

struct Stats {
    string name;
    long rbytes, wbytes; // read/write(-ish) syscalls
    long stime, utime; // CPU time in clock ticks
    long rss; // resident memory pages

    auto delta(Stats rhs) {
        return Stats(
            name,
            rbytes - rhs.rbytes,
            wbytes - rhs.wbytes,
            stime - rhs.stime,
            utime - rhs.utime,
            rss
        );
    }
}

shared int targetPid;
immutable double MB = 1024.0 * 1024.0;

extern(C) void signal_handler(int sig, siginfo_t*, void*)
{
    kill(targetPid, sig);
    _exit(9);
}

Stats statsOf(int pid) {
    string ioPath = format("/proc/%d/io", pid);
    string statPath = format("/proc/%d/stat", pid);
    long rd;
    long wr;
    File stat = File(statPath, "r");
    File io = File(ioPath, "r");
    io.readf("rchar: %d\nwchar: %d\n", &rd, &wr);
    int _;
    string name, rest;
    stat.readf("%d (%s) %s", _, name, rest);
    string[] fields = rest.split(" ");
    long stime = fields[11].to!long;
    long utime = fields[12].to!long;
    long rss = fields[21].to!long;
    return Stats(name, rd, wr, stime, utime, rss);
}

int main(string[] argv) {
    if (argv.length < 3) {
        stderr.writeln("Usage: rusage period:log-file <command> [args*]\n\n" ~
            "Example: rusage 0.1:usage.csv find /\nTo sample each 0.1 second and store to usage.csv");
        return 1;
    }
    string params = argv[1];
    double period;
    string logFile;
    params.formattedRead("%f:%s", period, logFile);
    File log = File(logFile, "w");
    Duration sampling = (period*1000).to!int.msecs;
    Pid p = spawnProcess(argv[2..$]);
    double pageSize = 1.0*sysconf(_SC_PAGE_SIZE);
    double tickSize = 1.0*sysconf(_SC_CLK_TCK);
    targetPid = p.processID;
    sigaction_t action;
    action.sa_sigaction = &signal_handler;
    enforce(sigaction(SIGTERM, &action, null) >= 0);
    enforce(sigaction(SIGINT, &action, null) >= 0);
    log.writeln("time,name,read(MB),written(MB),kernel cpu time(sec),user cpu time(sec),RSS(MB)");
    Stats prev;
    for(;;) {
        auto status = tryWait(p);
        if (status.terminated) break;
        try {
            auto stats = statsOf(targetPid);
            auto delta =  stats.delta(prev);
            prev = stats;
            SysTime dt = Clock.currTime;
            log.writefln("%s,%s,%f,%f,%f,%f,%f",
                dt.toISOExtString, stats.name,
                delta.rbytes / MB,
                delta.wbytes / MB,
                delta.stime / tickSize,
                delta.utime / tickSize,
                delta.rss * pageSize / MB
            );
        }
        catch (Exception e){
            stderr.writeln("Error: ", e);
        }
        log.flush();
        Thread.sleep(sampling);
    }
    return 0;
}
