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
// The functions of `pragma(crt_constructor)` and `pragma(crt_destructor)` are
// not druntime's in compiled D: the C runtime runs them from its init and
// fini arrays, in the order of the object files, before and after druntime.
// Here the constructors run before the registration, so they run when druntime
// refuses the modules too, and the destructors run once after druntime's
// destructor phase: from the last destructor of one more record, from the
// handler of `exit`, from `finish`, or at once when the start fails. They run
// when at least one constructor ran, or when the program has none. With a
// dependency image, a guest constructor runs after druntime start-up and after
// the `shared static this` of the dependency, where compiled D runs it before
// them.
//
// A process that runs one guest program and then ends (`bin/sb`) leaves the
// registration to its own `rt_term`, which runs the phases in the order
// druntime defines, and, for a program that calls `exit`, to a handler that
// `exit` runs first. A caller that runs many programs in one process (`run`,
// the tests, the REPL) ends the phases itself with `finish`.
public struct GuestModules {
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

    // While it lives, the explicit runtime start and end of a program with
    // a C entry run the module phases of `program`.
    public struct Entry {
        private EntryRun* _entry;

        @disable this(this);

        public this(Backend backend, Program program) {
            import std.conv: text;
            import std.string: toStringz;
            import snakebite.runtimeentry: RuntimeEntry;

            if (!program.hasCEntryPoint || program.checks.betterC)
                return;

            _entry = new EntryRun;
            _entry.backend = backend;
            _entry.program = program;
            _entry.file = Image.newFile;
            _entry.token = text("/proc/self/fd/", _entry.file).toStringz;
            RuntimeEntry.bind(_entry, &startEntry, &finishEntry, _entry.token);
        }

        public ~this() {
            import core.sys.posix.unistd: close;
            import snakebite.runtimeentry: RuntimeEntry;

            if (_entry is null)
                return;

            RuntimeEntry.unbind;
            _entry.modules.finish;
            close(_entry.file);
        }
    }

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
        import core.sys.posix.pthread: pthread_self;
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
            run.owner = pthread_self;
            run.threadsAtStart = kernelThreads;
            run.image = Image.open;
            if (ends == Ends.process)
                run.exit = newExitRecord(run, run.image.slot);

            run.runCrtConstructors;
            run.image.register(run.records);
        } catch (Throwable throwable) {
            atomicStore(run.state, Run.State.failed);
            print(throwable);
            modules._failed = true;
            try
                run.runCrtDestructors;
            catch (Throwable destructorThrowable)
                print(destructorThrowable);
            // The process ends with `main` and `rt_term` can free the GC heap
            // (`--DRT-gcopt=profile:1`) before `endAtExit` runs, which then
            // must not read the run.
            if (run.exit !is null) {
                atomicStore(run.exit.returned, true);
                atomicStore(run.exit.crtPending, false);
            }

            // No caller ends a program that did not start, and what startup
            // registered is still there.
            if (ends == Ends.program) {
                modules._run = null;
                run.end;
            }
        }
        modules.constructors = MonoTime.currTime - registering;
        return modules;
    }

    public bool failed() const {
        return _failed;
    }

    // What the calling thread registered with druntime and did not unregister,
    // and the registry images it opened and did not close. Unlike the maps of
    // the process, other threads cannot change them.
    version(unittest)
    public static Held held() {
        return Held(_registrations, _images, _leftToExit);
    }

    public struct Held {
        ptrdiff_t registrations;
        ptrdiff_t images;
        // The registrations that this thread left to the end of the process.
        ptrdiff_t leftToExit;
    }

    // Ends the program. When the process ends with it, `rt_term` runs the
    // destructors and `exit` no longer has to. Otherwise this does what
    // `rt_term` does for the thread that ran the program: that thread's
    // thread-local destructors, then the shared ones, each module in the
    // reverse of the order in which druntime ran its constructor, and then the
    // `crt_destructor` functions. Returns 1 when a destructor threw, as
    // `rt_term` then makes the program fail.
    //
    // The registration goes with the program when no thread that the
    // program started is alive: a thread inherits the registrations of the
    // thread that starts it, and druntime frees a registration for the
    // thread that removes it only. Otherwise the registration, the image
    // and the entries stay, and every entry does nothing, so a process that
    // runs many programs that leave threads alive grows with each of them.
    // The end of the process removes what stayed.
    public int finish() {
        if (_run is null || _failed)
            return 0;

        auto run = _run;
        _run = null;
        if (_ends == Ends.process) {
            atomicStore(run.exit.returned, true);
            return 0;
        }

        int status;
        try {
            foreach_reverse (phase; run.threadOrder)
                phase.execute;
            foreach_reverse (phase; run.sharedOrder)
                phase.execute;
            run.runCrtDestructors;
        } catch (Throwable throwable) {
            print(throwable);
            status = 1;
        }

        atomicStore(run.state, Run.State.finished);
        run.end;
        return status;
    }
}


