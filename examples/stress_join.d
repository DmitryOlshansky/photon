#!/usr/bin/env dub
/+ dub.json:
    {
	"authors": [
		"mzfhhhh"
	],
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for deeply nested joins",
	"license": "BOOST",
	"name": "stress_join"
}
+/
module examples.stress_join;

import std.stdio :  stderr;
import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.time : msecs;
import photon;

shared int g_alive;        
shared int g_round;       
shared bool g_done;     

enum ROUNDS = 100;
enum PER_ROUND = 100;

void runRounds(string tag, void delegate() func)
{
    go({
        for (int c = 0; c < ROUNDS; c++) {
            atomicStore(g_round, c);
            stderr.writeln(tag, " round=", c);
            for (int i = 0; i < PER_ROUND; i++) {
                go(func);
            }
            // wait all done
            delay(100.msecs);
            while (atomicLoad(g_alive) != 0) {
                delay(100.msecs);
            }
        }
        atomicStore(g_done, true);
        stderr.writeln(tag, " all rounds done");
    });
}

void testJoin()
{
    void ttt()
    {
        atomicOp!"+="(g_alive, 1);
        scope(exit) atomicOp!"-="(g_alive, 1);
        auto writerFiber = go({
            // delay(10.msecs);
        });
        writerFiber.join();
    }
    runRounds("join", &ttt);
}
 
void main(string[] args)
{
    initPhoton();
    testJoin();
    runScheduler();
}