module snakebite.backends.guestmodules;


private:


// What compiled D does with the modules of a program, done for the root
// modules of a guest program: druntime owns the phases. Each root module gets
// a `ModuleInfo` record whose constructor, destructor, thread-local
// constructor and thread-local destructor fields are native entries that run
// the guest functions on the active backend, and whose imported-module field
// lists the other root modules it imports. The record array is registered
// with druntime as an image of its own (`_d_dso_registry`), as the start-up
// code of a compiled image registers it. druntime then orders the modules by
// import, refuses a cycle, runs the shared constructors and then the
// thread-local ones, runs the thread-local constructors and destructors on
// every thread that starts or ends, and runs the destructors in reverse.
//
// A process that runs one guest program and then ends (`bin/sb`) leaves the
// registration to its own `rt_term`, which runs the phases in the order
// druntime defines, and, for a program that calls `exit`, to a handler that
// `exit` runs first. A caller that runs many programs in one process (`run`,
// the tests) ends the phases itself with `finish`.
public struct GuestModules {
    import core.atomic: cas;
    import core.time: Duration;
    import snakebite.backends.backend: Backend, Program;

    // Whether the records also name the unit tests of each module, for the
    // runner that druntime starts.
    public enum Tests {
        no,
        yes,
    }

    // Whether the process ends with the program.
    public enum Ends {
        program,
        process,
    }

    private Run* _run;
    private Ends _ends;
    private bool _failed;
    // The time to build the records and their entries, and the time druntime
    // took to order and run the constructors.
    public Duration preparation;
    public Duration constructors;

    // Registers the root modules of `program`. A startup that fails ends
    // the way druntime's `rt_init` ends: the throwable is printed and
    // `failed` is true. A program with no constructor, no destructor and,
    // for `Tests.no`, no unit test, needs no registration.
    public static GuestModules start(
        Backend backend,
        Program program,
        in Tests tests,
        in Ends ends,
    ) {
        import core.stdc.stdlib: atexit;
        import core.time: MonoTime;

        GuestModules modules;
        modules._ends = ends;
        const preparing = MonoTime.currTime;
        auto run = newRun(backend, program, tests);
        if (run is null)
            return modules;

        modules._run = run;
        modules.preparation = MonoTime.currTime - preparing;
        const registering = MonoTime.currTime;
        try {
            run.imagePath = registryImage(program);
            run.image = Image.open(run.imagePath);
            if (ends == Ends.process) {
                run.exit = newExitRecord(run.image.slot);
                if (cas(&_endHandlerRegistered, false, true))
                    atexit(&endAtExit);
            }
            run.image.register(run.records);
        } catch (Throwable throwable) {
            atomicStore(run.state, Run.State.failed);
            _d_print_throwable(throwable);
            modules._failed = true;
        }
        modules.constructors = MonoTime.currTime - registering;
        return modules;
    }

    public bool failed() const {
        return _failed;
    }

    // Ends the program. When the process ends with it, `rt_term` runs the
    // destructors and `exit` no longer has to. Otherwise this does what
    // `rt_term` does for the thread that ran the program: that thread's
    // thread-local destructors, then the shared ones. druntime runs them
    // through a second registration whose records have only the destructor
    // fields: the first registration stays, because a thread that the program
    // started and left running still holds it. Returns 1 when a destructor
    // threw, as `rt_term` then makes the program fail.
    public int finish() {
        if (_run is null || _failed)
            return 0;

        auto run = _run;
        if (_ends == Ends.process) {
            atomicStore(run.exit.returned, true);
            return 0;
        }

        int status;
        if (run.closingRecords.length) {
            atomicStore(run.state, Run.State.closing);
            try {
                auto closing = Image.open(run.imagePath);
                scope(exit) closing.close;
                closing.register(run.closingRecords);
                closing.unregister;
            } catch (Throwable throwable) {
                _d_print_throwable(throwable);
                status = 1;
            }
        }
        atomicStore(run.state, Run.State.finished);
        return status;
    }
}


