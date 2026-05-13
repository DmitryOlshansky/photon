/+ dub.json:
    {
	"dependencies": {
		"photon": { "path": ".." }
	},
	"description": "Echo server as presented in issue 63",
	"license": "BOOST",
	"name": "issue_63"
}
+/
module echo_server_63;
import std.stdio;
import std.socket;
import photon;

__gshared int totalRecvCount = 0;

void server_worker(int id, Socket client) {
    char[1024] buffer;
    int recvCount;
    try {
        while (true) {
            auto received = client.receive(buffer);
            if (received <= 0) break;
            recvCount++;
            atomicFetchAdd(totalRecvCount, 1);
            string responseStr = buffer[0 .. received].idup ~ "!";
            client.send(responseStr);
        }
    } catch (Exception e) { stderr.writeln(e); }
    finally {
        client.close();
        debug writefln("Client %d disconnected:recv count %d, totalRecvCount %d",
                       id, recvCount, totalRecvCount);
    }
}

void server() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("0.0.0.0", 8080));
    server.listen(1000);
    debug writeln("Started server");

    void processClient(int id, Socket client) {
        go(() => server_worker(id, client));
    }

    int id;
    while (true) {
        try {
            Socket client = server.accept();
            debug writeln("New client accepted:", id);
            processClient(id, client);
            id++;
        } catch (Exception e) {
            writefln("Failure to accept %s", e);
        }
    }
}

void main() {
    initPhoton();
    go(() => server());
    runScheduler();
}
