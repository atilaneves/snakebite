module ut.project;


import core.atomic: atomicLoad, atomicOp;
import core.runtime: UnitTestResult;
import core.sync.barrier: Barrier;
import core.sync.mutex: Mutex;
import core.stdc.errno: EINVAL, errno;
import core.stdc.signal: raise;
import core.sys.posix.signal:
    SA_RESETHAND, SIG_BLOCK, SIG_DFL, SIG_IGN, SIGBUS, SIGFPE, SIGSEGV,
    sigaction, sigaction_t, sigismember, sigprocmask, sigset_t;
import core.thread: Thread;
import snakebite.backends: BackendName, backendIdentity;
import snakebite.backends.backend: Program;
import snakebite.backends.guestfault: GuestFault, GuestFaultException;
import snakebite.dependencyimage: TestHooks;
import snakebite.execution: prepareProject, executeBackend;
import snakebite.dub: DubDescription;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;
import snakebite.guestrunlock: guestRunLock;
import snakebite.project: dubSourceSetFromDescription, projectStateDirectory;
import std.algorithm.searching: endsWith;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.file: getcwd;
import std.path: absolutePath, buildNormalizedPath, buildPath, dirName;
import ut;
import ut.backends;


@("stateDirectoryIsCwdScopedAndProjectPartitioned")
unittest {
    const cwd = getcwd;
    const firstProject = "projects/first".absolutePath.buildNormalizedPath;
    const secondProject = "projects/second".absolutePath.buildNormalizedPath;
    const first = projectStateDirectory("projects/first");
    const second = projectStateDirectory("projects/second");

    first.should == buildPath(cwd, ".snakebite",
        firstProject.sha256Of.toHexString.idup);
    second.should == buildPath(cwd, ".snakebite",
        secondProject.sha256Of.toHexString.idup);
    first.should.not == second;
}


@("sourceSet.loadsPackageRecordsWithoutTargets")
unittest {
    import std.json: parseJSON;

    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings").absolutePath;
    auto description = DubDescription(parseJSON(`{
        "rootPackage": "root",
        "configuration": "unittest",
        "targets": [],
        "packages": [
            {
                "name": "root", "configuration": "unittest",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "tests/main.d"}],
                "importPaths": ["source"], "stringImportPaths": [],
                "linkerFiles": [], "dflags": [], "debugVersions": [],
                "options": [], "versions": [], "lflags": [], "libs": []
            },
            {
                "name": "dependency", "configuration": "library",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "source/package.d"}],
                "importPaths": ["source"], "stringImportPaths": []
            }
        ]
    }`));

    const sources = dubSourceSetFromDescription(directory, description);

    sources.files.length.should == 1;
    sources.files[0].endsWith("tests/main.d").should == true;
    sources.importPaths.length.should == 2;
}


// dub turns `-release`, `-noboundscheck` and `-betterC` into options of the
// package and takes them out of `dflags`, so the flags reach the program from
// the options.
@("sourceSet.dubOptionsBecomeFlags")
unittest {
    import std.json: parseJSON;

    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings").absolutePath;
    auto description = DubDescription(parseJSON(`{
        "rootPackage": "root",
        "configuration": "unittest",
        "targets": [],
        "packages": [
            {
                "name": "root", "configuration": "unittest",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "tests/main.d"}],
                "importPaths": ["source"], "stringImportPaths": [],
                "linkerFiles": [], "dflags": [], "debugVersions": [],
                "options": ["releaseMode", "noBoundsCheck", "betterC"],
                "versions": [], "lflags": [], "libs": []
            }
        ]
    }`));

    const sources = dubSourceSetFromDescription(directory, description);

    sources.flags.compilerArguments.should == [
        "-release", "-noboundscheck", "-betterC",
    ];
}


// druntime's own `rt_init`/`rt_term` nesting depth.
pragma(mangle, "_D2rt6dmain210_initCountOm")
private extern shared size_t runtimeInitDepth;

private Program _innerProgram;
private BackendName _nestedBackend;
private extern(C) int rt_init();
private extern(C) int rt_term();

private UnitTestResult throwingInnerRunner() {
    throw new Exception("inner runner failed");
}

private UnitTestResult successfulOuterRunner() {
    executeBackend(_nestedBackend, _innerProgram, null, false).status.should == 1;
    return UnitTestResult(1, 1, false, false);
}

private __gshared Mutex _initDepthLock;

shared static this() {
    _initDepthLock = new Mutex;
}

