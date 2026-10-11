module windows_iat;
import photon.windows.iat;
import photon.windows.iat_loader;
import core.sys.windows.windows;
import core.sys.windows.winsock2;
import std.stdio : writeln, stdout;
pragma(lib, "ws2_32");

extern(Windows) int fakeSend(SOCKET, const(char)*, int, int) { return 101; }
extern(Windows) int fakeRecv(SOCKET, char*, int, int) { return 102; }
extern(Windows) SOCKET fakeAccept(SOCKET, sockaddr*, int*) { return 103; }
extern(Windows) SOCKET fakeSocket(int, int, int) { return 104; }

void main() {
    writeln("Starting IAT routing test"); stdout.flush();
    auto provider = LoadLibraryA("ws2_32.dll");
    assert(provider);
    IatHook[] hooks = [
        IatHook(cast(void*)GetProcAddress(provider, "send"), cast(void*)&fakeSend),
        IatHook(cast(void*)GetProcAddress(provider, "recv"), cast(void*)&fakeRecv),
        IatHook(cast(void*)GetProcAddress(provider, "accept"), cast(void*)&fakeAccept),
        IatHook(cast(void*)GetProcAddress(provider, "socket"), cast(void*)&fakeSocket)
    ];
    assert(patchLoadedImports(hooks, [provider]) >= 4);
    writeln("Patched EXE imports"); stdout.flush();
    assert(send(INVALID_SOCKET, null, 0, 0) == 101);
    assert(recv(INVALID_SOCKET, null, 0, 0) == 102);
    assert(accept(INVALID_SOCKET, null, null) == 103);
    assert(socket(0, 0, 0) == 104);
    assert(patchLoadedImports(hooks, [provider]) == 0);

    // Load a DLL after the initial scan, then explicitly rescan.
    auto dll = LoadLibraryA(".dub\\windows_iat_dll.dll");
    assert(dll);
    alias Probe = extern(C) int function();
    auto probe = cast(Probe)GetProcAddress(dll, "probe");
    assert(probe && probe() == 0);
    assert(patchLoadedImports(hooks, [provider]) >= 4);
    assert(probe() == 1);
    assert(patchLoadedImports(hooks, [provider]) == 0);
    // GetProcAddress still resolves the real export, not an IAT slot.
    assert(cast(void*)GetProcAddress(provider, "send") == hooks[0].original);
    FreeLibrary(dll);

    assert(installAutomaticIatPatching(hooks, [provider]) > 0);
    // Each iteration unloads the fixture so its IAT starts fresh next time.
    foreach (kind; 0 .. 4) {
        switch (kind) {
        case 0: dll = LoadLibraryA(".dub\\windows_iat_dll.dll"); break;
        case 1: dll = LoadLibraryW(".dub\\windows_iat_dll.dll"w.ptr); break;
        case 2: dll = LoadLibraryExA(".dub\\windows_iat_dll.dll", null, 0); break;
        default: dll = LoadLibraryExW(".dub\\windows_iat_dll.dll"w.ptr, null, 0); break;
        }
        assert(dll);
        assert(automaticIatError is null);
        probe = cast(Probe)GetProcAddress(dll, "probe");
        assert(probe && probe() == 1); // No explicit rescan.
        FreeLibrary(dll);
    }
    auto originalLoader = cast(typeof(&LoadLibraryA))GetProcAddress(
        GetModuleHandleA("kernel32.dll"), "LoadLibraryA");
    assert(originalLoader("photon-nonexistent-iat-test.dll") is null);
    auto expectedError = GetLastError();
    assert(LoadLibraryA("photon-nonexistent-iat-test.dll") is null);
    assert(GetLastError() == expectedError);
    dll = LoadLibraryExW(".dub\\windows_iat_dll.dll"w.ptr, null, LOAD_LIBRARY_AS_DATAFILE);
    assert(dll);
    FreeLibrary(dll);
    writeln("IAT: manual routing, four automatic loader hooks, reloads, and errors passed");
}
