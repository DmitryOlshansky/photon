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
import std.socket, std.stdio, std.datetime;
import photon, photon.http;


alias DbPool = shared Pool!Connection;

class HelloWorldProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "text/html; charset=utf-8")];
	DbPool pgPool;

    this(Socket sock, DbPool pgPool) {
		super(sock);
		this.pgPool = pgPool;
	}
    
    override void handle(HttpRequest req) {
        respondWith("Hello, world!", 200, headers);
    }
}

void server_worker(Socket client, DbPool pgPool) {
    scope processor =  new HelloWorldProcessor(client, pgPool);
    try {
        processor.run();
    }
    catch(Exception e) {
        stderr.writeln(e);
    }
}

void server(DbPool pgPool) {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("0.0.0.0", 8080));
    server.listen(1000);

    debug writeln("Started server");

    void processClient(Socket client) {
        go(() => server_worker(client, pgPool));
    }

    while(true) {
        try {
            debug writeln("Waiting for server.accept()");
            Socket client = server.accept();
            debug writeln("New client accepted");
            processClient(client);
        }
        catch(Exception e) {
            writefln("Failure to accept %s", e);
        }
    }
}

void main() {
    startloop();
	auto connect() {
		return new Connection("host=localhost port=5432 user=postgres password=12345678");
	}
	void disconnect(ref Connection con) {
		destroy(con);
	}
    go({
		auto pgPool = pool(10, 15.seconds, &connect, &disconnect);
		auto conn = pgPool.acquire();
        conn.exec("CREATE TABLE IF NOT EXISTS todo (id SERIAL, msg text)");
        pgPool.release(conn);
		server(pgPool);
    });
    runFibers();
}