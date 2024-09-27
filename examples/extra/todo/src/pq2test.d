/+ dub.json:
  {
	"authors": [
		"Dmitry Olshansky"
	],
	"copyright": "Copyright © 2024, Dmitry Olshansky",
	"dependencies": {
		"photon": { "path": "../.." },
        "photon-http": "~>0.4.5",
		"dpq2" : "~>1.1.7"
	},
	"description": "An example app using Postgres DPQ2 and Photon's pool API",
	"license": "BOOST",
	"name": "todo"
}
+/
module examples.extra.todo;

import dpq2;
import std.algorithm;
import std.format;
import std.socket, std.stdio, std.datetime;
import std.file: readFile = read;
import std.json, std.array;
import photon, photon.http;

immutable string escapables = `"\`; // should escape also all of [0x0, 0x1f]

string escape(string inp) {
    if (inp.canFind!(d => escapables.canFind(d))) {
        auto app = appender!(string);
        foreach (d; inp) {
            if (d < 0x20){
                formattedWrite(app, `\u00%02x`, d);
            }
            else if(escapables.canFind(d)) {
                app.put('\\');
            }
            else {
                app.put(d);
            }
        }
        return app.data;
    }
    else
        return inp;
}

alias DbPool = shared Pool!Connection;

class AppProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "application/json")];
	DbPool pgPool;

    this(Socket sock, DbPool pgPool) {
		super(sock);
		this.pgPool = pgPool;
	}

    void list(HttpRequest req, Connection conn) {
        QueryParams cmd;
        cmd.sqlCommand = "SELECT * FROM todo";
        auto answer = conn.execParams(cmd);
        auto list = appender!(string);
        list.put("[");
        foreach (a; rangify(answer)) {
            auto id = a[0].as!PGinteger;
            auto msg = a[1].as!PGtext;
            formattedWrite(list, `{"id": %s, "text": "%s"}`, id, msg);
        }
        list.put("]");
        respondWith(list.data, 200, headers);
    }

    void add(HttpRequest req, Connection conn) {
        QueryParams params;
        params.sqlCommand = "INSERT INTO todo (msg) VALUES($1) RETURNING ID";
        writeln(req.body_);
        JSONValue jval = parseJSON(req.body_);
        auto msg = jval.object()["msg"].str();
        params.argsVariadic(msg);
        auto anwser = conn.execParams(params);
        // answer[0]
        respondWith(`{ "status": "OK" }`, 200, headers);
    }

    void delete_(HttpRequest req, Connection conn) {
        respondWith("{}", 200, headers);
    }

    void processWithConnection(HttpRequest req, void delegate(HttpRequest, Connection) processor) {
        auto conn = pgPool.acquire();
        scope(success) pgPool.release(conn);
        scope(failure) pgPool.dispose(conn);
        processor(req, conn);
    }
    
    override void handle(HttpRequest req) {
        try {
            switch (req.uri) {
                case "/list":
                    processWithConnection(req, &list);
                    break;
                case "/add":
                    processWithConnection(req, &add);
                    break;
                case "/delete":
                    processWithConnection(req, &delete_);
                    break;
                case "/":
                    respondWith(cast(char[])readFile("index.html"), 200, [HttpHeader("Content-Type", "text/html; charset=utf-8")]);
                    break;
                default:
                    respondWith("", 404, headers);
            }    
        }
        catch (Exception e) {
            writefln("Error during processing of request %s", e);
            respondWith(e.toString(), 500, [HttpHeader("Content-Type", "text/plain; charset=utf8")]);
            sock.close();
        }    
    }
}

void server_worker(Socket client, DbPool pgPool) {
    scope processor =  new AppProcessor(client, pgPool);
    processor.run();
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
        scope(exit) pgPool.release(conn);
        conn.exec("CREATE TABLE IF NOT EXISTS todo (id SERIAL, msg text)");
        pgPool.release(conn);
		server(pgPool);
    });
    runFibers();
}