private struct EntryRun {
    Backend backend;
    Program program;
    GuestModules modules;
    int file;
    const(char)* token;
}

private extern(C) int startEntry(void* owner) {
    auto entry = cast(EntryRun*) owner;
    entry.modules = GuestModules.start(entry.backend, entry.program,
        GuestModules.Tests.no, GuestModules.Ends.process);
    return !entry.modules.failed;
}

private extern(C) void thread_joinAll();

private extern(C) int finishEntry(void* owner) {
    auto entry = cast(EntryRun*) owner;
    if (entry.modules.failed)
        return 0;

    auto run = entry.modules._run;
    if (run is null)
        return 1;

    int status = 1;
    try {
        auto group = registeredGroup(*run.image.slot); // Runtime methods mutate their group.
        group.runTlsDtors;
        thread_joinAll;
        group.runDtors;
    } catch (Throwable throwable) {
        print(throwable);
        status = 0;
    }
    atomicStore(run.state, Run.State.finished);
    entry.modules.finish;
    run.end;
    return status;
}

// Native declarations for the actual shared runtime's registered module group.
private struct RuntimeGroup {
    immutable(ModuleInfo*)[] modules;
    immutable(ModuleInfo)*[] constructors;
    immutable(ModuleInfo)*[] threadConstructors;
    pragma(mangle, "_D2rt5minfo11ModuleGroup11runTlsDtorsMFZv") void runTlsDtors();
    pragma(mangle, "_D2rt5minfo11ModuleGroup8runDtorsMFZv") void runDtors();
}

pragma(mangle, "_D2rt19sections_elf_shared3DSO11moduleGroupMNgFNbNcNdNiNjZNgSQCh5minfo11ModuleGroup")
private extern(C) RuntimeGroup* registeredGroup(void* dso);


private import core.atomic: atomicLoad, atomicStore, cas;
private import snakebite.backends.backend: Backend, Program;
private import snakebite.exception: SnakebiteException;
private import snakebite.ffi.callback: CallbackBridge, CallbackCall;


// What `endAtExit` needs, in memory that the GC does not own: after a normal
// end druntime can have freed the GC heap (`--DRT-gcopt=profile:1`) when
// `exit` runs the handler.
private struct ExitRecord {
    // Whether `rt_term` runs the phases of the program: it ended with `main`
    // or never started.
    shared bool returned;
    // Whether the program ended and its registration stayed, so that the
    // end of the process removes it.
    bool left;
    // Whether `rt_term` still can run the `crt_destructor` functions: when it
    // is true and `returned` too, `rt_term` is in a destructor phase, so the
    // `Run` is alive.
    shared bool crtPending;
    void** slot;
    Run* run;
    ExitRecord* next;
}


private ExitRecord* newExitRecord(Run* run, void** slot) {
    import core.stdc.stdlib: malloc;

    auto record = cast(ExitRecord*) malloc(ExitRecord.sizeof);
    record.returned = false;
    record.left = false;
    record.crtPending = run !is null && run.crtDestructors !is null;
    record.slot = slot;
    record.run = run;
    registerEndHandler;
    ExitRecord* head;
    do {
        head = cast(ExitRecord*) atomicLoad(_ending);
        record.next = head;
    } while (!cas(&_ending, cast(shared) head, cast(shared) record));

    return record;
}


