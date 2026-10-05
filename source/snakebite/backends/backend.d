module snakebite.backends.backend;


private:


// The root modules of the guest program, parsed and semantically analysed by
// the frontend, and its entry point. A dub project is not special: a
// dub-aware driver asks dub for import paths and flags and builds one of
// these.
public struct Program {
    import snakebite.dependencyimage: DependencyImage, TestHooks;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;
    import dmd.dsymbol: Dsymbol;
    import snakebite.backends.guestfault: GuestFault;
    import snakebite.backends.haltprocess: HaltAction, HostActions;
    import snakebite.frontend.checks: Checks;
    import snakebite.frontend.dmd.linking: LinkMap;

    // `func` is null when the program has no `main`, which is not an error: a
    // bare directory of `.d` files can be a library.
    struct Main {
        FuncDeclaration func;
    }

    Module[] rootModules;
    // Built once from `rootModules`, for `isRootOwned`'s `O(1)` lookup; see
    // `snakebite.frontend.dmd.functions.isRootOwned`.
    private bool[Module] _rootModuleSet;
    // Built once from `rootModules`; see `linkedFunctionOf`.
    private LinkMap _links;
    Main main;
    string name;
    private Checks _checks;
    private HostActions _actions;
    // Prepared for this project's execution before any guest code runs.
    const(DependencyImage)* dependencyImage;
    // Whether the program starts as a project does: its unit tests run
    // before `main`, under the runner that the project's own images name.
    bool startsAsProject;
    TestHooks testHooks;

    // The entry point is found the way a compiled build finds it: the first
    // root module declaring a module-level `main`.
    this(Module[] rootModules) {
        this(rootModules, "");
    }

    this(
        Module[] rootModules,
        in string name,
    ) {
        this(rootModules, name, Checks());
    }

    // `checks` are the ones the frontend analysed `rootModules` under, and
    // `actions` are what `-checkaction=halt` and a guest fault do here: the
    // default halt ends the process, as compiled code does.
    this(
        Module[] rootModules,
        in string name,
        in Checks checks,
        in HostActions actions = HostActions(),
    ) {
        import snakebite.frontend.compiler: withCompilerLock;
        import snakebite.frontend.dmd.functions: findFunction;

        this.rootModules = rootModules;
        this.name = name;
        _checks = checks;
        _actions = actions;
        // The walks read the frontend's global state, which a thread that
        // evaluates a literal changes under the lock at the same time.
        withCompilerLock({
            _links = LinkMap(rootModules);
            foreach (module_; rootModules) {
                _rootModuleSet[module_] = true;
            }

            foreach (module_; rootModules) {
                auto found = findFunction(module_, "main");
                if (found !is null) {
                    main = Main(found);
                    break;
                }
            }
        });
    }

    public Checks checks() const {
        return _checks;
    }

    // What a backend that can hold a function pointer stores.
    public HaltAction haltAction() const {
        return _actions.halt;
    }

    public noreturn halt() const {
        _actions.halt();
    }

    public GuestFault.Action faultAction() const {
        return _actions.fault;
    }

    public noreturn fault(
        in GuestFault.Kind kind,
        in const(char)[] file,
        in size_t line,
        scope GuestFault.Stack stack,
    ) const {
        _actions.fault(kind, file, line, stack);
    }

    // The root definition that the linker makes of the declaration
    // `function_`, or `function_` itself. Backends ask this once for each
    // function, through `CallSelection.definitionOf`, not for each call.
    public FuncDeclaration linkedFunctionOf(
        FuncDeclaration function_,
    ) const {
        return _links.definitionOf(function_);
    }

    public bool definesLinkableFunctions() const {
        return _links.definesLinkableFunctions;
    }

    // As `linkedFunctionOf`, for an `extern` variable.
    public imported!"dmd.declaration".VarDeclaration linkedVariableOf(
        imported!"dmd.declaration".VarDeclaration variable,
    ) const {
        return _links.definitionOf(variable);
    }

    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it: druntime does not start, so a build with unit tests runs
    // none of them and no module constructor, and the program is only
    // that function.
    public bool hasCEntryPoint() const {
        import dmd.astenums: LINK;

        return main.func !is null
            && (cast() main.func).resolvedLinkage == LINK.c;
    }

