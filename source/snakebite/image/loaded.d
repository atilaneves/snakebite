module snakebite.image.loaded;


private:


public struct TestHooks {
    import core.runtime: Runtime;

    private typeof(Runtime.moduleUnitTester) _legacy;
    private typeof(Runtime.extendedModuleUnitTester) _extended;

    public static TestHooks of(
        typeof(Runtime.moduleUnitTester) legacy,
        typeof(Runtime.extendedModuleUnitTester) extended,
    ) {
        return TestHooks(legacy, extended);
    }

    public static TestHooks current() {
        return TestHooks(Runtime.moduleUnitTester, Runtime.extendedModuleUnitTester);
    }

    public void install() const {
        Runtime.moduleUnitTester = _legacy;
        Runtime.extendedModuleUnitTester = _extended;
    }

    // Runtime hooks are function pointers, so they need a shared slot.
    // Each nested run must restore the enclosing run's tracking state.
    public struct Watch {
        private TestHooks _hooks;
        private Watch* _previous;
        public bool escaped;

        public void install(in TestHooks hooks) {
            _hooks = hooks;
            _previous = _watch;
            _watch = &this;
            TestHooks(
                hooks._legacy is null ? null : &watchedLegacy,
                hooks._extended is null ? null : &watchedExtended,
            ).install;
        }

        public void restore() {
            _watch = _previous;
        }
    }

    private static bool watchedLegacy() {
        try
            return _watch._hooks._legacy();
        catch (Throwable throwable) {
            _watch.escaped = true;
            throw throwable;
        }
    }

    private static typeof(Runtime.extendedModuleUnitTester()()) watchedExtended() {
        try
            return _watch._hooks._extended();
        catch (Throwable throwable) {
            _watch.escaped = true;
            throw throwable;
        }
    }
}

private __gshared TestHooks.Watch* _watch;


// A project's dependency image stays loaded until the executable exits.
// This value describes the image; its scope does not limit that lifetime.
public struct DependencyImage {
    private void* _handle;
    private string _path;
    private alias Modules = extern(C) const(ModuleInfo*)* function(size_t*);
    private Modules _modules;
    import snakebite.host.runtimeentry: RuntimeEntry;
    // The image's own function for each function of `RuntimeEntry`, or null.
    // Code in the image calls it and takes its address, so a guest
    // reference must give the same address.
    private void*[RuntimeEntry.symbols.length] _wrappers;
    public TestHooks testHooks;

    // The image exports its function registry under this name. The frontend
    // generator writes the definition and `resolve` looks it up.
    public enum registrySymbol = "snakebite_dependency_image_symbols_v1";
    public enum entryStartupSettings = deferredRegistrySource;

    public string path() @safe @nogc nothrow pure const return scope {
        return _path;
    }

    public const(ModuleInfo*)[] deferredModules() const {
        if (_modules is null)
            return null;
        size_t count;
        const records = _modules(&count);
        return records[0 .. count];
    }

    public void* resolve(in char[] name) const {
        import core.sys.posix.dlfcn: dlerror, dlsym;
        import std.string: toStringz;

        if (_handle is null)
            return null;
        dlerror;
        // const qualifies this description, not the loader's opaque handle.
        const address = dlsym(cast(void*) _handle, name.toStringz);
        if (dlerror is null) {
            foreach (i, function_; RuntimeEntry.druntime)
                if (_wrappers[i] !is null && address == function_)
                    return cast(void*) _wrappers[i];
            return cast(void*) address;
        }

        alias Registry = extern(C) void* function(const(char)[]);
        dlerror;
        const registry = cast(Registry) dlsym(cast(void*) _handle,
            registrySymbol.toStringz);
        if (dlerror !is null || registry is null)
            return null;
        return registry(name);
    }
}


// Loads an image that is already built, instead of having `prepareImage`
// (in `snakebite.image.dependency`) make one.
public DependencyImage loadImage(in string path) {
    import snakebite.host.runlock: guestRunLock;

    // Hooks belong to the process, and a guest run installs and watches them
    // under this lock. A load must not capture or restore a run's hooks.
    guestRunLock.lock;
    scope(exit) guestRunLock.unlock;
    return loadImageLocked(path);
}