// The image that provides the registration slot of a program, prepared with
// the other images of a project.
public imported!"snakebite.dependencyimage".DependencyImage prepareRegistryImage(
    in string stateDirectory,
) {
    import snakebite.dependencyimage: prepareImage, defaultCompiler;
    import std.path: buildPath;

    return prepareImage(registrySource, stateDirectory.buildPath("startup"),
        defaultCompiler, null, null, null, ["-betterC"], null, ["-betterC"]);
}


private import core.atomic: atomicLoad, atomicStore;
private import snakebite.backends.backend: Backend, Program;
private import snakebite.ffi.callback: CallbackBridge, CallbackCall;


// The registration slot must belong to an ELF image: druntime uses its
// address to find the image's segments and keys the image by its loader
// handle, so each registration loads a copy of this image of its own.
// BetterC prevents the compiler from registering a second, unrelated
// ModuleInfo for this small adapter.
private enum registrySource = q{
    module snakebite_test_registry;
    private __gshared void* _slot;
    export extern(C) void** snakebite_registry_slot() {
        return &_slot;
    }
};


// What `endAtExit` needs, in memory that the GC does not own: after a normal
// end druntime has freed the GC heap when `exit` runs the handler.
private struct ExitRecord {
    // Whether the program ended with `main`, so `rt_term` runs its phases.
    shared bool returned;
    void** slot;
    ExitRecord* next;
}


private ExitRecord* newExitRecord(void** slot) {
    import core.stdc.stdlib: malloc;

    auto record = cast(ExitRecord*) malloc(ExitRecord.sizeof);
    record.returned = false;
    record.slot = slot;
    record.next = _ending;
    _ending = record;
    return record;
}


// `exit` runs this before the loader finalizes the images, with the runtime
// initialised: unregistering the records makes druntime run the destructors
// of the calling thread and then the shared ones.
private extern(C) void endAtExit() {
    for (auto record = _ending; record !is null; record = record.next) {
        if (atomicLoad(record.returned) || *record.slot is null)
            continue;

        try
            Image.unregister(record.slot);
        catch (Throwable throwable)
            _d_print_throwable(throwable);
    }
}


private __gshared ExitRecord* _ending;
private shared bool _endHandlerRegistered;


private extern(C) void _d_dso_registry(void* data);
private extern(C) void _d_print_throwable(Throwable);


// What one registration holds and what the entries of its records reach.
private struct Run {
    // `running` until the program ends. `closing` while `finish` runs the
    // destructors of the program. `finished` after, when an entry that a
    // thread still alive reaches does nothing. `failed` when startup threw:
    // no destructor runs for a program that did not start.
    enum State : int {
        running,
        closing,
        finished,
        failed,
    }

    Backend backend;
    shared State state;
    string imagePath;
    ModuleInfo*[] records;
    ModuleInfo*[] closingRecords;
    Image image;
    CallbackBridge* bridge;
    ExitRecord* exit;
}


private struct Phase {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;

    enum Kind {
        constructor,
        destructor,
        unitTests,
    }

    Run* run;
    Kind kind;
    // The destructors that `finish` runs, not the ones of a program that
    // ends with its process.
    bool closing;
    FuncDeclaration[] functions;
    // dmd's glue layer increments the gate of each destructor of a template
    // instance while it runs the constructors of the module: the destructor
    // body returns early unless it brings the gate back to zero.
    VarDeclaration[] gates;
}


private extern(C) void callPhase(void* owner, CallbackCall* call) {
    execute(cast(Phase*) call.function_);
}


private void execute(Phase* phase) {
    import core.atomic: atomicOp;

    auto run = phase.run;
    const state = atomicLoad(run.state);
    final switch (phase.kind) with (Phase.Kind) {
        case constructor:
            if (state != Run.State.running)
                return;

            foreach (gate; phase.gates) {
                auto storage = run.backend.staticStorage(gate);
                if (storage.length)
                    atomicOp!"+="(*cast(shared int*) storage.ptr, 1);
            }
            break;
        case destructor:
            const expected = phase.closing
                ? Run.State.closing
                : Run.State.running;
            if (state != expected)
                return;
            break;
        case unitTests:
            break;
    }

    foreach (function_; phase.functions)
        run.backend.call(function_, null, []);
}


