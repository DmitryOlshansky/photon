#!/usr/bin/env dub
/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2025, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for offload primitive",
	"license": "BOOST",
	"name": "offloaded"
}
+/
module offloaded;
import photon;

double gauss(double a, double b, double function(double) f, double step) {
    double sum = 0.0;
    for (double x = a; x < b; x += step) {
        sum += (f(x+step) + f(x))/2 * step;
    }
    return sum;
}

void boom() {
    throw new Exception("Boom!");
}

long fib(long n) {
    if (n <= 2) return 1;
    else {
        return offload(() => fib(n-1)) + offload(() => fib(n-2));
    }
}

void main() {
    initPhoton();
    go({
        goOnSameThread({
            writeln("Blocking computation");
            writeln("Integral:", gauss(0.0, 10.0, x => x*x, 1e-7));
        });
        goOnSameThread({
            writeln("Blocking computation");
            writeln("Integral:", gauss(0.0, 10.0, x => x*x, 1e-7));
        });
        goOnSameThread({
            writeln("Nonblocking computation");
            writeln("Integral: ", offload(() => gauss(0.0, 10.0, x => x*x, 1e-7)));
        });
        goOnSameThread({
            writeln("Nonblocking computation");
            writeln("Integral: ", offload(() => gauss(0.0, 10.0, x => x*x, 1e-7)));
        });
        goOnSameThread({
            writeln("Catching exception from offloaded computation");
            try {
                offload(&boom);
                assert(0);
            } catch(Exception e) {
                assert(e.msg == "Boom!");
            }
        });
        goOnSameThread({
            writeln("Recursive offload");
            writeln("Fib(15):", offload(() => fib(15)));
        });
    });
    runScheduler();
}