/** Opt-in, current-process IAT patching sketch. See docs/windows-iat.md. */
module photon.windows.iat;
version (Windows):

import core.atomic : atomicLoad, cas, MemoryOrder;
import core.sys.windows.windows;
import core.sys.windows.tlhelp32;
import std.exception : enforce;
import std.windows.syserror : wenforce;

struct IatHook {
    void* original;
    void* replacement;
}

/**
 * Patch ordinary imports in the EXE and every DLL in a module snapshot.
 * Call from a serialized startup/plugin-load path, outside DllMain, with module
 * loading/unloading quiescent. Keep replacement code loaded for process lifetime.
 * Returns the number of changed slots; repeated calls are harmless.
 * Failure throws and may leave a partially patched process (no rollback).
 */
size_t patchLoadedImports(const(IatHook)[] hooks, const(HMODULE)[] excluded = null) {
    foreach (hook; hooks)
        enforce(hook.original !is null && hook.replacement !is null,
            "IAT hooks must have original and replacement addresses");

    HANDLE snapshot;
    // Windows explicitly permits retrying a snapshot after ERROR_BAD_LENGTH.
    foreach (attempt; 0 .. 8) {
        snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
        if (snapshot != INVALID_HANDLE_VALUE || GetLastError() != ERROR_BAD_LENGTH)
            break;
    }
    wenforce(snapshot != INVALID_HANDLE_VALUE, "Module snapshot failed");
    scope(exit) CloseHandle(snapshot);
    MODULEENTRY32W entry;
    entry.dwSize = entry.sizeof;
    auto present = Module32FirstW(snapshot, &entry);
    size_t changed;
    while (present) {
        bool skip;
        foreach (module_; excluded)
            if (module_ == entry.hModule) skip = true;
        if (!skip) {
            // Hold a reference throughout PE traversal and VirtualProtect.
            HMODULE held;
            wenforce(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                cast(LPCWSTR)entry.modBaseAddr, &held), "Module reference failed");
            scope(exit) FreeLibrary(held);
            changed += patchImage(cast(ubyte*)held, entry.modBaseSize, hooks);
        }
        present = Module32NextW(snapshot, &entry);
    }
    wenforce(GetLastError() == ERROR_NO_MORE_FILES, "Module enumeration failed");
    return changed;
}

private size_t patchImage(ubyte* base, size_t size, const(IatHook)[] hooks) {
    bool fits(size_t rva, size_t length) { return rva <= size && length <= size - rva; }
    enforce(fits(0, IMAGE_DOS_HEADER.sizeof), "Truncated DOS header");
    auto dos = cast(IMAGE_DOS_HEADER*)base;
    enforce(dos.e_magic == IMAGE_DOS_SIGNATURE && dos.e_lfanew >= 0,
        "Invalid DOS header");
    enforce(fits(dos.e_lfanew, IMAGE_NT_HEADERS.sizeof), "Truncated PE header");
    auto nt = cast(IMAGE_NT_HEADERS*)(base + dos.e_lfanew);
    enforce(nt.Signature == IMAGE_NT_SIGNATURE &&
        nt.OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR_MAGIC, "Invalid native PE header");
    if (nt.OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT) return 0;
    auto directory = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!directory.VirtualAddress || !directory.Size) return 0;
    enforce(fits(directory.VirtualAddress, directory.Size), "Invalid import directory");
    auto descriptors = cast(IMAGE_IMPORT_DESCRIPTOR*)(base + directory.VirtualAddress);
    size_t changed;
    foreach (i; 0 .. directory.Size / IMAGE_IMPORT_DESCRIPTOR.sizeof) {
        auto descriptor = descriptors + i;
        if (!descriptor.Name) break;
        if (!descriptor.FirstThunk) continue;
        size_t rva = descriptor.FirstThunk;
        for (;; rva += size_t.sizeof) {
            enforce(fits(rva, size_t.sizeof), "Unterminated IAT");
            auto slot = cast(shared(size_t)*)(base + rva);
            // DMD's sequentially consistent load can use a locked cmpxchg,
            // which faults on a read-only IAT. An acquire load only reads it.
            auto previous = atomicLoad!(MemoryOrder.acq)(*slot);
            if (!previous) break;
            // Resolved-address matching also handles ordinal imports and images
            // without OriginalFirstThunk. Existing third-party hooks are left alone.
            foreach (hook; hooks) {
                if (previous != cast(size_t)hook.original || hook.original == hook.replacement)
                    continue;
                // MinGW DLLs can have only DWORD-aligned PE32+ IATs.
                // x86/x64 locked CMPXCHG supports unaligned memory operands.
                // Other architectures must not use this path unaligned.
                version (D_InlineAsm_X86) {} else version (D_InlineAsm_X86_64) {} else
                    enforce(rva % size_t.sizeof == 0, "Unaligned target IAT slot");
                DWORD oldProtection;
                MEMORY_BASIC_INFORMATION memory;
                wenforce(VirtualQuery(cast(void*)slot, &memory, memory.sizeof),
                    "Cannot query IAT protection");
                // Some linkers place import thunks and their IAT on executable
                // pages. Removing execute access can fault inside this patcher.
                auto executable = memory.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                    PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY);
                wenforce(VirtualProtect(cast(void*)slot, size_t.sizeof,
                    executable ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE,
                    &oldProtection), "Cannot make IAT writable");
                bool replaced = replaceSlot(slot, previous, cast(size_t)hook.replacement);
                DWORD ignored;
                wenforce(VirtualProtect(cast(void*)slot, size_t.sizeof,
                    oldProtection, &ignored), "Cannot restore IAT protection");
                if (replaced) ++changed;
                break;
            }
        }
    }
    return changed;
}

private bool replaceSlot(shared(size_t)* slot, size_t expected, size_t replacement) {
    if (cast(size_t)slot % size_t.sizeof == 0) return cas(slot, expected, replacement);
    // core.atomic.cas requires natural alignment even on x86. Use the CPU's
    // locked instruction explicitly for PE32+ images with DWORD-aligned IATs.
    // A split-cache-line operand may be slow; this runs only during patching.
    bool replaced;
    version (D_InlineAsm_X86_64) {
        asm {
            mov RCX, slot;
            mov RAX, expected;
            mov RDX, replacement;
            lock; cmpxchg [RCX], RDX;
            sete AL;
            mov replaced, AL;
        }
    } else version (D_InlineAsm_X86) {
        asm {
            mov ECX, slot;
            mov EAX, expected;
            mov EDX, replacement;
            lock; cmpxchg [ECX], EDX;
            sete AL;
            mov replaced, AL;
        }
    } else {
        enforce(false, "Unaligned IAT requires x86 inline assembly support");
    }
    return replaced;
}
