module snakebite.teststartup;


private:


// The registration slot must belong to an ELF image: druntime uses its
// address to find the image's segments. BetterC prevents the compiler from
// registering a second, unrelated ModuleInfo for this small adapter.
public imported!"snakebite.dependencyimage".DependencyImage prepareTestStartup(
    in string directory,
    in string[] moduleNames,
) {
    import snakebite.dependencyimage: prepareImage, defaultCompiler;
    import std.path: buildPath;
    import std.array: join;

    const source = registrySource ~ "\n// Modules: " ~ moduleNames.join(", ") ~ "\n";
    return prepareImage(source, directory.buildPath(".snakebite", "startup"),
        defaultCompiler, null, null, null, ["-betterC"], null, ["-betterC"]);
}


private enum registrySource = q{
    module snakebite_test_registry;
    private __gshared void* _slot;
    private struct CompilerDSOData {
        size_t version_;
        void** slot;
        const(void*)* begin;
        const(void*)* end;
    }
    private alias Registry = extern(C) void function(void*);
    private __gshared Registry _unregister;
    export extern(C) void snakebite_register_tests(
        Registry registry, const(void*)* modules, size_t length,
    ) {
        auto data = CompilerDSOData(1, &_slot, modules, modules + length);
        registry(&data);
        _unregister = registry;
    }
    // The pinned image outlives guest workers. Its ELF destructor is the
    // same point at which compiler-generated registrations are removed.
    pragma(crt_destructor) extern(C) void unregisterTests() {
        if (_slot !is null) {
            auto data = CompilerDSOData(1, &_slot, null, null);
            _unregister(&data);
        }
    }
};


public int runTestsAndMain(
    imported!"snakebite.backends.backend".Backend backend,
    imported!"snakebite.backends.backend".Program program,
    in string[] arguments,
) {
    import snakebite.backends.backend: TestHooks, runMain, runModuleConstructors;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.string: toStringz;

    const savedHooks = TestHooks.current;
    auto savedArgs = _runtimeArgs; // Restore mutable host argument storage.
    auto savedCArgs = _runtimeCArgs; // C argv contains mutable pointers.
    const savedMain = _main;
    scope(exit) {
        savedHooks.install;
        _runtimeArgs = savedArgs;
        _runtimeCArgs = savedCArgs;
        _main = savedMain;
    }
    program.testHooks.install;
    _runtimeArgs = arguments.length ? arguments.dup : [program.name];
    auto cArguments = _runtimeArgs.map!(arg => cast(char*) arg.toStringz).array ~ null;
    _runtimeCArgs.argc = cast(int) _runtimeArgs.length;
    _runtimeCArgs.argv = cArguments.ptr;

    if (runModuleConstructors(backend, program.moduleConstructors))
        return 1;

    auto modules = activateModules(backend, program);
    scope(exit) foreach (module_; modules)
        *testEntry(module_) = null;

    _main = (string[] args) => runMain(backend, program, args);
    // druntime owns runner selection, summaries, failure status and the
    // decision to call main. Its nested init/term pair is reference counted.
    return _d_run_main(_runtimeCArgs.argc, cArguments.ptr, &callMain);
}


// Guest worker threads inherit the image's druntime registration. Keep it
// alive with the pinned image, even if workers outlive this call. Inactive
// entries have a null unittest pointer so later runs cannot repeat them.
private __gshared ModuleInfo*[][string] _registeredModules;


private ModuleInfo*[] activateModules(
    imported!"snakebite.backends.backend".Backend backend,
    imported!"snakebite.backends.backend".Program program,
) {
    auto modules = testModules(backend, program);
    const path = program.testStartupImage.path;
    if (auto existing = path in _registeredModules) {
        assert(existing.length == modules.length);
        foreach (i, module_; *existing)
            *testEntry(module_) = *testEntry(modules[i]);
        return *existing;
    }

    _registeredModules[path] = modules;
    alias Registry = extern(C) void function(void*);
    alias Register = extern(C) void function(Registry, const(void*)*, size_t);
    const register = cast(Register) program.testStartupImage.resolve("snakebite_register_tests");
    assert(register !is null);
    if (modules.length)
        register(&_d_dso_registry, cast(const(void*)*) modules.ptr, modules.length);
    return modules;
}


private int delegate(string[]) _main;


private extern(C) int callMain(char[][] arguments) {
    return _main(cast(string[]) arguments);
}


// _d_run_main leaves its arguments pointing into its stack on return.
// Preserve the enclosing host's arguments when entering guest startup.
pragma(mangle, "_D2rt6dmain27_d_argsAAya")
private extern __gshared string[] _runtimeArgs;
pragma(mangle, "_D2rt6dmain26_cArgsSQsQr5CArgs")
private extern __gshared imported!"core.runtime".CArgs _runtimeCArgs;
private alias MainFunction = extern(C) int function(char[][]);
private extern(C) int _d_run_main(
    int argc, char** argv, MainFunction main,
);
private extern(C) void _d_dso_registry(void* data);


private ModuleInfo*[] testModules(
    imported!"snakebite.backends.backend".Backend backend,
    imported!"snakebite.backends.backend".Program program,
) {
    import snakebite.frontend.dmd.functions: findUnittests;
    import snakebite.ffi.callback: CallbackBridge;
    import std.string: fromStringz;

    auto bridge = new CallbackBridge(&callTests, null);
    ModuleInfo*[] modules;
    foreach (module_; program.rootModules) {
        auto tests = findUnittests(module_); // DMD declarations remain mutable.
        const(void)* entry;
        if (tests.length) {
            auto suite = new ModuleTests(backend, tests.dup);
            bridge.register(suite, tests[0]);
            entry = bridge.entryOf(suite);
        }
        const name = module_.toPrettyChars.fromStringz;
        // ModuleInfo has a variable-sized tail. These are the same flag,
        // function-pointer and NUL-terminated name fields emitted by D.
        auto storage = new void[ModuleInfo.sizeof + (void*).sizeof + name.length + 1];
        auto info = cast(ModuleInfo*) storage.ptr;
        info._flags = MIstandalone | MIunitTest | MIname;
        info._index = 0;
        auto callback = testEntry(info);
        *callback = entry;
        auto text = cast(char*) (callback + 1);
        text[0 .. name.length] = name;
        text[name.length] = '\0';
        modules ~= info;
    }
    return modules;
}


private const(void)** testEntry(ModuleInfo* module_) @system pure nothrow @nogc {
    return cast(const(void)**) (cast(ubyte*) module_ + ModuleInfo.sizeof);
}


private struct ModuleTests {
    import snakebite.backends.backend: Backend;
    import dmd.func: FuncDeclaration;

    Backend backend;
    FuncDeclaration[] functions;
}


private extern(C) void callTests(
    void* owner, imported!"snakebite.ffi.callback".CallbackCall* call,
) {
    auto suite = cast(ModuleTests*) call.function_;
    // A compiler emits one __modtest per module. A failure leaves this
    // callback; druntime catches it and continues with the next module.
    foreach (function_; suite.functions)
        suite.backend.call(function_, null, []);
}