// A handled inner runner failure must not terminate the outer runtime. The
// variants of this test change druntime's nesting depth, so they take turns.
static foreach (backend; Matrix!()) {
    @("runtime.nestedRunnerKeepsInitDepth." ~ backend.stringof)
    unittest {
        {
            _initDepthLock.lock;
            scope(exit) _initDepthLock.unlock;

            static if (is(backend == Native)) {
                rt_init;
                const depth = atomicLoad(runtimeInitDepth);
                rt_init;
                rt_term;
                atomicLoad(runtimeInitDepth).should == depth;
                rt_term;
            } else {
                const sandbox = Sandbox();
                sandbox.writeFile("outer/outer.d", "module outer; int main() { return 0; }");
                sandbox.writeFile("inner/inner.d", "module inner; int main() { return 0; }");
                auto outer = prepareProject(sandbox.inSandboxPath("outer")).project.program;
                _innerProgram = prepareProject(sandbox.inSandboxPath("inner")).project.program;
                _nestedBackend = backendIdentity!backend;
                _innerProgram.testHooks = TestHooks.of(null, &throwingInnerRunner);
                outer.testHooks = TestHooks.of(null, &successfulOuterRunner);
                rt_init;
                const depth = atomicLoad(runtimeInitDepth);
                scope(exit) {
                    while (atomicLoad(runtimeInitDepth) < depth)
                        rt_init;
                    rt_term;
                }
                executeBackend(_nestedBackend, outer, null, false).status.should == 0;
                atomicLoad(runtimeInitDepth).should == depth;
            }
        }
    }
}


// While druntime runs the tests of a program, it swaps the actions of the
// fault signals for its own. The kernel must go on delivering guest faults
// to us, on every thread, with a runner hook and with several runs at once.
private alias FaultingGuests = Matrix!(
    Omit!(Native, Because.inexpressible,
        "the test catches the fault of a call on a backend object, and the "
        ~ "Native arm is code compiled into bin/ut with no such object"),
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter reports a null dereference as a diagnostic and "
        ~ "raises no GuestFaultException"),
);

// Calls a guest function that dereferences null on this thread, and
// returns whether the fault came back as a `GuestFaultException`.
private bool guestFaultReported(BackendType)() {
    auto module_ = parseSnippets([q{
        module runnerFault;
        int fail() { int* pointer; return *pointer; }
    }])[0];
    auto backend = new BackendType(Program([module_]));
    int result;
    try
        backend.call(module_.findFunction("fail"), &result, []);
    catch (GuestFaultException fault)
        return fault.kind == GuestFault.Kind.nullDereference;
    return false;
}

private bool guestFaultReportedOnAnotherThread(BackendType)() {
    bool reported;
    auto faulter = new Thread({ reported = guestFaultReported!BackendType; }).start;
    faulter.join;
    return reported;
}

private template RunnerProbe(BackendType) {
    __gshared bool reported;

    UnitTestResult runner() {
        reported = guestFaultReportedOnAnotherThread!BackendType;
        return UnitTestResult(1, 1, false, false);
    }
}

// The runs below change druntime's nesting depth, so they take turns with
// the test above and with each other.
static foreach (BackendType; FaultingGuests) {
    @Tags(BackendType.stringof)
    @("runtime.guestFaultOnAnotherThreadWhileARunnerIsActive." ~ BackendType.stringof)
    unittest {
        _initDepthLock.lock;
        scope(exit) _initDepthLock.unlock;

        const sandbox = Sandbox();
        sandbox.writeFile("app/app.d", "module app; int main() { return 0; }");
        auto program = prepareProject(sandbox.inSandboxPath("app")).project.program;
        program.testHooks = TestHooks.of(null, &RunnerProbe!BackendType.runner);

        executeBackend(backendIdentity!BackendType, program, null, false).status.should == 0;

        RunnerProbe!BackendType.reported.shouldBeTrue;
    }
}


// What the kernel delivers for a signal, not what `sigaction` reports: a
// program can intercept that call.
private struct KernelAction {
    ulong handler;
    ulong flags;
    ulong restorer;
    ulong mask;
}

private extern(C) long syscall(long number, ...) nothrow @nogc;

private KernelAction kernelAction(int signal) {
    enum rtSigaction = 13;
    enum kernelMaskSize = 8;
    KernelAction action;
    syscall(rtSigaction, signal, null, &action, kernelMaskSize).should == 0;
    return action;
}

