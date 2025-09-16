/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "Simple verification that goOnSameThread indeed puts fiber on the calling fiber's scheduler",
	"license": "BOOST",
	"name": "go_same_thread"
}
+/
import photon;
import std.stdio;

int placeholder;
int placeholder2;

void main(){
    initPhoton();
    placeholder = 4;
    goOnSameThread({
		assert(placeholder == 4);
		writeln("Func version is done");
    });
	int k = 0;
	goOnSameThread({
		assert(k == 1);
		writeln("Delegate version is done");
	});
	k = 1;
	go({
		placeholder2 = 42;
		goOnSameThread({
			assert(placeholder2 == 42);
			writeln("Spawning inside of go is done");
		});
	});
    runScheduler();
}