// The registration for `program`, or null when none is needed.
private Run* newRun(
    Backend backend,
    Program program,
    in GuestModules.Tests tests,
) {
    import core.memory: GC;
    import snakebite.frontend.dmd.functions: findModuleFunctions;

    ModuleSpec[] specs;
    bool needed = tests == GuestModules.Tests.yes
        && program.rootModules.length != 0;
    foreach (module_; program.rootModules) {
        auto spec = ModuleSpec(module_, findModuleFunctions(module_));
        needed = needed || spec.hasFunctions;
        specs ~= spec;
    }

    if (!needed)
        return null;

    auto run = new Run;
    // The registered records must outlive every thread that inherits them.
    GC.addRoot(cast(void*) run);
    run.backend = backend;
    run.bridge = new CallbackBridge(&callPhase, cast(void*) run);
    run.records = recordsOf(run, specs, tests, false);
    foreach (spec; specs)
        if (spec.hasDestructors) {
            run.closingRecords = recordsOf(
                run, specs, GuestModules.Tests.no, true);
            break;
        }
    return run;
}


private struct ModuleSpec {
    import dmd.dmodule: Module;
    import snakebite.frontend.dmd.functions: ModuleFunctions;

    Module module_;
    ModuleFunctions functions;

    bool hasFunctions() const {
        return functions.independentConstructors.length
            || functions.sharedConstructors.length
            || functions.threadConstructors.length
            || hasDestructors;
    }

    bool hasDestructors() const {
        return functions.sharedDestructors.length
            || functions.threadDestructors.length;
    }
}


// One record for each module. The records of a closing registration have
// the destructor fields only.
private ModuleInfo*[] recordsOf(
    Run* run,
    ModuleSpec[] specs,
    in GuestModules.Tests tests,
    in bool closing,
) {
    import std.string: fromStringz;
    import snakebite.frontend.dmd.functions: findUnittests;

    auto records = new ModuleInfo*[specs.length];
    auto importSlots = new ModuleInfo**[specs.length];
    const imports = importsOf(specs);
    foreach (i, spec; specs) {
        auto functions = spec.functions;
        Fields fields;
        fields.name = spec.module_.toPrettyChars.fromStringz.idup;
        // druntime orders no module that has nothing to construct or
        // destruct, and no import of one: dmd marks it the same way.
        fields.standalone = !spec.module_.needmoduleinfo;
        fields.importCount = imports[i].length;
        if (!closing) {
            fields.independentConstructor = run.entryOf(
                Phase.Kind.constructor,
                false,
                functions.independentConstructors,
            );
            fields.constructor = run.entryOf(
                Phase.Kind.constructor,
                false,
                functions.sharedConstructors,
                gatesOf(functions.sharedDestructors),
                functions.sharedDestructors,
            );
            fields.threadConstructor = run.entryOf(
                Phase.Kind.constructor,
                false,
                functions.threadConstructors,
                gatesOf(functions.threadDestructors),
                functions.threadDestructors,
            );
        }
        fields.destructor = run.entryOf(
            Phase.Kind.destructor,
            closing,
            reversed(functions.sharedDestructors),
        );
        fields.threadDestructor = run.entryOf(
            Phase.Kind.destructor,
            closing,
            reversed(functions.threadDestructors),
        );
        if (tests == GuestModules.Tests.yes)
            fields.unitTests = run.entryOf(
                Phase.Kind.unitTests, false, findUnittests(spec.module_));

        records[i] = newRecord(fields, importSlots[i]);
    }

    foreach (i, slots; importSlots)
        foreach (j, index; imports[i])
            slots[j] = records[index];
    return records;
}