    public bool isInterpreted(
        FuncDeclaration function_,
    ) const {
        return function_ !is null && isRootOwned(function_);
    }

    // Whether `declaration` belongs to one of this program's own root
    // modules, rather than one dmd only reached through an `import` - both
    // a callee (`isInterpreted`) and a type's own runtime metadata
    // (`RuntimeTypes`) need this same answer for the same reason: guest
    // source gets no linked machine code or linked `TypeInfo` of its own.
    // The frontend's own load-time walks (e.g. the inline-asm check) ask
    // the identical question, so the predicate itself lives once in
    // `snakebite.frontend.dmd.functions` and this forwards to it.
    public bool isRootOwned(
        Dsymbol declaration,
    ) const {
        import snakebite.frontend.dmd.functions:
            frontendIsRootOwned = isRootOwned;

        return frontendIsRootOwned(declaration, _rootModuleSet);
    }
}


// Cumulative work done by a backend's compiler. A backend without a
// compilation phase leaves `hasCompiler` false; this is distinct from a
// compiler whose measured duration is zero.
public struct CompilationStatistics {
    import core.time: Duration;

    bool hasCompiler;
    size_t cacheMisses;
    Duration duration;
}


// Owns one backend: the only release of the execution state the backend
// made for the calling thread while that thread lives (its frame stacks
// stay GC roots until then; the end of a thread also releases it). A site
// that holds the handle cannot forget to release.
// The backend itself stays on the GC heap: callback entries and guest
// finalizers can still reach it. A handle must not be a member of a GC
// object: the destructor calls a virtual function, and the GC can finalize
// the backend first.
public struct Owned(B : Backend) {
    private B _backend;

    @disable this(this);

    public this(B backend) {
        _backend = backend;
    }

    static if (!__traits(isAbstractClass, B)) {
        public this(const Program program) {
            _backend = new B(program);
        }
    }

    ~this() {
        // `release` is protected: through the base class it is visible here.
        Backend base = _backend;
        if (base !is null)
            base.release;
    }

    public B backend() {
        return _backend;
    }

    alias backend this;
}


public abstract class Backend {
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // The program this backend runs. Whether a callee is interpreted or
    // called natively is the program's one decision (`isInterpreted`),
    // so every backend is constructed knowing which program it runs.
    protected const Program _program;

    protected this(const Program program) {
        _program = program;
    }

    // Gives back the execution state, with its frame stacks, that this
    // backend made for the calling thread. A later call of the backend on
    // this thread, such as a GC finalizer that runs a guest destructor,
    // makes a new state, and nothing releases that state before the thread
    // ends. Nothing limits their number: a REPL session whose cells leave
    // such objects keeps a state for most of them (ADR-0006 has measured
    // numbers). Host callback entries stay, and so do the guest
    // thread-local variables that a program touched: an object that is not
    // finalized yet can still call through them or point into them.
    protected void release() {
    }

    // Read-only cumulative statistics. Backends without a compilation phase
    // use the default empty result.
    public CompilationStatistics compilationStatistics() const {
        return CompilationStatistics.init;
    }

    // Invoke one guest function. `args` and the value written to
    // `returnPlace` are in native layout, exactly as compiled D would lay
    // them out; `null` for `returnPlace` means the result is discarded
    // (e.g. a `void` function, or a caller that does not need the value).
    // Type information travels only through `function_`'s dmd type, not
    // through the untyped `void*[]`.
    //
    // `args[i]` points at the native bytes of parameter `i`; for a `ref`
    // or `out` parameter those bytes are the target's own address, one
    // pointer wide - the same convention a callback re-entry already
    // uses. When `function_` has a hidden `this` (a member method or a
    // nested function that reads an outer member's `this`), `args[0]` is
    // that same shape one more time, before the declared parameters: the
    // address of a pointer-sized word holding the context.
    //
    // For a value-returning callee, `returnPlace` must be exactly the
    // return type's size. For a `ref`-returning callee, `returnPlace`
    // must be pointer-sized: the callee hands back the result's own
    // address, not its value, the same word compiled D returns in `rax`.
    //
    // A guest failure (a failed assert, an uncaught guest exception) throws
    // a host exception, the same as `eval`.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    public abstract void call(
        FuncDeclaration function_, void* returnPlace, void*[] args,
    );

    // The bytes of the process-wide `static` or `__gshared` variable
    // `variable`, in native layout, or empty when this backend keeps no
    // static storage between calls (CTFE evaluates each call in isolation).
    // Module phases use it to do what dmd's glue layer does with the gate
    // of a module destructor.
    public abstract void[] staticStorage(
        imported!"dmd.declaration".VarDeclaration variable,
    );

    // Execute one synthesised `string`-returning function and return its
    // result. The guest renders the value itself (`std.conv.text`), so the
    // returned string is a natively laid out value like any other; nothing
    // is boxed or marshalled. A `Throwable` that escapes propagates to the
    // caller.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    //
    // Collapses into `call` once `call` can return a native `string`.
    public abstract string eval(FuncDeclaration function_);
}