private immutable int[3] faultSignals = [SIGSEGV, SIGBUS, SIGFPE];

private __gshared KernelAction[3] _actionsInsideRunner;

private UnitTestResult recordingRunner() {
    foreach (index, signal; faultSignals)
        _actionsInsideRunner[index] = kernelAction(signal);
    return UnitTestResult(1, 1, false, false);
}

// The first code that a runner hook runs is the earliest point at which a
// test can look. The default loop of druntime has no hook to look from, and
// it runs after the same `sigaction` calls.
static foreach (backend; Matrix!()) {
    @("runtime.faultSignalActionsAreUnchangedWhileDruntimeRunsTests." ~ backend.stringof)
    unittest {
        _initDepthLock.lock;
        scope(exit) _initDepthLock.unlock;

        const sandbox = Sandbox();
        sandbox.writeFile("app/app.d", "module app; int main() { return 0; }");
        auto program = prepareProject(sandbox.inSandboxPath("app")).project.program;
        program.testHooks = TestHooks.of(null, &recordingRunner);
        KernelAction[3] before;
        foreach (index, signal; faultSignals)
            before[index] = kernelAction(signal);

        executeBackend(backendIdentity!backend, program, null, false).status.should == 0;

        foreach (index; 0 .. faultSignals.length) {
            _actionsInsideRunner[index].should == before[index];
            (_actionsInsideRunner[index].flags & SA_RESETHAND).should == 0;
        }
        _actionsInsideRunner[0].handler.should.not == 0;
    }
}


pragma(mangle, "_D2rt6dmain27_d_argsAAya")
private extern __gshared string[] _runtimeArgs;
pragma(mangle, "_D2rt6dmain26_cArgsSQsQr5CArgs")
private extern __gshared imported!"core.runtime".CArgs _runtimeCArgs;
private alias MainFunction = extern(C) int function(char[][]);
private extern(C) int _d_run_main(int argc, char** argv, MainFunction main);
private extern(C) int noMain(char[][]) { return 0; }

private template OverlapProbe(BackendType) {
    __gshared Barrier barrier;
    shared size_t reported;

    UnitTestResult runner() {
        // Both threads are now inside `runModuleUnitTests`, after the
        // `sigaction` calls of both.
        barrier.wait;
        if (guestFaultReported!BackendType)
            atomicOp!"+="(reported, 1);
        return UnitTestResult(1, 1, false, false);
    }

    // The arguments outlive the runs: druntime keeps the pointer in its
    // own state, and another thread that loads a library reads it.
    __gshared char*[2] argv;

    void runMain() {
        _d_run_main(1, argv.ptr, &noMain);
    }
}

// `_d_run_main` called on two threads at once: each saves the action that
// is in force when it starts, and restores it when it ends.
static foreach (BackendType; FaultingGuests) {
    @Tags(BackendType.stringof)
    @("runtime.guestFaultsAreRecoveredWhileTwoDruntimeRunsOverlap." ~ BackendType.stringof)
    unittest {
        _initDepthLock.lock;
        scope(exit) _initDepthLock.unlock;
        // The hooks and the arguments of druntime belong to one run at a
        // time, as in `executeBackend`.
        guestRunLock.lock;
        scope(exit) guestRunLock.unlock;

        const savedHooks = TestHooks.current;
        auto savedArgs = _runtimeArgs;
        auto savedCArgs = _runtimeCArgs;
        scope(exit) {
            savedHooks.install;
            _runtimeArgs = savedArgs;
            _runtimeCArgs = savedCArgs;
        }
        alias Probe = OverlapProbe!BackendType;
        Probe.barrier = new Barrier(2);
        Probe.reported = 0;
        Probe.argv[0] = cast(char*) "overlap\0".ptr;
        TestHooks.of(null, &Probe.runner).install;
        const before = kernelAction(SIGSEGV);

        auto first = new Thread(&Probe.runMain).start;
        auto second = new Thread(&Probe.runMain).start;
        first.join;
        second.join;

        // One fault on each thread, while both runs were active.
        atomicLoad(Probe.reported).should == 2;
        kernelAction(SIGSEGV).should == before;
        guestFaultReportedOnAnotherThread!BackendType.shouldBeTrue;
    }
}