// For each module, the positions in `specs` of the modules it imports that
// have a record. dmd's glue layer lists only imported modules that need a
// `ModuleInfo`, and the root modules are all the modules that have one here.
private size_t[][] importsOf(ModuleSpec[] specs) {
    import dmd.dmodule: Module;

    size_t[Module] indexOf;
    foreach (i, spec; specs)
        indexOf[spec.module_] = i;

    auto imports = new size_t[][specs.length];
    foreach (i, spec; specs) {
        bool[size_t] seen;
        foreach (imported; spec.module_.aimports) {
            if (!imported.needmoduleinfo || imported is spec.module_)
                continue;

            if (auto index = imported in indexOf)
                if (*index !in seen) {
                    seen[*index] = true;
                    imports[i] ~= *index;
                }
        }
    }
    return imports;
}


private auto gatesOf(imported!"dmd.func".FuncDeclaration[] destructors) {
    import dmd.declaration: VarDeclaration;

    VarDeclaration[] gates;
    foreach (destructor; destructors)
        if (auto gate = destructor.isStaticDtorDeclaration.vgate)
            gates ~= gate;
    return gates;
}


private auto reversed(imported!"dmd.func".FuncDeclaration[] functions) {
    import std.algorithm.mutation: reverse;

    return functions.dup.reverse;
}


// The native entry that runs `functions` as one phase of a module, or null
// when the phase has nothing to run. `signature` gives the entry its type
// when only gates make the phase.
private const(void)* entryOf(
    Run* run,
    in Phase.Kind kind,
    in bool closing,
    imported!"dmd.func".FuncDeclaration[] functions,
    imported!"dmd.declaration".VarDeclaration[] gates = null,
    imported!"dmd.func".FuncDeclaration[] signatures = null,
) {
    if (functions.length == 0 && gates.length == 0)
        return null;

    auto phase = new Phase(run, kind, closing, functions, gates);
    run.bridge.register(
        phase,
        functions.length ? functions[0] : signatures[0],
    );
    return run.bridge.entryOf(phase);
}


// The fields of one `ModuleInfo` record. The entries are the `void function()`
// pointers of the compiler's own records.
private struct Fields {
    string name;
    bool standalone;
    size_t importCount;
    const(void)* independentConstructor;
    const(void)* constructor;
    const(void)* threadConstructor;
    const(void)* destructor;
    const(void)* threadDestructor;
    const(void)* unitTests;
}


// A record in the layout `ModuleInfo` reads: the flags and the index, then the
// fields that the flags name in a fixed order, the imported modules with their
// count, and the name. `importSlots` is where the imported records go once
// all records exist.
private ModuleInfo* newRecord(in Fields fields, out ModuleInfo** importSlots) {
    import core.stdc.string: memcpy;

    uint flags = MIname;
    if (fields.standalone)
        flags |= MIstandalone;
    if (fields.importCount)
        flags |= MIimportedModules;
    const(void)*[6] entries;
    size_t count;
    void add(in uint flag, in const(void)* entry) {
        if (entry is null)
            return;

        flags |= flag;
        entries[count++] = entry;
    }
    add(MItlsctor, fields.threadConstructor);
    add(MItlsdtor, fields.threadDestructor);
    add(MIctor, fields.constructor);
    add(MIdtor, fields.destructor);
    add(MIictor, fields.independentConstructor);
    add(MIunitTest, fields.unitTests);

    const importBytes = fields.importCount
        ? (1 + fields.importCount) * (void*).sizeof : 0;
    auto storage = new void[
        ModuleInfo.sizeof + count * (void*).sizeof + importBytes
            + fields.name.length + 1];
    auto record = cast(ModuleInfo*) storage.ptr;
    record._flags = flags;
    record._index = 0;
    auto place = cast(ubyte*) storage.ptr + ModuleInfo.sizeof;
    foreach (entry; entries[0 .. count]) {
        *cast(const(void)**) place = entry;
        place += (void*).sizeof;
    }
    if (fields.importCount) {
        *cast(size_t*) place = fields.importCount;
        importSlots = cast(ModuleInfo**) (place + size_t.sizeof);
        place += importBytes;
    }
    memcpy(place, fields.name.ptr, fields.name.length);
    place[fields.name.length] = 0;
    return record;
}


