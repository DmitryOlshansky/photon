module photon.windows.fast_sockets;

import photon.windows.core;
import core.sys.windows.core;
import std.socket, std.algorithm.comparison;

private:
// ===========================================================================
// FAST SOCKETS
// ===========================================================================

__gshared RIO_EXTENSION_FUNCTION_TABLE rio;
__gshared LPFN_ACCEPTEX AcceptEx;

public class FastSocket {
    private this(int proto) {
        sock = WSASocketW(AF_INET, SOCK_STREAM, proto, null, 0, WSA_FLAG_REGISTERED_IO | WSA_FLAG_OVERLAPPED);
        wenforce(sock != INVALID_SOCKET);
        setupSocket();
        registerSocket(sock);
    }

    void bind(const(sockaddr)* addr, socklen_t namelen) {
        wenforce(.bind(sock, addr, namelen) != SOCKET_ERROR);
    }

    void bind(Address addr) {
        bind(sock, addr.name(), addr.nameLen());
    }

    void setsockopt(int level, int optname, const(void)* optvalue, socklen_t optlen) {
        wenforce(.setsockopt(sock, level, optname, optvalue, optlen) != SOCKET_ERROR);
    }

    void listen(int backlog) {
        wenforce(.listen(sock, backlog) == 0);
    }

    FastSocket accept() {
        ubyte[128] buf = void;
        DWORD bytesRecieved = 0;
        overlapped.fiber = currentFiber;
        FastSocket accepted = new FastSocket();
        BOOL ret = AcceptEx(
            sock,
            accepted.sock,
            buf.ptr,
            0,
            32,
            32,
            &bytesRecieved,
            &overlapped
        );
        wenforce(WSAGetLastError() == ERROR_IO_PENDING || ret);
        FiberExt.yield();
        return accepted;
    }

    int send(FastBuffer buf) {
        overlapped.fiber = currentFiber;
        wenforce(rio.RIOSend(rq, &buf.buf, 1, 0, cast(void*)this));
        FiberExt.yield();
        RIORESULT result;
        wenforce(rio.RIODequeueCompletion(cq, &result, 1) == 1);
        return result.BytesTransferred;
    }

    int receive(FastBuffer buf) {
        overlapped.fiber = currentFiber;
        wenforce(rio.RIOReceive(rq, &buf.buf, 1, 0, cast(void*)this));
        FiberExt.yield();
        RIORESULT result;
        wenforce(rio.RIODequeueCompletion(cq, &result, 1) == 1);
        return result.BytesTransferred;
    }

    void close() {
        close(sock);
    }

private:
    void setupSocket() {
        RIO_NOTIFICATION_COMPLETION compl;
        compl.IocpHandle = cast(HANDLE)scheds[currentFiber.numScheduler].iocp;
        compl.CompletionKey = cast(void*)sock;
        compl.Overlapped = cast(OVERLAPPED*)&overlapped;
        compl.Type = RIO_NOTIFICATION_COMPLETION_TYPE.RIO_IOCP_COMPLETION;
        cq = rio.RIOCreateCompletionQueue(2, &compl);
        wenforce(cq);
        wenforce(rio.RIONotify(cq) == ERROR_SUCCESS);
        rq = rio.RIOCreateRequestQueue(sock,  1, 1, 1, 1, cq, cq, cast(void*)this);
        wenforce(rq);
    }

    RIO_RQ rq;
    RIO_CQ cq;
    Overlapped overlapped;
    SOCKET sock;
}

enum MAX_POOL_SIZE = (1UL<<30);

///
public class FastSockets {
    ///
    this(size_t bufferPoolSize) {
        assert(bufferPoolSize & 0xFFFF == 0);
        GUID guid = WSAID_MULTIPLE_RIO;
        auto sock = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_REGISTERED_IO | WSA_FLAG_OVERLAPPED);
        wenforce(sock != INVALID_SOCKET);
        DWORD bytesReturned = 0;
        int result = WSAIoctl(
            sock,
            SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
            &guid,
            guid.sizeof,
            &rio,
            rio.sizeof,
            &bytesReturned,
            null,
            null
        );
        if (result != 0) {
            stderr.writeln("Error: ", GetLastError());
        }
        wenforce(result == 0);
        closesocket(sock);
        sock = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_REGISTERED_IO | WSA_FLAG_OVERLAPPED);
        wenforce(sock != INVALID_SOCKET);
        auto acceptExGuid = WSAID_ACCEPTEX;
        result = WSAIoctl(
            sock,
            SIO_GET_EXTENSION_FUNCTION_POINTER,
            &acceptExGuid,
            acceptExGuid.sizeof,
            &AcceptEx,
            AcceptEx.sizeof,
            &bytesReturned,
            null,
            null
        );
        wenforce(result == 0);
        auto mem = VirtualAlloc(null, bufferPoolSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        wenforce(mem);
        for (size_t start = 0; start < bufferPoolSize; start += MAX_POOL_SIZE) {
            pools ~= FastBufferPool(mem[start .. min(start +  (1<<30), bufferPoolSize)]);
        }
    }
    ///
    FastSocket socket(int proto = IPPROTO_TCP) {
        return new FastSocket(proto);
    }
    ///
    FastBuffer allocate(size_t size) {

    }
    ///
    FastBuffer reallocate(FastBuffer buf, size_t size) {

    }
    ///
    void deallocate(FastBuffer buf) {
        foreach (pool; pools) {
            if (pool.id == buf.buf.BufferId) {
                pool.deallocate(buf);
            }
        }
    }

private:
    FastBufferPool[] pools;
}

enum BUFFER_LINE = 64;

struct FastBufferPool {
    this(ubyte[] memory) {
        auto id = rio.RIORegisterBuffer(cast(CHAR*)memory.ptr, cast(uint)memory.length);
        RIO_BUF buf;
        buf.BufferId = id;
        buf.Offset = 0;
        buf.Length = cast(uint)memory.length;
        buffer = FastBuffer(memory, buf);
        bitmap = new ubyte[memory.length / 8 / BUFFER_LINE];
    }

    FastBuffer allocate() {

    }

    FastBuffer reallocate(FastBuffer buf, size_t newSize) {

    }

    void deallocate(FastBuffer buf) {
        
    }
private:
    FastBuffer buffer;
    ubyte[] bitmap;
}

public struct FastBuffer {
    ubyte[] slice;
    RIO_BUF buf;
    
    private this(ubyte[] slice, RIO_BUF buf) {
        this.slice = slice;
        this.buf = buf;
    }

    this(ubyte[] source) {
        
    }

    bool empty() { return buf.Length == 0; }

    FastBuffer opSlice(size_t from, size_t to)
    {
        return RioBuffer(RIO_BUF(buf.BufferId, cast(uint)(buf.Offset + from), cast(uint)(to - from)));
    }
}

void initFastSockets() {
    
}


