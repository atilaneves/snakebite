module snakebite.ffi.symbol;


private:


// Resolves already-loaded symbols by linker name. The cache keeps both
// addresses and missing symbols, so a missing template instance is not
// looked up again on every call. Every thread reads the cache without a
// lock (ADR-0006); a symbol is looked up once, on its first use.
public struct Resolver {
    import snakebite.image.dependency: DependencyImage;
    import snakebite.host.runtimeentry: RuntimeEntry;
    import snakebite.host.sharedtable: SharedTable;

    private const(DependencyImage)* _image;
    // Read without a lock the same way as every other ADR-0006 cache:
    // several guest threads can each resolve a symbol for the first time
    // at once.
    private SharedTable!(string, void*) _addresses;
    // Kept apart from `_addresses`: the same name can have two different
    // cached answers, a full one that accepts the executable's own copy
    // and an independent one that never does (see `resolveIndependent`).
    private SharedTable!(string, void*) _independentAddresses;

    // The owner must outlive this resolver and every address it returns.
    public this(const(DependencyImage)* image) {
        _image = image;
    }

    // The first name that answered each address, so that a stored program can
    // name the code it calls and ask for it again by name.
    private SharedTable!(const(void)*, string) _names;

    version(unittest) private size_t _lookups;

    public void* resolve(in char[] name) {
        if (auto cached = _addresses.find(cast(string) name))
            return *cached;

        version(unittest) ++_lookups;
        auto address = _image is null ? null : _image.resolve(name);
        if (address is null)
            address = symbolAddress(name);
        auto routed = RuntimeEntry.route(address);
        if (routed !is null)
            _names.insert(routed, name.idup);
        return *_addresses.insert(name.idup, routed);
    }

    // The name of the symbol that `address` is in or `distance` bytes after,
    // or null. The names `resolve` answered come first; any other address in a
    // shared object of the process is asked of the loader, the reverse of
    // `sharedObjectAddress`. A name is answered only when `resolve` gives it
    // back as the address of that symbol.
    public string nameOf(const(void)* address, out size_t distance) {
        if (auto found = address in _names)
            return *found;
        version (Posix) {
            import core.sys.posix.dlfcn: Dl_info, dladdr;
            import std.string: fromStringz;

            Dl_info info;
            if (dladdr(address, &info) == 0 || info.dli_sname is null
                    || info.dli_saddr is null || info.dli_saddr > address)
                return null;
            const name = info.dli_sname.fromStringz.idup;
            if (resolve(name) !is info.dli_saddr)
                return null;
            distance = address - info.dli_saddr;
            return name;
        } else
            return null;
    }

    // `name`'s address, but only when a genuine, independent native copy
    // answers it: the dependency image, or an already-loaded shared
    // object. Never the running executable's own copy - the tier
    // `symbolAddress` only reaches as its last resort. Call selection asks
    // here when it needs an independent body, not a designated host test
    // fixture (ADR-0008). Ordinary host templates are private, but that
    // export boundary does not make an executable fixture independent.
    public void* resolveIndependent(in char[] name) {
        if (auto cached = _independentAddresses.find(cast(string) name))
            return *cached;

        auto address = _image is null ? null : _image.resolve(name);
        if (address is null)
            address = sharedObjectAddress(name);
        return *_independentAddresses.insert(name.idup, address);
    }

    // This thread's address of a thread-local symbol. Never cached: the
    // loader answers `dlsym` on a thread-local symbol with the calling
    // thread's own copy, so one thread's answer is wrong for every other.
    public void* resolveThreadLocal(in char[] name) const {
        return threadLocalAddress(_image, name);
    }

    version(unittest)
    public size_t lookups() @safe @nogc nothrow pure const scope {
        return _lookups;
    }
}


// This thread's address of the thread-local symbol `name` of the dependency
// image `image`, or of the process when `image` is null or has no such symbol.
public void* threadLocalAddress(
    const(imported!"snakebite.image.dependency".DependencyImage)* image,
    in char[] name,
) {
    auto address = image is null ? null : image.resolve(name);
    return address is null ? symbolAddress(name) : address;
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
//
// A caller that needs an independent native body asks
// `Resolver.resolveIndependent` instead. It excludes executable fixtures
// even when their names match, and keeps its answers in a separate cache.
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