// "Run on this project": do what a compiled build of it does, implemented
// once on top of `call`, and return the exit status. A `Throwable` that
// escapes `main` is handled as druntime would handle it: printed, exit
// status 1. The module constructors and destructors belong to druntime
// (`GuestModules`): it orders them, runs them on each thread, and prints
// what a destructor throws.
public int run(
    Backend backend,
    Program program,
    in string[] hostArguments = null,
) {
    import snakebite.backends.guestmodules: GuestModules;

    // A C `main` starts no druntime: no module constructor or destructor
    // of a D module runs.
    if (program.hasCEntryPoint || program.checks.betterC)
        return runMain(backend, program, hostArguments);

    auto modules = GuestModules.start(
        backend, program, GuestModules.Tests.no, GuestModules.Ends.program);
    if (modules.failed)
        return 1;

    const status = runMain(backend, program, hostArguments);
    const destructorStatus = modules.finish;
    return status != 0 ? status : destructorStatus;
}

// The program's own `main`. `void main` maps to exit status 0, and no `main`
// at all is not an error: the status is 0.
package(snakebite) int runMain(
    Backend backend,
    Program program,
    in string[] hostArguments,
) {
    import dmd.astenums: Tvoid;
    import dmd.typesem: nextOf;

    auto main_ = program.main.func;
    if (main_ is null)
        return 0;

    const isVoid = main_.type.nextOf.ty == Tvoid;
    int status;
    string[] arguments;
    void*[] mainArguments;
    CArguments cArguments;
    if (program.hasCEntryPoint) {
        arguments = hostArguments.length ? hostArguments.dup : [program.name];
        cArguments = CArguments(arguments);
        mainArguments = cArguments.of(main_);
    } else if (main_.parameters !is null && main_.parameters.length != 0) {
        arguments = hostArguments.length
            ? hostArguments.dup
            : [program.name];
        mainArguments = [cast(void*) &arguments];
    }
    return failing(() {
        backend.call(main_, isVoid ? null : &status, mainArguments);
    }) ? 1 : status;
}

// The values a C `main` takes, in the order the C runtime passes them:
// `argc`, `argv` and the environment.
private struct CArguments {
    private int _argc;
    private char*[] _storage;
    private char** _argv;
    private char** _environment;

    this(in string[] arguments) {
        import core.sys.posix.unistd: environ;
        import std.algorithm.iteration: map;
        import std.array: array;
        import std.string: toStringz;

        _argc = cast(int) arguments.length;
        _storage = arguments.map!(argument => cast(char*) argument.toStringz)
            .array ~ null;
        _argv = _storage.ptr;
        _environment = cast(char**) environ;
    }

    // The address of each argument `main_` declares.
    void*[] of(imported!"dmd.func".FuncDeclaration main_) {
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        void*[3] all = [
            cast(void*) &_argc, cast(void*) &_argv, cast(void*) &_environment,
        ];
        return all[0 .. typeFunctionOf(main_).parameterList.length].dup;
    }
}

// Runs one guest call, reporting an escaping `Throwable` the way druntime
// reports one out of `main`: the message on stderr, and the process fails.
private bool failing(scope void delegate() call) {
    import core.stdc.stdio: fprintf, stderr;
    import std.string: toStringz;

    try
        call();
    catch (Throwable throwable) {
        fprintf(stderr, "%s\nat %s:%llu\n",
            throwable.msg.toStringz,
            throwable.file.toStringz,
            throwable.line,
        );
        return true;
    }

    return false;
}
