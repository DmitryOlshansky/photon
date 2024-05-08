/+ dub.json:
  {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": "../.." },
		"dpq2" : "~>1.1.7"
	},
	"description": "An example app using pool API",
	"license": "BOOST",
	"name": "todo"
}
+/
module examples.extra.todo;

import dpq2;

import photon;

void main() {
    startloop();
    go({
        Connection conn = new Connection("host=localhost port=5432 user=postgres password=12345678");
        conn.exec("CREATE TABLE IF NOT EXISTS todo (id SERIAL, msg text)");
        destroy(conn);
    });
    runFibers();
}