// A registration that stays after its program ended: the end of the process
// removes it, and runs none of its entries.
private void leaveToExit(Run* run) {
    run.exit = newExitRecord(null, run.image.slot);
    run.exit.left = true;
    ++_leftToExit;
}


private void registerEndHandler() {
    import core.stdc.stdlib: atexit;

    if (cas(&_endHandlerRegistered, false, true))
        atexit(&endAtExit);
}


// `exit` runs this before the loader finalizes the images, with the runtime
// initialised: unregistering the records makes druntime run the destructors
// of the calling thread and then the shared ones. A program that is not
// registered yet, because `exit` came from a `crt_constructor` function, has
// no destructor to run but the `crt_destructor` ones.
private extern(C) void endAtExit() {
    for (auto record = cast(ExitRecord*) atomicLoad(_ending); record !is null;
            record = record.next) {
        if (atomicLoad(record.returned)) {
            if (atomicLoad(record.crtPending))
                try
                    record.run.runCrtDestructors;
                catch (Throwable throwable)
                    print(throwable);
            continue;
        }

        if (*record.slot !is null)
            try
                Image.unregister(record.slot);
            catch (Throwable throwable)
                print(throwable);

        // A registration that stayed after its program ended has no run: the
        // end of that program ran the destructors.
        if (record.run !is null)
            try
                record.run.runCrtDestructors;
            catch (Throwable throwable)
                print(throwable);
    }
}


private shared(ExitRecord*) _ending;
private ptrdiff_t _registrations;
private ptrdiff_t _images;
private ptrdiff_t _leftToExit;
private shared bool _endHandlerRegistered;


private extern(C) void _d_dso_registry(void* data);
private extern(C) void _d_print_throwable(Throwable);


// A failure of snakebite itself while a phase runs. druntime prints what a
// phase throws, so this prints the message that the rest of the tool prints
// for such a failure and not a stack trace of the host.
private final class HostFailure: Exception {
    this(string message) {
        super(message);
    }

    override void toString(scope void delegate(in char[]) sink) const {
        sink("snakebite: ");
        sink(msg);
        sink("\n");
    }
}


// A thread of the process. The kernel gives the id of an ended thread to a
// new thread, so the start time tells the two apart.
private struct KernelThread {
    int id;
    ulong startTime;
}


// The threads of the process that are alive, or null when the process cannot
// say.
private KernelThread[] kernelThreads() {
    import std.array: split;
    import std.conv: to;
    import std.file: dirEntries, readText, SpanMode;
    import std.path: baseName;
    import std.string: lastIndexOf;

    KernelThread[] threads;
    try
        foreach (entry; dirEntries("/proc/self/task", SpanMode.shallow)) {
            string stat;
            // A thread that ended after the directory listed it.
            try
                stat = readText(entry.name ~ "/stat");
            catch (Exception)
                continue;

            // The name of the thread can contain spaces and parentheses; the
            // start time is field 22, and the state after the name is field 3.
            const fields = stat[stat.lastIndexOf(')') + 2 .. $].split;
            threads ~= KernelThread(
                entry.name.baseName.to!int, fields[19].to!ulong);
        }
    catch (Exception)
        return null;

    return threads;
}


private void print(Throwable throwable) {
    if (auto failure = cast(SnakebiteException) throwable)
        throwable = new HostFailure(failure.msg);

    _d_print_throwable(throwable);
}


// What one registration holds and what the entries of its records reach.
private struct Run {
    import dmd.func: FuncDeclaration;
    import core.sys.posix.pthread: pthread_t;

    // `running` until the program ends, then `finished`, when an entry that
    // a thread still alive reaches does nothing. `failed` when startup
    // threw: no destructor runs for a program that did not start.
    enum State : int {
        running,
        finished,
        failed,
    }

