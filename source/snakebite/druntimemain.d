module snakebite.druntimemain;


private:


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
    imported!"snakebite.backends.backend".Backend backend,
    in imported!"snakebite.dependencyimage".TestHooks testHooks,
    in string[] arguments,
    in bool endsProcess = false,
) {
    import snakebite.backends.backend: runMain;
    import snakebite.guestrunlock: guestRunLock;
    import snakebite.backends.guestmodules: GuestModules;
    import snakebite.dependencyimage: TestHooks;
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
    auto start = &backend.startData(true);
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
    imported!"dmd.astenums".LINK.c,
    false, false, false, false, false,
    ArgumentPlan([Register(Register.Kind.signed, 4), Register.init], 1, false),
    [NativeSignature.Parameter(ArgumentPlan(
        [Register(Register.Kind.integer, 8), Register(Register.Kind.integer, 8)],
        2, false, 0, size_t.sizeof))],
);


private extern(C) void callMain(void* owner, CallbackCall* call) {
    import snakebite.backends.backend: runMain;

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
private import snakebite.backends.backend: Backend;
private import snakebite.backends.startdata: StartData;
private import snakebite.ffi.abi: ArgumentPlan, Register;
private import snakebite.ffi.callback: CallbackBridge, CallbackCall;
private import snakebite.ffi.plan: NativeSignature;
private alias MainFunction = extern(C) int function(char[][]);
private extern(C) int _d_run_main(
    int argc, char** argv, MainFunction main,
);
private extern(C) int rt_term();