// A guest that leaves a Fiber suspended leaves its mark on the thread. The
// host that runs on that thread afterwards is not the guest, and druntime
// must not take the kernel action from us for it.
static foreach (BackendType; FaultingGuests) {
    @Tags(BackendType.stringof)
    @("runtime.faultSignalActionsAreUnchangedAfterAGuestLeavesAFiberSuspended." ~ BackendType.stringof)
    unittest {
        _initDepthLock.lock;
        scope(exit) _initDepthLock.unlock;

        const sandbox = Sandbox();
        sandbox.writeFile("app/app.d", "module app; int main() { return 0; }");
        auto program = prepareProject(sandbox.inSandboxPath("app")).project.program;
        program.testHooks = TestHooks.of(null, &recordingRunner);
        KernelAction[3] before;
        foreach (index, signal; faultSignals)
            before[index] = kernelAction(signal);

        // A thread of its own: the mark stays on it until the Fiber ends.
        auto worker = new Thread({
            auto module_ = parseSnippets([q{
                module suspended;
                import core.thread.fiber: Fiber;
                __gshared Fiber kept;
                int leave() { kept = new Fiber({ Fiber.yield(); }); kept.call; return 1; }
                int finish() { kept.call; return 2; }
            }])[0];
            auto backend = new BackendType(Program([module_]));
            int result;
            backend.call(module_.findFunction("leave"), &result, []);

            executeBackend(backendIdentity!BackendType, program, null, false).status.should == 0;

            foreach (index; 0 .. faultSignals.length)
                _actionsInsideRunner[index].should == before[index];
            guestFaultReported!BackendType.shouldBeTrue;
            backend.call(module_.findFunction("finish"), &result, []);
        }).start;
        worker.join;
    }
}


// A guest can install a handler of its own and read it back, and it never
// reaches the kernel: a fault of the guest on another thread, while the
// action of the guest is in force, must still come back as an exception.
static foreach (BackendType; FaultingGuests) {
    @Tags(BackendType.stringof)
    @("runtime.guestSigactionIsRecordedAndNeverReachesTheKernel." ~ BackendType.stringof)
    unittest {
        auto module_ = parseSnippets([q{
            module installer;
            import core.sys.posix.signal;
            int install() {
                sigaction_t action;
                action.sa_flags = SA_RESETHAND;
                if (sigaction(SIGSEGV, &action, null) != 0)
                    return -1;
                sigaction_t current;
                if (sigaction(SIGSEGV, null, &current) != 0)
                    return -2;
                return (current.sa_flags & SA_RESETHAND) != 0 ? 1 : 0;
            }
        }])[0];
        auto backend = new BackendType(Program([module_]));
        const before = kernelAction(SIGSEGV);
        int result;

        backend.call(module_.findFunction("install"), &result, []);

        result.should == 1;
        kernelAction(SIGSEGV).should == before;
        guestFaultReportedOnAnotherThread!BackendType.shouldBeTrue;
        guestFaultReported!BackendType.shouldBeTrue;
    }
}


private alias HandlerSetter = extern(C) void* function(int, void*) nothrow @nogc;
private alias Ignorer = extern(C) int function(int) nothrow @nogc;
private alias Interrupter = extern(C) int function(int, int) nothrow @nogc;
private alias VectorSetter = extern(C) int function(int, const(SigVec)*, SigVec*) nothrow @nogc;

private struct SigVec {
    void* handler;
    int mask;
    int flags;
}

// By name at run time, as a native library that a guest loads would: the
// linker does not offer every one of these.
private auto symbolNamed(Function)(in string name) {
    import core.sys.posix.dlfcn: dlsym;
    import std.string: toStringz;

    auto address = dlsym(null, name.toStringz);
    address.shouldNotBeNull;
    return cast(Function) address;
}

// Puts back the action that `sigaction` reports, so that a test that
// changes it does not leave its request to the host faults of other tests.
private struct ReportedActions {
    import core.sys.posix.signal: sigaction, sigaction_t;

    sigaction_t[3] saved;

    @disable this(this);

    this(int) {
        foreach (index, signal; faultSignals)
            sigaction(signal, null, &saved[index]);
    }

    ~this() {
        foreach (index, signal; faultSignals)
            sigaction(signal, &saved[index], null);
    }
}

