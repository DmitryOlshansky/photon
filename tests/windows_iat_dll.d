// A separately linked consumer, with no dependency on Photon.
module windows_iat_dll;
import core.sys.windows.winsock2;
pragma(lib, "ws2_32");
import core.sys.windows.windows : HINSTANCE, DWORD, LPVOID, BOOL, TRUE;
extern(Windows) BOOL DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }

export extern(C) int probe() {
    return send(INVALID_SOCKET, null, 0, 0) == 101 &&
        recv(INVALID_SOCKET, null, 0, 0) == 102 &&
        accept(INVALID_SOCKET, null, null) == 103 &&
        socket(0, 0, 0) == 104;
}