    Backend backend;
    shared State state;
    ModuleInfo*[] records;
    Image image;
    CallbackBridge* bridge;
    FuncDeclaration nativeDeclaration;
    const(ModuleInfo*)[] dependencyModules;
    ExitRecord* exit;
    // The thread that registered, and the modules with destructors in the
    // order druntime ran their constructors on it: `finish` runs the
    // destructors in the reverse order.
    pthread_t owner;
    Phase*[] sharedOrder;
    Phase*[] threadOrder;
    // The functions of `pragma(crt_constructor)` and `pragma(crt_destructor)`,
    // or null when there is none. The destructors run when a constructor ran,
    // one time.
    Phase* crtConstructors;
    Phase* crtDestructors;
    shared bool crtConstructed;
    shared bool crtDestructed;
    KernelThread[] threadsAtStart;

    // A registration reaches a thread through the thread that starts it, so
    // a thread that the program started holds it, and such a thread was not
    // alive at the start. The ids of the process find a thread that was
    // started and has not listed itself in druntime yet; the list of druntime
    // does not.
    bool noThreadHoldsRegistration() {
        import std.algorithm.searching: all, canFind;

        const now = kernelThreads;
        return threadsAtStart.length != 0
            && now.length != 0
            && now.all!(thread => threadsAtStart.canFind(thread));
    }

    // Gives the registration back, or leaves it to the end of the process when
    // a thread holds it.
    void end() {
        if (image.slot is null || noThreadHoldsRegistration)
            release;
        else
            leaveToExit(&this);
    }

    // Throws what a function throws: the caller ends the start.
    void runCrtConstructors() {
        if (crtConstructors is null)
            return;

        atomicStore(crtConstructed, true);
        crtConstructors.call;
    }

    // Throws what a function throws: the caller ends the program. The
    // functions after the one that threw do not run.
    void runCrtDestructors() {
        import core.atomic: cas;

        if (exit !is null)
            atomicStore(exit.crtPending, false);

        if (crtDestructors is null || !atomicLoad(crtConstructed)
            || !cas(&crtDestructed, false, true))
            return;

        crtDestructors.call;
    }

    // Removes the registration and everything it holds.
    void release() {
        import core.memory: GC;

        try
            image.unregister;
        catch (Throwable throwable)
            print(throwable);

        image.close;
        bridge.release;
        GC.removeRoot(&this);
    }
}


private struct Phase {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;

    enum Kind {
        constructor,
        threadConstructor,
        destructor,
        crtDestructor,
        unitTests,
    }

    Run* run;
    Kind kind;
    FuncDeclaration[] functions;
    // dmd's glue layer increments the gate of each destructor of a template
    // instance while it runs the constructors of the module: the destructor
    // body returns early unless it brings the gate back to zero.
    VarDeclaration[] gates;
    // For a constructor phase, the destructor phase of the same module.
    Phase* destructor;
    void function() nativeFunction;
}


private extern(C) void callPhase(void* owner, CallbackCall* call) {
    (cast(Phase*) call.function_).execute;
}


private void execute(Phase* phase) {
    import core.atomic: atomicOp;
    import core.sys.posix.pthread: pthread_equal, pthread_self;

    auto run = phase.run;
    final switch (phase.kind) with (Phase.Kind) {
        case constructor:
        case threadConstructor:
            if (atomicLoad(run.state) != Run.State.running)
                return;

            foreach (gate; phase.gates) {
                auto storage = run.backend.staticStorage(gate);
                if (storage.length)
                    atomicOp!"+="(*cast(shared int*) storage.ptr, 1);
            }
            break;
        case destructor:
            if (atomicLoad(run.state) != Run.State.running)
                return;
            break;
        case crtDestructor:
            if (atomicLoad(run.state) == Run.State.running)
                run.runCrtDestructors;
            return;
        case unitTests:
            break;
    }

    // druntime skips the rest of its phase and ends the program.
    try
        phase.call;
    catch (Throwable throwable) {
        if (run.exit !is null)
            atomicStore(run.exit.crtPending, false);
        throw throwable;
    }

    if (phase.destructor is null || !pthread_equal(pthread_self, run.owner))
        return;

    if (phase.kind == Phase.Kind.constructor)
        run.sharedOrder ~= phase.destructor;
    else
        run.threadOrder ~= phase.destructor;
}


