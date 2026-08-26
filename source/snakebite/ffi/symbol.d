module snakebite.ffi.symbol;


private:


// The address of an already-loaded symbol, by its linker name.
//
// Nothing is loaded to find it: the search covers the running process and
// every library it already links, which is where druntime and the C runtime
// both live. A guest program calling `malloc` therefore reaches the very
// same `malloc` the host itself calls, so memory a guest allocates is
// ordinary process memory, not a separate emulated heap.
//
// `null` means the symbol is not there to call.
public void* symbolAddress(in char* name) {
    version (Posix) {
        import core.sys.posix.dlfcn: dlerror, dlsym;

        version (linux)
            import core.sys.linux.dlfcn: RTLD_DEFAULT;
        else
            import core.sys.posix.dlfcn: RTLD_DEFAULT;

        // A symbol can legitimately live at a null address, so `dlsym`
        // returning null is not itself the failure. `dlerror` is what
        // distinguishes the two, and it reports the *previous* call's
        // error, so it is cleared first.
        dlerror;
        auto address = dlsym(RTLD_DEFAULT, name);
        return dlerror is null ? address : null;
    } else
        return null;
}
