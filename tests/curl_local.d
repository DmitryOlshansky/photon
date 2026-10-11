/+ dub.json:
{"name":"curl-local","dependencies":{"photon":{"path":".."}},
 "debugVersions":["photon_single"]}
+/
// Deterministic loopback regression: independent 200ms responses should overlap.
import photon;
import std.socket;
import std.net.curl : get, HTTP;
import std.stdio;
import std.conv : to;
import std.datetime.stopwatch;
import core.thread : Thread;
import core.time : msecs;

void main() {
    try { run(); }
    catch (Throwable e) {
        writeln("Regression failed: ", e.msg); stdout.flush();
        import core.stdc.stdlib : exit;
        exit(1);
    }
}

void run() {
    initPhoton();
    auto listener = new TcpSocket;
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(32);
    auto port = (cast(InternetAddress)listener.localAddress).port;
    enum requests = 6;
    auto server = new Thread({
        Thread[] clients;
        foreach (i; 0 .. requests * 2) {
            auto socket = listener.accept();
            Thread serve(Socket socket) { return new Thread({
                scope(exit) socket.close();
                char[4096] request;
                size_t received;
                import std.algorithm : canFind;
                while (!request[0 .. received].canFind("\r\n\r\n")) {
                    auto n = socket.receive(request[received .. $]);
                    assert(n > 0, "Server receive failed: " ~ n.to!string);
                    received += n;
                }
                Thread.sleep(200.msecs);
                immutable response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
                size_t sent;
                while (sent < response.length) {
                    auto n = socket.send(response[sent .. $]);
                    assert(n > 0);
                    sent += n;
                }
            }); }
            auto client = serve(socket);
            client.start();
            clients ~= client;
        }
        foreach (client; clients) client.join();
    });
    server.start();
    auto url = "http://127.0.0.1:" ~ port.to!string ~ "/";
    void download() {
        auto http = HTTP();
        http.proxy = "";
        assert(get(url, http) == "OK");
    }
    auto watch = StopWatch(AutoStart.yes);
    foreach (i; 0 .. requests) download();
    auto sequential = watch.peek.total!"msecs";
    version (Windows) {
        import photon.windows.iat_loader : automaticIatError;
        assert(automaticIatError is null, "Automatic libcurl IAT patching failed");
    }
    watch.reset();
    foreach (i; 0 .. requests) go(&download);
    runScheduler();
    auto concurrent = watch.peek.total!"msecs";
    server.join();
    listener.close();
    writefln("Sequential: %s ms; one-scheduler fibers: %s ms", sequential, concurrent);
    assert(concurrent * 2 < sequential, "Readiness waits serialized fiber downloads");
}