private DependencyImage loadImageLocked(in string path) {
    import core.sys.posix.dlfcn:
        dlerror, dlopen, dlsym, RTLD_LAZY, RTLD_NODELETE;
    import std.string: fromStringz, toStringz;
    import std.conv: text;
    import snakebite.failure.report: SnakebiteException;
    import snakebite.host.runtimeentry: RuntimeEntry;

    const savedHooks = TestHooks.current;
    scope(exit) savedHooks.install;
    TestHooks.init.install;

    DependencyImage image;
    image._path = path;
    // A plain `dlopen`, not `Runtime.loadLibrary`. Both register the
    // image with druntime on this thread (`_d_dso_registry` runs from
    // the image's own constructor): the GC scans its TLS, its module and
    // TLS constructors run, and the record lives until the loader's own
    // teardown at process exit finds and frees it. `Runtime.loadLibrary`
    // additionally marks the record as an *explicit* load this thread
    // must `dlclose` itself, and every thread this one starts inherits
    // that duty (`core.thread`'s `pinLoadedLibraries` and druntime's
    // `cleanupLoadedLibraries`). A guest thread still alive at process
    // exit then reads the record after the loader freed it - a dependency
    // image's finalizer runs before druntime's and libphobos's - and
    // segfaults inside `dlclose`. Releasing that explicit reference is no
    // answer either: druntime drops the whole record with it, so the
    // GC stops scanning the image's TLS and the loader warns at exit.
    // `RTLD_NODELETE` keeps the one loader reference taken here for the
    // whole process, so symbols stay valid after this call returns and
    // nothing ever closes the image.
    image._handle = dlopen(path.toStringz, RTLD_LAZY | RTLD_NODELETE);
    if (image._handle is null)
        throw new SnakebiteException(text("Cannot load dependency image ",
            path, ": ", dlerror.fromStringz));
    image._modules = cast(DependencyImage.Modules) dlsym(image._handle,
        "snakebite_dependency_image_modules_v1");
    if (image._modules !is null) {
        foreach (i, symbol; RuntimeEntry.symbols)
            image._wrappers[i] = dlsym(
                image._handle, text("__wrap_", symbol).toStringz);
        alias Bind = extern(C) void function(
            const(void)*, const(void)*, const(void)*, const(void)*);
        const bind = cast(Bind) dlsym(image._handle,
            "snakebite_dependency_entry_bind_v1");
        const entries = RuntimeEntry.entries;
        const druntime = RuntimeEntry.druntime;
        bind(entries[0], entries[1], druntime[0], druntime[1]);
    }
    // Shared constructors run only on the first load. Retain their hooks
    // even if later preparation fails, since the loaded image stays open.
    if (auto hooks = image._handle in _imageTestHooks)
        image.testHooks = *hooks;
    else {
        image.testHooks = TestHooks.current;
        _imageTestHooks[image._handle] = image.testHooks;
    }
    return image;
}


// An empty module range preserves actual image GC/TLS registration without
// starting a full-D static dependency before its C entry requests startup.
private enum deferredRegistrySource = q{
    private struct SnakebiteDeferredDSO {
        size_t version_;
        void** slot;
        const(ModuleInfo*)* begin;
        const(ModuleInfo*)* end;
    }
    private __gshared const(ModuleInfo*)[] snakebiteDeferredModules;
    extern(C) void __real__d_dso_registry(void*);
    extern(C) void __wrap__d_dso_registry(SnakebiteDeferredDSO* data) {
        auto ranges = *data;
        if (*data.slot is null) {
            snakebiteDeferredModules = data.begin[0 .. data.end - data.begin];
            ranges.begin = ranges.end = null;
        }
        __real__d_dso_registry(&ranges);
    }
    export extern(C) const(ModuleInfo*)* snakebite_dependency_image_modules_v1(size_t* count) {
        *count = snakebiteDeferredModules.length;
        return snakebiteDeferredModules.ptr;
    }
    alias SnakebiteRuntimePhase = extern(C) int function();
    private __gshared SnakebiteRuntimePhase snakebiteEntryInit;
    private __gshared SnakebiteRuntimePhase snakebiteEntryTerm;
    private __gshared void* snakebiteHostInit;
    private __gshared void* snakebiteHostTerm;
    extern(C) int __real_rt_init();
    extern(C) int __real_rt_term();
    export extern(C) void snakebite_dependency_entry_bind_v1(
        SnakebiteRuntimePhase initialize, SnakebiteRuntimePhase terminate,
        void* hostInitialize, void* hostTerminate,
    ) {
        snakebiteEntryInit = initialize;
        snakebiteEntryTerm = terminate;
        snakebiteHostInit = hostInitialize;
        snakebiteHostTerm = hostTerminate;
    }
    // A dependency that defines one of these functions keeps its definition.
    export extern(C) int __wrap_rt_init() {
        return cast(void*) &__real_rt_init == snakebiteHostInit
            ? snakebiteEntryInit() : __real_rt_init();
    }
    export extern(C) int __wrap_rt_term() {
        return cast(void*) &__real_rt_term == snakebiteHostTerm
            ? snakebiteEntryTerm() : __real_rt_term();
    }
    pragma(mangle, "__wrap_" ~ imported!"core.runtime".Runtime.initialize.mangleof)
    export bool snakebiteRuntimeInitialize() {
        return __wrap_rt_init() != 0;
    }
    pragma(mangle, "__wrap_" ~ imported!"core.runtime".Runtime.terminate.mangleof)
    export bool snakebiteRuntimeTerminate() {
        return __wrap_rt_term() != 0;
    }
};


private __gshared TestHooks[void*] _imageTestHooks;