// What druntime keeps for a registered image: the address of the slot that
// belongs to an ELF image of its own, and the loader handle of that image.
private struct Image {
    import core.sys.posix.dlfcn: dlclose, dlerror, dlopen, dlsym, RTLD_LOCAL,
        RTLD_NOW;

    private struct CompilerDSOData {
        size_t version_;
        void** slot;
        const(ModuleInfo*)* begin;
        const(ModuleInfo*)* end;
    }

    private void* _handle;
    private void** _slot;

    // A copy of `source` at a path of its own, because druntime keys an image
    // by its loader handle and the loader returns one handle for one file.
    // The copies go when the process ends, not before: a path that a new
    // copy reuses can name the same file to the loader.
    public static Image open(in string source) {
        import core.atomic: atomicOp, cas;
        import core.stdc.stdlib: atexit;
        import core.sys.posix.unistd: getpid;
        import std.conv: text;
        import std.file: copy, tempDir;
        import std.path: buildPath;
        import std.string: fromStringz, toStringz;

        const prefix = tempDir.buildPath(
            text("snakebite-registry-", getpid, "-"));
        const path = text(prefix, atomicOp!"+="(_copies, 1), ".so");
        source.copy(path);
        if (cas(&_cleanupRegistered, false, true)) {
            if (prefix.length >= _copyPrefix.length)
                assert(0, "the copy path fits the cleanup buffer");

            _copyPrefix[0 .. prefix.length] = prefix;
            _copyPrefix[prefix.length] = '\0';
            atexit(&removeCopies);
        }

        Image image;
        image._handle = dlopen(path.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (image._handle is null)
            throw new Exception(text(
                "cannot load the registry image ", path, ": ",
                dlerror.fromStringz));

        alias Slot = extern(C) void** function();
        auto slot = cast(Slot) dlsym(image._handle, "snakebite_registry_slot");
        if (slot is null)
            assert(0, "the registry image exports its slot");

        image._slot = slot();
        return image;
    }

    public void register(ModuleInfo*[] records) {
        auto data = CompilerDSOData(
            1, _slot, records.ptr, records.ptr + records.length);
        _d_dso_registry(&data);
    }

    public void unregister() {
        unregister(_slot);
    }

    public static void unregister(void** slot) {
        auto data = CompilerDSOData(1, slot, null, null);
        _d_dso_registry(&data);
    }

    public void** slot() {
        return _slot;
    }

    public void close() {
        dlclose(_handle);
    }
}


private shared size_t _copies;
private shared bool _cleanupRegistered;


// The runtime is gone when this runs, so it uses no GC memory.
private extern(C) void removeCopies() @nogc nothrow {
    import core.stdc.stdio: snprintf;
    import core.sys.posix.unistd: unlink;

    char[4200] path = void;
    foreach (copy; 1 .. atomicLoad(_copies) + 1) {
        snprintf(path.ptr, path.length, "%s%zu.so", _copyPrefix.ptr, copy);
        unlink(path.ptr);
    }
}


private __gshared char[4096] _copyPrefix;


// The path of the image to copy for `program`: the one prepared with the
// project's other images, or the one for programs that have no project.
private string registryImage(Program program) {
    if (program.testStartupImage !is null)
        return program.testStartupImage.path;

    if (auto found = atomicLoad(_defaultImage))
        return *cast(string*) found;

    import core.sys.posix.unistd: getuid;
    import std.conv: text;
    import std.file: tempDir;
    import std.path: buildPath;

    auto path = new string[1];
    path[0] = prepareRegistryImage(tempDir.buildPath(
        text("snakebite-registry-", getuid))).path;
    atomicStore(_defaultImage, cast(shared) path.ptr);
    return path[0];
}


private shared(string)* _defaultImage;