// `signal` and the other functions that glibc has for the same job call an
// internal `sigaction`, not the symbol, so they need their own definitions.
static foreach (BackendType; FaultingGuests) {
    @Tags(BackendType.stringof)
    @("runtime.signalFunctionsNeverChangeTheKernelActionOfTheFaultSignals." ~ BackendType.stringof)
    unittest {
        auto module_ = parseSnippets([q{
            module signaller;
            import core.sys.posix.signal: SIG_DFL, SIGSEGV;
            extern(C) void* signal(int, void*);
            int reset() { signal(SIGSEGV, null); return 1; }
        }])[0];
        auto backend = new BackendType(Program([module_]));
        const restore = ReportedActions(0);
        KernelAction[3] before;
        foreach (index, signal; faultSignals)
            before[index] = kernelAction(signal);

        foreach (signal; faultSignals) {
            foreach (name; ["signal", "bsd_signal", "__sysv_signal", "sysv_signal",
                            "ssignal", "sigset"])
                symbolNamed!HandlerSetter(name)(signal, null);
            symbolNamed!Ignorer("sigignore")(signal);
            symbolNamed!Interrupter("siginterrupt")(signal, 1);
            const SigVec vector = {null, 0, 4};
            symbolNamed!VectorSetter("sigvec")(signal, &vector, null);
        }
        int result;
        backend.call(module_.findFunction("reset"), &result, []);

        foreach (index, signal; faultSignals)
            kernelAction(signal).should == before[index];
        guestFaultReportedOnAnotherThread!BackendType.shouldBeTrue;
    }
}


// Runs `body` on a thread that is not running guest code, with the actions
// that `sigaction` reports put back at the end.
private void onHostThread(in void delegate() body_) {
    _initDepthLock.lock;
    scope(exit) _initDepthLock.unlock;

    const restore = ReportedActions(0);
    auto thread = new Thread({ body_(); }).start;
    thread.join;
}

// Each user of a handler counts on its own, because tests run in parallel.
private template Counting(string owner) {
    shared int delivered;

    extern(C) void handler(int) nothrow @nogc {
        atomicOp!"+="(delivered, 1);
    }
}

private alias countingHandler = Counting!"host".handler;

private sigaction_t handledBy(void* handler, int flags) {
    sigaction_t action;
    action.sa_handler = cast(typeof(action.sa_handler)) handler;
    action.sa_flags = flags;
    return action;
}

// A signal that the program sent (`raise`) has no instruction to run again,
// so it is delivered to the action that the program recorded.
@("runtime.hostSignalGoesToTheRecordedAction")
unittest {
    onHostThread({
        const action = handledBy(&countingHandler, 0);
        sigaction(SIGSEGV, &action, null);
        const kernel = kernelAction(SIGSEGV);
        const before = atomicLoad(Counting!"host".delivered);

        raise(SIGSEGV);

        atomicLoad(Counting!"host".delivered).should == before + 1;
        kernelAction(SIGSEGV).should == kernel;
    });
}

@("runtime.hostOneShotActionRunsOnceThenReadsBackAsDefault")
unittest {
    onHostThread({
        const action = handledBy(&countingHandler, SA_RESETHAND);
        sigaction(SIGSEGV, &action, null);
        const before = atomicLoad(Counting!"host".delivered);

        raise(SIGSEGV);

        atomicLoad(Counting!"host".delivered).should == before + 1;
        sigaction_t reported;
        sigaction(SIGSEGV, null, &reported);
        (cast(void*) reported.sa_handler).should == cast(void*) SIG_DFL;
    });
}

@("runtime.hostSignalIsIgnoredWhenTheRecordedActionIgnoresIt")
unittest {
    onHostThread({
        const action = handledBy(cast(void*) SIG_IGN, 0);
        sigaction(SIGSEGV, &action, null);

        raise(SIGSEGV);
    });
}

// The one delivery of a one-shot action of a guest is used up by the first
// fault. The fault that the handler returns to is the guest's own error.
static foreach (BackendType; FaultingGuests) {
    @Tags(BackendType.stringof)
    @("runtime.guestOneShotHandlerRunsOnceThenTheFaultIsRecovered." ~ BackendType.stringof)
    unittest {
        auto module_ = parseSnippets([q{
            module oneShot;
            import core.sys.posix.signal;
            int run(void* handler) {
                sigaction_t action;
                action.sa_handler = cast(typeof(action.sa_handler)) handler;
                action.sa_flags = SA_RESETHAND;
                sigaction(SIGSEGV, &action, null);
                int* pointer;
                return *pointer;
            }
        }])[0];
        auto backend = new BackendType(Program([module_]));
        void* handler = &Counting!(BackendType.stringof).handler;
        const before = atomicLoad(Counting!(BackendType.stringof).delivered);
        int result;
        GuestFault.Kind kind;

        try
            backend.call(module_.findFunction("run"), &result, [&handler]);
        catch (GuestFaultException fault)
            kind = fault.kind;

        atomicLoad(Counting!(BackendType.stringof).delivered).should == before + 1;
        kind.should == GuestFault.Kind.nullDereference;
    }
}


