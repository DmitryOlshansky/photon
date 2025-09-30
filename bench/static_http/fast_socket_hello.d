#!/usr/bin/env dub
/+ dub.json:
    {
        "name" : "hello",
        "dependencies": {
            "photon": { "path" : "../.." },
            "photon-http": "0.5.6"
        }
    }
+/
module photon.bench.static_http.fast_socket_hello;

import std.stdio;
import std.socket;

import std.array, std.range, std.format, std.algorithm;

import photon, photon.http.http_server, photon.http;
import glow.xbuf;

struct Output {
    ubyte[] array;
    size_t offset;

    void put(const(char)[] fragment) {
        array[offset .. offset + fragment.length] = (cast(ubyte*)fragment.ptr)[0..fragment.length];
        offset += fragment.length;
    }

    ref auto opOpAssign(string op)(const(char)[] fragment)
    {
        put(fragment);
        return this;
    }

    ubyte[] data() {
        return array[0..offset];
    }

    void clear() {
        offset = 0;
    }
}

abstract class HttpProcessor {
	FastSocket sock;
    Output buf;
    ubyte[] data;
    ubyte[] recvData;
	RioBuffer rioBuf;
    RioBuffer recvRioBuf;
    bool connectionClose;
    
	this(FastSocket sock) {
		this.sock = sock;
        data = new ubyte[8096];
        recvData = new ubyte[8096];
        rioBuf = RioBuffer(data);
        recvRioBuf = RioBuffer(recvData);
        buf = Output(data, 0);
	}

	void respondWith(const(char)[] range, int status, HttpHeader[] headers) {
		buf.clear();
		buf.formattedWrite("HTTP/1.1 %d OK\r\n", status);
		foreach (header; headers)
		{
			buf.formattedWrite("%s: %s\r\n", header.key, header.value);
		}
		buf ~= "Server: photon-http\r\n";
		auto t = atomicLoad(httpDate);
		buf ~= cast(const char[])*t;
		if (connectionClose) {
			buf ~= "Connection: close\r\n";
		}
		buf.formattedWrite("Content-Length: %d\r\n", range.length);
		buf ~= "\r\n";
		buf ~= range;
		sock.send(rioBuf[0..buf.offset]);
	}

	void respondWith(InputRange!dchar range, int status, HttpHeader[] headers) {
		char[] buf;
		foreach (el; range){
			buf ~= cast(char)el;
		}
		respondWith(buf, status, headers);
	}

    void handle(HttpRequest req);

	int read(ubyte[] s) nothrow {
		try {
			return cast(int)sock.receive(recvRioBuf);
		} catch(Throwable e) {
			assert(false);
		}
	}

	void run() {
		/+XBuf buf = XBuf(8096, 1024, &this.read);
		Parser parser = Parser(move(buf));+/
		for (;;) {
			HttpRequest request;
			/+int r = parser.parse(request);
			connectionClose = parser.connectionClose;
			if (r == 0) break;
			else if (r < 0) {
				if (parser.error.ptr) {
					throw new Exception("Failed during http parsing: %s".format(parser.error));
				}
				throw new Exception("I/O error %s".format(GetLastError()));
			}+/
            int received = sock.receive(recvRioBuf);
            if (received <= 0) break;
			handle(request);
			//if (connectionClose) break;
		}
	}
}

class HelloWorldProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "text/plain; charset=utf-8")];

    this(FastSocket sock){ super(sock); }
    
    override void handle(HttpRequest req) {
        respondWith("Hello, world!", 200, headers);
    }
}


void server_worker(FastSocket client) {
    scope processor =  new HelloWorldProcessor(client);
    try {
        processor.run();
    }
    catch(Exception e) {
        stderr.writeln(e);
    }
}

void server() {
    try {
        initFastSockets();
        FastSocket server = new FastSocket();
        int reuseAddr = 1;
        server.setsockopt(SOL_SOCKET, SO_REUSEADDR, &reuseAddr, reuseAddr.sizeof);
        sockaddr_in addr;
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(8080);
        server.bind(cast(sockaddr*)&addr, addr.sizeof);
        server.listen(1000);

        debug writeln("Started server");

        void processClient(FastSocket client) {
            go(() => server_worker(client));
        }

        while(true) {
            try {
                debug writeln("Waiting for server.accept()");
                FastSocket client = server.accept();
                debug writeln("New client accepted");
                processClient(client);
            }
            catch(Exception e) {
                writefln("Failure to accept %s", e);
            }
        }
    } catch (Exception e) {
        stderr.writefln("Got exception while setting up the server: %s", e);
    }
}

void main() {
    initPhoton();
    go(() => server());
    runScheduler();
}
