module snakebite.run.program;


private:


import snakebite.backends.api: Backend;
import snakebite.start.data: StartData;
import snakebite.ffi.shape: ArgumentPlan, Linkage, Register;
import snakebite.ffi.callback: CallbackBridge, CallbackCall;
import snakebite.ffi.plan: NativeSignature;


// "Run on this project": do what a compiled build of it does, implemented
// once on top of the start data, and return the exit status. A `Throwable`
// that escapes `main` is handled as druntime would handle it: printed, exit
// status 1. The module constructors and destructors belong to druntime
// (`GuestModules`): it orders them, runs them on each thread, and prints
// what a destructor throws.
public int run(
    Backend backend,
    in string[] hostArguments = null,
) {
    import snakebite.run.modules: GuestModules;

    // A C `main` starts no druntime: no module constructor or destructor
    // of a D module runs.
    auto start = &backend.startData();
    if (start.hasCEntryPoint || start.betterC)
        return runMain(backend, *start, hostArguments);

    auto modules = GuestModules.start(
        backend, GuestModules.Tests.no, GuestModules.Ends.program);
    if (modules.failed)
        return 1;

    const status = runMain(backend, *start, hostArguments);
    const destructorStatus = modules.finish;
    return status != 0 ? status : destructorStatus;
}

// The program's own `main`. `void main` maps to exit status 0, and no `main`
// at all is not an error: the status is 0.
package(snakebite) int runMain(
    Backend backend,
    StartData start,
    in string[] hostArguments,
) {
    if (!start.main.present)
        return 0;

    int status;
    string[] arguments;
    void*[] mainArguments;
    CArguments cArguments;
    if (start.hasCEntryPoint) {
        arguments = hostArguments.length
            ? hostArguments.dup : [start.programName];
        cArguments = CArguments(arguments);
        mainArguments = cArguments.of(start.main.parameterCount);
    } else if (start.main.parameterCount != 0) {
        arguments = hostArguments.length
            ? hostArguments.dup
            : [start.programName];
        mainArguments = [cast(void*) &arguments];
    }
    return failing(() {
        start.main.function_.call(
            start.main.returnsVoid ? null : &status, mainArguments);
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

    // The address of each of the first `count` arguments.
    void*[] of(in size_t count) {
        void*[3] all = [
            cast(void*) &_argc, cast(void*) &_argv, cast(void*) &_environment,
        ];
        return all[0 .. count].dup;
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


public struct StartupReport {
    import core.time: Duration;

    public int status;
    public Duration constructorDuration;
    public Duration moduleInfoDuration;
}


// Runs `program` the way its compiled `-unittest` build runs: through
// druntime's `_d_run_main`. The module constructors and destructors belong
// to druntime (`GuestModules`). `endsProcess` says that the process ends
// with this program: its own `rt_term` and `exit` then run the destructors,
// with the threads joined at the point druntime joins them. A caller that
// goes on running programs in one process has its destructors run before
// this returns.
public StartupReport runDruntimeMain(
    imported!"snakebite.backends.api".Backend backend,
    in imported!"snakebite.image.dependency".TestHooks testHooks,
    in string[] arguments,
    in bool endsProcess = false,
) {
    import snakebite.host.runlock: guestRunLock;
    import snakebite.run.modules: GuestModules;
    import snakebite.image.dependency: TestHooks;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.string: toStringz;

    // A guest run owns process-wide state for its duration: druntime's
    // runner hooks, its argument storage, `_main`, and the watched hooks
    // below. Two runs on two threads would clobber each other's, so one
    // runs at a time. The lock is recursive: a guest run that starts
    // another on the same thread still nests.
    guestRunLock.lock;
    scope(exit) guestRunLock.unlock;
    const savedHooks = TestHooks.current;
    auto savedArgs = _runtimeArgs; // Restore mutable host argument storage.
    auto savedCArgs = _runtimeCArgs; // C argv contains mutable pointers.
    scope(exit) {
        savedHooks.install;
        _runtimeArgs = savedArgs;
        _runtimeCArgs = savedCArgs;
    }
    auto start = &backend.startData();
    testHooks.install;
    _runtimeArgs = arguments.length ? arguments.dup : [start.programName];
    auto cArguments = _runtimeArgs.map!(arg => cast(char*) arg.toStringz).array ~ null;
    _runtimeCArgs.argc = cast(int) _runtimeArgs.length;
    _runtimeCArgs.argv = cArguments.ptr;

    auto modules = GuestModules.start(
        backend, GuestModules.Tests.yes,
        endsProcess ? GuestModules.Ends.process : GuestModules.Ends.program);
    StartupReport report;
    report.constructorDuration = modules.constructors;
    report.moduleInfoDuration = modules.moduleInfo;
    if (modules.failed) {
        report.status = 1;
        return report;
    }

    // `_d_run_main` takes a function pointer with no context: a native entry
    // (ADR-0003) carries the run to it.
    auto mainRun = MainRun(backend, start);
    mainRun.bridge = new CallbackBridge(&callMain, cast(void*) &mainRun);
    scope(exit) mainRun.bridge.release;
    mainRun.bridge.register(cast(void*) &mainRun, mainSignature);
    const entry = cast(MainFunction) mainRun.bridge.entryOf(&mainRun);
    // druntime owns runner selection, summaries, failure status and the
    // decision to call main. Its nested init/term pair is reference counted.
    // `_d_run_main` pairs its `rt_init` with `rt_term` only when
    // `runModuleUnitTests` returns. A runner hook that lets a throwable
    // escape - unit-threaded's own does, running its suite - skips that
    // `rt_term`, and druntime's init depth stays one too high. The host's
    // own `rt_term` would then only decrement: no `thread_joinAll`, no
    // module destructors, and the loader would run those at `exit` in
    // dependency order instead, after freeing the DSO records a guest
    // thread still walks when it ends. Watch the hooks the guest's
    // constructors left installed, and pay the skipped `rt_term` back, so
    // the host terminates the way compiled D does: guest threads joined
    // and destructors run before `exit`.
    TestHooks.Watch watch;
    watch.install(TestHooks.current);
    scope(exit) watch.restore;
    report.status = _d_run_main(_runtimeCArgs.argc, cArguments.ptr, entry);
    if (modules.finish && report.status == 0)
        report.status = 1;
    if (watch.escaped)
        rt_term();
    return report;
}


private struct MainRun {
    Backend backend;
    StartData* start;
    CallbackBridge* bridge;
}


// `extern(C) int main(char[][] arguments)`: the slice travels as two integer
// eightbytes.
private enum mainSignature = NativeSignature(
    Linkage.c,
    false, false, false, false, false,
    ArgumentPlan(
        [Register(Register.Kind.signed, 4), Register.init], 1, false),
    [NativeSignature.Parameter(ArgumentPlan(
        [
            Register(Register.Kind.integer, 8),
            Register(Register.Kind.integer, 8),
        ],
        2, false, 0, size_t.sizeof))],
);


private extern(C) void callMain(void* owner, CallbackCall* call) {
    auto run = cast(MainRun*) owner;
    const arguments = *cast(string[]*) call.arguments[0];
    *cast(int*) call.returnPlace = runMain(
        run.backend, *run.start, arguments);
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
private extern(C) int rt_term();
