/** Automatic rescans after calls through patched LoadLibrary imports. */
module photon.windows.iat_loader;
version (Windows):

import core.sys.windows.windows;
import photon.windows.iat;
import std.exception : enforce;
import std.windows.syserror : wenforce;

private __gshared {
    typeof(&LoadLibraryA) realA;
    typeof(&LoadLibraryW) realW;
    typeof(&LoadLibraryExA) realExA;
    typeof(&LoadLibraryExW) realExW;
    IatHook[] activeHooks;
    HMODULE[] exclusions;
    CRITICAL_SECTION scanLock;
    bool installed;
}
private bool insideLoad; // TLS recursion guard, including nested loads in DllMain.

/// Last automatic scan failure on this thread; null following a successful scan.
/// A load result and its GetLastError are preserved even when patching fails.
Exception automaticIatError;

/** Install once during single-threaded startup, outside DllMain. Subsequent
 * calls rescan the original configuration. Loading/unloading must be serialized
 * by the application; this sketch does not intercept FreeLibrary or LdrLoadDll.
 */
size_t installAutomaticIatPatching(const(IatHook)[] hooks, const(HMODULE)[] excluded = null) {
    if (installed) return rescan();
    auto kernel = GetModuleHandleA("kernel32.dll");
    auto base = GetModuleHandleA("kernelbase.dll");
    wenforce(kernel, "Cannot find kernel32");
    realA = cast(typeof(realA))GetProcAddress(kernel, "LoadLibraryA");
    realW = cast(typeof(realW))GetProcAddress(kernel, "LoadLibraryW");
    realExA = cast(typeof(realExA))GetProcAddress(kernel, "LoadLibraryExA");
    realExW = cast(typeof(realExW))GetProcAddress(kernel, "LoadLibraryExW");
    enforce(realA && realW && realExA && realExW, "Cannot resolve loader exports");
    foreach (hook; hooks)
        activeHooks ~= IatHook(cast(void*)hook.original, cast(void*)hook.replacement);
    foreach (module_; excluded) exclusions ~= cast(HMODULE)module_;
    exclusions ~= kernel;
    if (base) exclusions ~= base;
    // Match both export providers: modern imports may use KernelBase directly.
    void*[4] replacements = [cast(void*)&loadA, cast(void*)&loadW, cast(void*)&loadExA, cast(void*)&loadExW];
    foreach (provider; [kernel, base]) {
        if (!provider) continue;
        foreach (i, name; ["LoadLibraryA", "LoadLibraryW", "LoadLibraryExA", "LoadLibraryExW"]) {
            auto original = GetProcAddress(provider, name.ptr);
            if (original) activeHooks ~= IatHook(cast(void*)original, replacements[i]);
        }
    }
    InitializeCriticalSection(&scanLock);
    // Publish complete state before changing any import. Partial installation
    // failures remain usable and retryable, just like the underlying patcher.
    installed = true;
    return rescan();
}

private size_t rescan() {
    EnterCriticalSection(&scanLock);
    scope(exit) LeaveCriticalSection(&scanLock);
    auto previous = insideLoad;
    insideLoad = true;
    scope(exit) insideLoad = previous;
    return patchLoadedImports(activeHooks, exclusions);
}

private void afterLoad(HMODULE result, DWORD flags) nothrow {
    enum DWORD LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE = 0x40;
    enum DWORD LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x20;
    if (!result || (cast(size_t)result & 3) ||
        (flags & (DONT_RESOLVE_DLL_REFERENCES | LOAD_LIBRARY_AS_DATAFILE |
            LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE | LOAD_LIBRARY_AS_IMAGE_RESOURCE))) return;
    try {
        rescan();
        automaticIatError = null;
    } catch (Exception error) {
        // Never unwind a D exception through the caller's C ABI or pretend a
        // successful LoadLibrary failed (which would leak its module reference).
        automaticIatError = error;
    }
}

private extern(Windows) HMODULE loadA(LPCSTR name) nothrow {
    if (insideLoad) return realA(name);
    insideLoad = true;
    scope(exit) insideLoad = false;
    auto result = realA(name);
    auto error = GetLastError();
    afterLoad(result, 0);
    SetLastError(error);
    return result;
}

private extern(Windows) HMODULE loadW(LPCWSTR name) nothrow {
    if (insideLoad) return realW(name);
    insideLoad = true;
    scope(exit) insideLoad = false;
    auto result = realW(name);
    auto error = GetLastError();
    afterLoad(result, 0);
    SetLastError(error);
    return result;
}

private extern(Windows) HMODULE loadExA(LPCSTR name, HANDLE file, DWORD flags) nothrow {
    if (insideLoad) return realExA(name, file, flags);
    insideLoad = true;
    scope(exit) insideLoad = false;
    auto result = realExA(name, file, flags);
    auto error = GetLastError();
    afterLoad(result, flags);
    SetLastError(error);
    return result;
}

private extern(Windows) HMODULE loadExW(LPCWSTR name, HANDLE file, DWORD flags) nothrow {
    if (insideLoad) return realExW(name, file, flags);
    insideLoad = true;
    scope(exit) insideLoad = false;
    auto result = realExW(name, file, flags);
    auto error = GetLastError();
    afterLoad(result, flags);
    SetLastError(error);
    return result;
}