private alias RawSigaction = extern(C) int function(int, const(sigaction_t)*, sigaction_t*) nothrow @nogc;

@("runtime.underscoreSigactionRecordsLikeSigaction")
unittest {
    onHostThread({
        const action = handledBy(&countingHandler, 0);
        symbolNamed!RawSigaction("__sigaction")(SIGSEGV, &action, null).should == 0;
        sigaction_t reported;

        sigaction(SIGSEGV, null, &reported).should == 0;

        (cast(void*) reported.sa_handler).should == cast(void*) &countingHandler;
    });
}

@("runtime.signalFunctionsFailForASignalNumberThatDoesNotExist")
unittest {
    enum noSuchSignal = 1000;
    enum sigError = cast(void*) -1;
    onHostThread({
        foreach (name; ["signal", "bsd_signal", "__sysv_signal", "sysv_signal",
                        "ssignal", "sigset"]) {
            errno = 0;
            symbolNamed!HandlerSetter(name)(noSuchSignal, null).should == sigError;
            errno.should == EINVAL;
        }
        symbolNamed!Ignorer("sigignore")(noSuchSignal).should == -1;
        symbolNamed!Interrupter("siginterrupt")(noSuchSignal, 1).should == -1;
        const SigVec vector = {null, 0, 0};
        symbolNamed!VectorSetter("sigvec")(noSuchSignal, &vector, null).should == -1;
        // `SIG_HOLD` reads the action first.
        enum sigHold = cast(void*) 2;
        symbolNamed!HandlerSetter("sigset")(noSuchSignal, sigHold).should == sigError;
    });
}

@("runtime.signalFunctionsRejectTheErrorValueAsAHandler")
unittest {
    enum sigError = cast(void*) -1;
    onHostThread({
        errno = 0;
        symbolNamed!HandlerSetter("signal")(SIGSEGV, sigError).should == sigError;
        errno.should == EINVAL;
    });
}

@("runtime.sigsetHoldBlocksTheSignalAndReportsIt")
unittest {
    enum sigHold = cast(void*) 2;
    onHostThread({
        auto sigset = symbolNamed!HandlerSetter("sigset");
        sigset(SIGFPE, cast(void*) &countingHandler);
        scope(exit) sigset(SIGFPE, cast(void*) SIG_DFL);

        sigset(SIGFPE, sigHold).should == cast(void*) &countingHandler;
        sigset_t mask;
        sigprocmask(SIG_BLOCK, null, &mask);
        sigismember(&mask, SIGFPE).should == 1;
        sigset(SIGFPE, sigHold).should == sigHold;
        sigset(SIGFPE, cast(void*) &countingHandler).should == sigHold;
        sigprocmask(SIG_BLOCK, null, &mask);
        sigismember(&mask, SIGFPE).should == 0;
    });
}

@("runtime.siginterruptSwitchesRestartOfTheRecordedAction")
unittest {
    import core.sys.posix.signal: SA_RESTART;
    onHostThread({
        const action = handledBy(&countingHandler, 0);
        sigaction(SIGSEGV, &action, null);
        sigaction_t reported;

        symbolNamed!Interrupter("siginterrupt")(SIGSEGV, 0).should == 0;
        sigaction(SIGSEGV, null, &reported);
        (reported.sa_flags & SA_RESTART).should.not == 0;

        symbolNamed!Interrupter("siginterrupt")(SIGSEGV, 1).should == 0;
        sigaction(SIGSEGV, null, &reported);
        (reported.sa_flags & SA_RESTART).should == 0;
    });
}

@("runtime.sigvecReportsTheRecordedAction")
unittest {
    enum interrupt = 2, resetHand = 4;
    onHostThread({
        const SigVec vector = {cast(void*) &countingHandler, 0, resetHand | interrupt};
        SigVec reported;

        symbolNamed!VectorSetter("sigvec")(SIGSEGV, &vector, null).should == 0;
        symbolNamed!VectorSetter("sigvec")(SIGSEGV, null, &reported).should == 0;

        reported.handler.should == cast(void*) &countingHandler;
        reported.flags.should == (resetHand | interrupt);
    });
}
