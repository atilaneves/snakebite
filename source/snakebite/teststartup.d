module snakebite.teststartup;


private:


public struct TestStartupReport {
    import core.time: Duration;

    public int status;
    public Duration constructorDuration;
    public Duration activationDuration;
}


// Runs the unit tests and then `main` of `program` the way a compiled build
// does. The module constructors and destructors belong to druntime
// (`GuestModules`). `endsProcess` says that the process ends with this
// program: its own `rt_term` and `exit` then run the destructors, with the
// threads joined at the point druntime joins them. A caller that goes on
// running programs in one process has its destructors run before this returns.
public TestStartupReport runTestsAndMain(
    imported!"snakebite.backends.backend".Backend backend,
    imported!"snakebite.backends.backend".Program program,
    in string[] arguments,
    in bool endsProcess = false,
) {
    import snakebite.backends.backend: runMain;
    import snakebite.guestrunlock: guestRunLock;
    import snakebite.backends.guestmodules: GuestModules;
    import snakebite.dependencyimage: TestHooks;
    import snakebite.faultsignal: FaultHandlersOwner;
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

    auto modules = GuestModules.start(
        backend, program, GuestModules.Tests.yes,
        endsProcess ? GuestModules.Ends.process : GuestModules.Ends.program);
    TestStartupReport report;
    report.constructorDuration = modules.constructors;
    report.activationDuration = modules.preparation;
    if (modules.failed) {
        report.status = 1;
        return report;
    }

    _main = (string[] args) => runMain(backend, program, args);
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
    // `runModuleUnitTests` swaps the fault actions for its own. The watched
    // hooks put ours back before the runner starts, and this owner puts
    // them back after the call.
    scope FaultHandlersOwner handlers;
    report.status = _d_run_main(_runtimeCArgs.argc, cArguments.ptr, &callMain);
    if (modules.finish && report.status == 0)
        report.status = 1;
    if (watch.escaped)
        rt_term();
    return report;
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
private extern(C) int rt_term();
