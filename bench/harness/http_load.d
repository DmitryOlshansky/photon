// Performs multiple runs of weighttp tool
// varying the concurency range in steps
// Inspired by GWAN benchmark tool (ab.c)

module http_load;

import core.cpuid, core.thread;
import std.getopt, std.array, std.algorithm, std.numeric,
    std.conv, std.datetime, std.exception,
    std.stdio, std.process, std.regex;

void usage() {
    stderr.writeln("Usage: http_load START-STOP:STEP TIMExRUNS http://server[:port]/path");
}

long fromMetric(string num) {
    assert(num.length > 0);
    long mult;
    switch(num[$-1]){
    case 'm':
        mult = 1_000_000;
        num = num[0..$-1];
        break;
    case 'k':
        mult = 1_000;
        num = num[0..$-1];
        break;
    default:
        mult = 1;
    }
    return mult * num.to!long;
}

int main(string[] argv) {
    bool trace = false;
    getopt(argv,
        "v", &trace
    );
    if (argv.length < 4) {
        usage();
        return 1;
    }
    auto m = matchFirst(argv[1], `^(\d+(?:[km]?))-(\d+(?:[km]?)):(\d+(?:[km]?))$`);
    if (!m) {
        stderr.writeln("Can't parse 'range' argument:", argv[1]);
        usage();
        return 1;
    }
    string url = argv[3];
    long start = fromMetric(m[1]);
    long stop = fromMetric(m[2]);
    long step = fromMetric(m[3]);
    auto m2 = matchFirst(argv[2], `^(\d+)x(\d+)$`);
    if (!m2) {
        stderr.writeln("Can't parse 'runs' argument:", argv[2]);
        usage();
        return 1;
    }
    int numThreads = threadsPerCPU;
    int time = m2[1].to!int;
    int runs = m2[2].to!int;
    writefln("time,concurrency,RPS(min),RPS(avg),RPS(max),errors(max),lat(75%%),lat(99%%)");
    for(long c = start; c <= stop; c += step) {
        c = c / step * step; // truncate to step
        if (c < numThreads) c = numThreads;
        auto dt = Clock.currTime();
        double[] rps = new double[runs];
        double[] perc75 = new double[runs];
        double[] perc99 = new double[runs];
        long[] errors = new long[runs];
        foreach(r; 0..runs) {
            double multiplier(const(char)[] s){
                if (s == "") return 1;
                else if(s == "u") return 1e-6;
                else if(s == "m") return 1e-3;
                else throw new Exception("Unknown multiplier " ~ s.to!string);
            }
            auto cmd = ["wrk", "--latency", "-c", c.to!string, "-t", numThreads.to!string, "-d", time.to!string, url];
            if(trace) stderr.writeln(cmd.join(" "));
            auto pipes = pipeProcess(cmd);
            foreach (line; pipes.stdout.byLine) {
                auto result = matchFirst(line, `Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)`);
                if(result) {
                    errors[r] = result[1].to!long + result[2].to!long + result[3].to!long + result[4].to!long;
                }
                result = matchFirst(line, `Requests/sec:\s*([\d.]+)`);
                if (result) {
                    rps[r] = result[1].to!double;
                }
                result = matchFirst(line, `75%\s*([\d.]+)([mu])?s`);
                if (result) {
                    perc75[r] = result[1].to!double * multiplier(result[2]);
                }
                result = matchFirst(line, `99%\s*([\d.]+)([mu])?s`);
                if (result) {
                    perc99[r] = result[1].to!double * multiplier(result[2]);
                }
            }
            if (wait(pipes.pid)) {
                stderr.writeln("wrk failed, stopping benchmark");
                return 1;
            }
        }
        writefln("%s,%d,%f,%f,%f,%d,%f,%f",
            dt.toISOExtString, c, reduce!(min)(rps), mean(rps), reduce!max(rps),
            reduce!max(errors), mean(perc75), mean(perc99));
        stdout.flush();
        Thread.sleep(100.msecs);
    }
    return 0;
}