private void call(Phase* phase) {
    try
        if (phase.nativeFunction !is null)
            phase.nativeFunction(); // A function pointer needs explicit call syntax.
        else
        foreach (function_; phase.functions)
            phase.run.backend.call(function_, null, []);
    catch (SnakebiteException failure)
        throw new HostFailure(failure.msg);
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
    const dependencies = program.dependencyImage is null
        ? null : program.dependencyImage.deferredModules;
    needed = needed || dependencies.length != 0;
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
    run.dependencyModules = dependencies;
    if (dependencies.length) {
        import dmd.astenums: LINK, STC;
        import dmd.func: FuncDeclaration;
        import dmd.identifier: Identifier;
        import dmd.location: Loc;
        import dmd.mtype: Type, TypeFunction, ParameterList;
        import snakebite.frontend.compiler: newInFrontend;
        auto identifier = newInFrontend!(Identifier.idPool)( // DMD takes a mutable identifier.
            "snakebite_module_phase");
        auto type = newInFrontend!TypeFunction( // DMD declarations take a mutable type.
            ParameterList.init, Type.tvoid, LINK.d);
        run.nativeDeclaration = newInFrontend!FuncDeclaration(
            Loc.initial, Loc.initial, identifier, cast(STC) 0, type);
    }
    run.records = recordsOf(run, specs, tests);
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
            || functions.crtConstructors.length
            || functions.crtDestructors.length
            || hasDestructors;
    }

    bool hasDestructors() const {
        return functions.sharedDestructors.length
            || functions.threadDestructors.length;
    }
}


// One record for each module.
private ModuleInfo*[] recordsOf(
    Run* run,
    ModuleSpec[] specs,
    in GuestModules.Tests tests,
) {
    import std.string: fromStringz;
    import snakebite.frontend.dmd.functions: findUnittests;

    auto records = new ModuleInfo*[specs.length];
    auto nativeRecords = nativeRecordsOf(run); // Imports refer to these mutable copies.
    ModuleInfo*[string] nativeByName;
    foreach (record; nativeRecords)
        nativeByName[record.name] = record;
    auto nativeImports = new ModuleInfo*[][specs.length];
    if (nativeRecords.length)
        foreach (i, spec; specs)
            foreach (module_; spec.module_.aimports) {
                const name = module_.toPrettyChars.fromStringz;
                if (auto record = name in nativeByName)
                    nativeImports[i] ~= *record;
            }
    auto crtRecord = crtRecordOf(run, specs);
    auto importSlots = new ModuleInfo**[specs.length];
    const imports = importsOf(specs);
    foreach (i, spec; specs) {
        auto functions = spec.functions;
        Fields fields;
        fields.name = spec.module_.toPrettyChars.fromStringz.idup;
        // druntime orders no module that has nothing to construct or
        // destruct, and no import of one: dmd marks it the same way.
        fields.standalone = !spec.module_.needmoduleinfo;
        fields.importCount = imports[i].length + nativeImports[i].length;
        // Every module with a destructor also gets a constructor entry, so
        // that `finish` learns where druntime put it in the order.
        auto sharedDestructor = run.phaseOf(
            Phase.Kind.destructor, reversed(functions.sharedDestructors));
        auto threadDestructor = run.phaseOf(
            Phase.Kind.destructor, reversed(functions.threadDestructors));
        fields.independentConstructor = run.entryOf(run.phaseOf(
            Phase.Kind.constructor, functions.independentConstructors));
        fields.constructor = run.entryOf(run.phaseOf(
            Phase.Kind.constructor,
            functions.sharedConstructors,
            gatesOf(functions.sharedDestructors),
            sharedDestructor,
        ));
        fields.threadConstructor = run.entryOf(run.phaseOf(
            Phase.Kind.threadConstructor,
            functions.threadConstructors,
            gatesOf(functions.threadDestructors),
            threadDestructor,
        ));
        fields.destructor = run.entryOf(sharedDestructor);
        fields.threadDestructor = run.entryOf(threadDestructor);
        if (tests == GuestModules.Tests.yes)
            fields.unitTests = run.entryOf(run.phaseOf(
                Phase.Kind.unitTests, findUnittests(spec.module_)));

        records[i] = newRecord(fields, importSlots[i]);
    }

    foreach (i, slots; importSlots) {
        foreach (j, index; imports[i])
            slots[j] = records[index];
        foreach (j, record; nativeImports[i])
            slots[imports[i].length + j] = record;
    }
    auto roots = crtRecord is null ? records : crtRecord ~ records; // Registration takes mutable records.
    return nativeRecords.length ? roots ~ nativeRecords : roots;
}


