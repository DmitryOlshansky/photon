/+ dub.json:
    {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "A test for task join API",
	"license": "BOOST",
	"name": "join"
}
+/
module examples.join;

import photon;

void main() {
    initPhoton();
    shared int flag = 0;
    auto task1 = go({
        flag = 1;
    });
    auto failedTask = go({
        throw new Exception("Boom!");
    });
    auto task2 = go({
        task1.join();
        assert(flag == 1);
        try {
            failedTask.join();
            assert(false);
        } catch(Exception e) {
            assert(e.msg == "Boom!");
        }
    });
    runScheduler();
}
