module snakebite.ffi.symbol;


private:


// Resolves already-loaded symbols by linker name: in the dependency image
// first, then in the process. It keeps no answer: the name of a symbol keeps
// it (`CallPlanStore.addressOf`), so a symbol is looked up once, on its first
// use, also when it is missing.
public struct Resolver {
    import snakebite.image.dependency: DependencyImage;
    import snakebite.host.runtimeentry: RuntimeEntry;

    private const(DependencyImage)* _image;

    // The owner must outlive this resolver and every address it returns.
    public this(const(DependencyImage)* image) {
        _image = image;
    }

    version(unittest) private size_t _lookups;

    public void* resolve(in char[] name) {
        version(unittest) ++_lookups;
        auto address = _image is null ? null : _image.resolve(name);
        if (address is null)
            address = symbolAddress(name);
        return RuntimeEntry.route(address);
    }

    // This thread's address of a thread-local symbol. Never cached: the
    // loader answers `dlsym` on a thread-local symbol with the calling
    // thread's own copy, so one thread's answer is wrong for every other.
    public void* resolveThreadLocal(in char[] name) const {
        auto address = _image is null ? null : _image.resolve(name);
        return address is null ? symbolAddress(name) : address;
    }

    version(unittest)
    public size_t lookups() @safe @nogc nothrow pure const scope {
        return _lookups;
    }
}


// The address of an already-loaded symbol, by its linker name, searched
// after the dependency image (ADR-0007) has already had its turn and come
// up empty. Covers every shared object the process already links - which
// is where druntime, the C runtime, and a project's own C/C++ dependencies
// all live. A guest program calling `malloc` therefore reaches the very
// same `malloc` the host itself calls, so memory a guest allocates is
// ordinary process memory, not a separate emulated heap.
//
// `null` means no already-loaded shared object answers this name; the
// executable itself may still have its own copy, which only
// `symbolAddress` below, never this, will find.
private void* sharedObjectAddress(in char[] name) {
    version (Posix) {
        import core.sys.posix.dlfcn: dlerror, dlsym;
        import std.string: toStringz;

        version (linux)
            import core.sys.linux.dlfcn: RTLD_NEXT;
        else
            import core.sys.posix.dlfcn: RTLD_NEXT;

        const nameZ = name.toStringz;

        // A symbol can legitimately live at a null address, so `dlsym`
        // returning null is not itself the failure. `dlerror` is what
        // distinguishes the two, and it reports the *previous* call's
        // error, so it is cleared first.
        //
        // `RTLD_NEXT` searches the objects loaded *after* the caller's own
        // object in the process's search order. `sharedObjectAddress` is
        // compiled straight into the executable (`bin/sb`, `bin/ut`,
        // `bin/at`), never into a shared object, so "after the caller"
        // here means every already-loaded shared object and nothing in
        // the executable itself.
        dlerror;
        auto address = dlsym(RTLD_NEXT, nameZ);
        return dlerror is null ? address : null;
    } else
        return null;
}

// `sharedObjectAddress`'s answer, or, as a last resort, the running
// executable's own copy of `name`. `null` means the symbol is not there to
// call.
//
// The executable fallback serves only designated test fixtures and the
// process-settings symbol `rt_options` (ADR-0008). Ordinary host templates
// remain private: their closures need not match a guest backend's layout.
// Libraries still go first so a fixture cannot replace an independent
// library definition with the same name.
private void* symbolAddress(in char[] name) {
    import snakebite.druntime.atomicwrapper:
        atomicAddSymbol, snakebite_constructor_atomic_add_int;

    // The host wrapper that a call to `core.atomic.atomicOp!"+="` runs.
    if (name == atomicAddSymbol)
        return cast(void*) &snakebite_constructor_atomic_add_int;
    if (auto address = sharedObjectAddress(name))
        return address;

    version (Posix) {
        import core.sys.posix.dlfcn: dlerror, dlopen, dlsym,
            RTLD_LAZY, RTLD_NOLOAD;
        import std.string: toStringz;

        const nameZ = name.toStringz;

        // Last resort: the executable itself. `bin/ut` and `bin/at` build
        // their native fixtures straight into the test binary, with no
        // `.so` of their own, so a symbol only found here is still a
        // legitimate host answer - just never preferred over a real
        // library's own copy of the same name.
        dlerror;
        auto executable = dlopen(null, RTLD_LAZY | RTLD_NOLOAD);
        if (executable is null)
            return null;
        dlerror;
        auto address = dlsym(executable, nameZ);
        return dlerror is null ? address : null;
    } else
        return null;
}