private ModuleInfo*[] nativeRecordsOf(Run* run) {
    import core.stdc.string: memcpy;

    ModuleInfo*[] records;
    ModuleInfo*[const(ModuleInfo)*] copies;
    foreach (original; run.dependencyModules) {
        const name = original.name;
        const size = cast(const(ubyte)*) name.ptr + name.length + 1
            - cast(const(ubyte)*) original;
        auto storage = new void[size];
        memcpy(storage.ptr, original, size);
        auto record = cast(ModuleInfo*) storage.ptr;
        record._index = 0;
        auto slot = cast(void**) (storage.ptr + ModuleInfo.sizeof);
        // The order of the fields in the record. `xgetMembers` is a field
        // that druntime never calls.
        foreach (flag; [MItlsctor, MItlsdtor, MIctor, MIdtor, MIxgetMembers,
                MIictor, MIunitTest]) {
            if (!(record._flags & flag))
                continue;

            if (flag != MIxgetMembers) {
                auto phase = new Phase;
                phase.run = run;
                phase.kind = flag == MItlsctor ? Phase.Kind.threadConstructor
                    : flag == MIctor || flag == MIictor ? Phase.Kind.constructor
                    : flag == MIunitTest ? Phase.Kind.unitTests
                    : Phase.Kind.destructor;
                phase.nativeFunction = cast(void function()) *slot;
                run.bridge.register(phase, run.nativeDeclaration);
                *slot = cast(void*) run.entryOf(phase);
            }
            ++slot;
        }
        copies[original] = record;
        records ~= record;
    }
    foreach (record; records)
        foreach (ref dependency; cast(ModuleInfo*[]) record.importedModules)
            if (auto replacement = dependency in copies)
                dependency = *replacement;
    return records;
}


