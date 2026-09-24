module snakebite.ffi.symbol;


private:


// Resolves already-loaded symbols by linker name. The cache keeps both
// addresses and missing symbols, so a missing template instance is not
// looked up again on every call. Every thread reads the cache without a
// lock (ADR-0006); a symbol is looked up once, on its first use.
public struct Resolver {
    import snakebite.dependencyimage: DependencyImage;
    import snakebite.sharedtable: SharedTable;

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

    version(unittest) private size_t _lookups;

    public void* resolve(in char[] name) {
        if (auto cached = _addresses.find(cast(string) name))
            return *cached;

        version(unittest) ++_lookups;
        auto address = _image is null ? null : _image.resolve(name);
        if (address is null)
            address = symbolAddress(name);
        return *_addresses.insert(name.idup, address);
    }

    // `name`'s address, but only when a genuine, independent native copy
    // answers it: the dependency image, or an already-loaded shared
    // object. Never the running executable's own copy - the tier
    // `symbolAddress` only reaches as its last resort. A caller that must
    // never bind to snakebite's own instantiation of a template a guest
    // program also instantiates (`CallSelection.buildDecision`,
    // ADR-0008's open question) asks here instead of `resolve`.
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
// The executable goes last because snakebite itself instantiates plenty of
// the same templates a guest program calls, `dirEntries` in
// `snakebite.project` among them (ADR-0008, ADR-0009): `--export-dynamic`
// exports that instance's symbol from `bin/sb` too, with whichever closure
// layout the host compiler happened to give its nested functions. A guest
// backend that bound to it would read that closure with its own layout
// instead. Searching every already-loaded library first, before the
// executable, keeps a guest call away from a host-side instantiation
// whenever a genuine native copy - in the image, in druntime, in phobos, in
// a dependency's own C library - already answers the same name.
//
// A caller for whom even that last resort is unsafe - a guest call
// through a template instance, which may have no native copy anywhere but
// the executable's own mismatched-layout one - asks `Resolver.
// resolveIndependent` instead, which stops at `sharedObjectAddress` and
// never reaches here.
private void* symbolAddress(in char[] name) {
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
