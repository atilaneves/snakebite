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


// The address of an already-loaded symbol, by its linker name.
//
// Nothing is loaded to find it: the search covers the running process and
// every library it already links, which is where druntime and the C runtime
// both live. A guest program calling `malloc` therefore reaches the very
// same `malloc` the host itself calls, so memory a guest allocates is
// ordinary process memory, not a separate emulated heap.
//
// `null` means the symbol is not there to call.
private void* symbolAddress(in char[] name) {
    version (Posix) {
        import core.sys.posix.dlfcn: dlerror, dlsym;
        import std.string: toStringz;

        version (linux)
            import core.sys.linux.dlfcn: RTLD_DEFAULT;
        else
            import core.sys.posix.dlfcn: RTLD_DEFAULT;

        // A symbol can legitimately live at a null address, so `dlsym`
        // returning null is not itself the failure. `dlerror` is what
        // distinguishes the two, and it reports the *previous* call's
        // error, so it is cleared first.
        dlerror;
        auto address = dlsym(RTLD_DEFAULT, name.toStringz);
        return dlerror is null ? address : null;
    } else
        return null;
}