// Sets up the `crt_constructor` functions of all modules in `run`, and
// returns the record of their `crt_destructor` functions, or null when there
// are none. Without a constructor, the destructors have nothing to wait for.
//
// The record is first and standalone, as druntime puts such a module first
// among the ones that have a destructor, which makes its destructor the last.
private ModuleInfo* crtRecordOf(Run* run, ModuleSpec[] specs) {
    imported!"dmd.func".FuncDeclaration[] constructors;
    imported!"dmd.func".FuncDeclaration[] destructors;
    foreach (spec; specs) {
        constructors ~= spec.functions.crtConstructors;
        destructors ~= spec.functions.crtDestructors;
    }

    if (constructors.length)
        run.crtConstructors = new Phase(
            run, Phase.Kind.constructor, constructors);
    else
        atomicStore(run.crtConstructed, true);

    if (destructors.length == 0)
        return null;

    Fields fields;
    fields.name = "snakebite_crt";
    fields.standalone = true;
    run.crtDestructors = run.phaseOf(
        Phase.Kind.crtDestructor, reversed(destructors));
    fields.destructor = run.entryOf(run.crtDestructors);
    ModuleInfo** unused;
    return newRecord(fields, unused);
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


// The phase of a module that runs `functions`, or null when there is
// nothing to run and, for a constructor phase, no destructor phase to place.
private Phase* phaseOf(
    Run* run,
    in Phase.Kind kind,
    imported!"dmd.func".FuncDeclaration[] functions,
    imported!"dmd.declaration".VarDeclaration[] gates = null,
    Phase* destructor = null,
) {
    if (functions.length == 0 && destructor is null)
        return null;

    auto phase = new Phase(run, kind, functions, gates, destructor);
    // The entry takes its type from a function: the destructors have the
    // type of the constructors.
    run.bridge.register(
        phase,
        functions.length ? functions[0] : destructor.functions[0],
    );
    return phase;
}


// The native entry that runs `phase`, or null when there is none.
private const(void)* entryOf(Run* run, Phase* phase) {
    return phase is null ? null : run.bridge.entryOf(phase);
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


// The bytes of the ELF image that provides a registration slot, which the
// build made and linked in (`registry_slot.c`).
private extern(C) extern __gshared const ubyte snakebite_registry_image_start;
private extern(C) extern __gshared const ubyte snakebite_registry_image_end;
private extern(C) int memfd_create(const char* name, uint flags);


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
    private int _file;
    private bool _registered;

    // A new copy of the image, because druntime keys an image by its loader
    // handle and the loader returns one handle for one file name. The copy
    // lives in an anonymous memory file, which needs no writable or
    // executable directory and leaves nothing behind. The file stays open as
    // long as the image does: its descriptor number is the file name the
    // loader sees, so no two images that are alive have the same name.
    public static Image open() {
        import core.sys.posix.unistd: close;
        import std.conv: text;
        import std.string: fromStringz, toStringz;

        const file = newFile;
        scope(failure) close(file);
        Image image;
        image._file = file;
        image._handle = dlopen(
            text("/proc/self/fd/", file).toStringz, RTLD_NOW | RTLD_LOCAL);
        if (image._handle is null)
            throw new SnakebiteException(text(
                "cannot load the registry image: ", dlerror.fromStringz));

        alias Slot = extern(C) void** function();
        auto slot = cast(Slot) dlsym(image._handle, "snakebite_registry_slot");
        if (slot is null)
            assert(0, "the registry image exports its slot");

        image._slot = slot();
        ++_images;
        return image;
    }

    // An open anonymous memory file with the bytes of the image.
    public static int newFile() {
        import core.stdc.errno: errno;
        import core.stdc.string: strerror;
        import core.sys.posix.unistd: close, write;
        import std.conv: text;
        import std.string: fromStringz;

        enum MFD_CLOEXEC = 1;
        const file = memfd_create("snakebite-registry", MFD_CLOEXEC);
        if (file < 0)
            throw new SnakebiteException(text(
                "cannot create the registry image: ",
                strerror(errno).fromStringz));

        scope(failure) close(file);
        const bytes = (&snakebite_registry_image_start)[
            0 .. &snakebite_registry_image_end - &snakebite_registry_image_start];
        for (size_t written; written < bytes.length; ) {
            const count = write(
                file, bytes.ptr + written, bytes.length - written);
            if (count <= 0)
                throw new SnakebiteException(text(
                    "cannot write the registry image: ",
                    strerror(errno).fromStringz));

            written += count;
        }

        return file;
    }

    public void register(ModuleInfo*[] records) {
        auto data = CompilerDSOData(
            1, _slot, records.ptr, records.ptr + records.length);
        // druntime keeps the registration when a constructor throws.
        _registered = true;
        ++_registrations;
        _d_dso_registry(&data);
    }

    public void unregister() {
        if (!_registered)
            return;

        _registered = false;
        unregister(_slot);
    }

    public static void unregister(void** slot) {
        auto data = CompilerDSOData(1, slot, null, null);
        _d_dso_registry(&data);
        --_registrations;
    }

    public void** slot() {
        return _slot;
    }

    public void close() {
        import core.sys.posix.unistd: close;

        if (_handle is null)
            return;

        dlclose(_handle);
        close(_file);
        --_images;
    }
}
