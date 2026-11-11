module snakebite.driver.execution;


private:


public struct ExecutionReport {
    import core.time: Duration;
    import snakebite.backends.statistics: CompilationStatistics;

    public int status;
    // Everything from making the backend to the end of the program. The
    // durations below do not overlap and do not include compilation.
    public Duration latency;
    public Duration constructorDuration;
    public Duration moduleInfoDuration;
    // The unit tests and `main`.
    public Duration programDuration;
    public CompilationStatistics compilation;
}


public struct PreparationReport {
    import core.time: Duration;
    import snakebite.project.loading: Project;

    public Project project;
    // Finding out what to run the frontend on: `dub describe` for a dub
    // project, a directory scan otherwise.
    public Duration discovery;
    // The frontend itself: initialisation, parsing, semantic analysis.
    public Duration duration;
    public Duration imageDuration;
}


// What `PreparationReport.discovery` timed, for reports: dub itself for a
// dub project, a directory scan otherwise.
public string discoveryLabel(in PreparationReport report) {
    import snakebite.project.loading: isDubProject;

    return isDubProject(report.project.directory)
        ? "dub ovrhd"
        : "src scan";
}


// Runs `body` the way `dub test` runs the project: the frontend in the
// project directory, where dub builds, and the guest in the working
// directory of the recipe, or the project directory when it names none.
// Every front end that runs a project's code goes through here, and none
// chooses a directory. The directory is state of the whole process, so only
// a front end, never a function that a test calls on a thread, may set it.
// Paths of the caller become absolute first: they are relative to where the
// caller is. `body` gets the absolute project directory and a function that
// enters the working directory: it calls it before each run of the guest.
// `EndsProcess.yes` leaves the directory in place: the module destructors of
// the program run when the process ends and see the directory that its
// constructors and `main` saw.
public int runProject(
    in string projectDirectory,
    in string[] callerImportPaths,
    in string[] callerStringImportPaths,
    in string[] versions,
    in imported!"snakebite.project.loading".EndsProcess endsProcess,
    in int delegate(
        string,
        imported!"snakebite.project.dub".SourceSet,
        imported!"core.time".Duration,
        void delegate(),
    ) body,
) {
    import snakebite.project.loading: ProjectDirectory, sourceSet;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.path: absolutePath;

    const directory = projectDirectory.absolutePath;
    const importPaths = callerImportPaths.map!(path => path.absolutePath).array;
    const stringImportPaths =
        callerStringImportPaths.map!(path => path.absolutePath).array;
    auto stopWatch = StopWatch(AutoStart.yes);
    auto sources = sourceSet(directory, importPaths, stringImportPaths, versions);
    const discovery = stopWatch.peek;
    scope entered = ProjectDirectory(
        directory,
        sources.workingDirectory.length ? sources.workingDirectory : directory,
        endsProcess,
    );
    return body(directory, sources, discovery, &entered.enterWorking);
}


// Does not change the working directory: `runProject` does.
public PreparationReport prepareProject(
    in string directory,
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
    in bool nativeDependencies = true,
    in string[] versions = null,
    in imported!"snakebite.image.preparation".Optimise optimise
        = imported!"snakebite.image.preparation".Optimise.yes,
) {
    import snakebite.project.loading: sourceSet;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    // Finding the sources is not frontend work (for a dub project it is the dub
    // library, which starts the compiler too) and once
    // counted as frontend time it inflated that number by up to half.
    auto stopWatch = StopWatch(AutoStart.yes);
    auto sources = sourceSet(directory, importPaths, stringImportPaths, versions);
    return prepareSources(
        directory, sources, stopWatch.peek, nativeDependencies, optimise,
    );
}


public PreparationReport prepareSources(
    in string directory,
    imported!"snakebite.project.dub".SourceSet sources,
    in imported!"core.time".Duration discovery,
    in bool nativeDependencies = true,
    in imported!"snakebite.image.preparation".Optimise optimise
        = imported!"snakebite.image.preparation".Optimise.yes,
) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project.loading: loadProject;
    import snakebite.project.dependencies: prepareDependencies;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    auto stopWatch = StopWatch(AutoStart.yes);
    initialize(Snippets.no);
    auto project = loadProject(directory, sources, nativeDependencies);
    const frontendDuration = stopWatch.peek;
    stopWatch.reset;
    if (nativeDependencies)
        project.program.dependencyImage = prepareDependencies(
            project.directory, project.sources, () => project.program,
            optimise,
        );
    if (project.program.dependencyImage !is null)
        project.program.testHooks = project.program.dependencyImage.testHooks;
    project.program.startsAsProject = true;
    return PreparationReport(project, discovery, frontendDuration, stopWatch.peek);
}


public ExecutionReport executeBackend(
    in imported!"snakebite.backends".BackendName name,
    imported!"snakebite.backends".Program program,
    in string[] hostArguments = null,
    in bool collectGarbage = true,
    in bool endsProcess = false,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit =
        imported!"snakebite.backends.bytecode.vm".JitSetting.init,
) {
    import snakebite.backends: makeBackend;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    import std.stdio: stdin, stdout, stderr;

    // Guest runners can replace thread-local streams. Host reports must
    // use the host's streams after execution, including exceptional exits.
    auto savedInput = stdin; // File references must remain mutable.
    auto savedOutput = stdout;
    auto savedError = stderr;
    scope(exit) {
        stdin = savedInput;
        stdout = savedOutput;
        stderr = savedError;
    }

    auto stopWatch = StopWatch(AutoStart.yes);
    auto backend = makeBackend(name, program, jit);
    import snakebite.backends.statistics: ExecutionClock;
    const running = ExecutionClock.start(backend.compilationStatistics);
    auto start = &backend.startData();
    return runStartData(
        *start, backend.compilationStatistics, running, stopWatch,
        program.testHooks, program.startsAsProject, hostArguments,
        collectGarbage, endsProcess);
}

// Runs the program of `start` and reports on it. `running` began before the
// backend made `start`, and `latency` before the backend was made. It takes
// no backend: whatever made `start` and `compilation`, compiled or loaded,
// can call it. `startsAsProject` false is a snippet. The function holds the
// `GuestModules.Entry` of `start` until it returns, as the runtime of a
// program with a C entry point ends with it.
ExecutionReport runStartData(
    ref imported!"snakebite.start.data".StartData start,
    ref const imported!"snakebite.backends.statistics".CompilationStatistics
        compilation,
    in imported!"snakebite.backends.statistics".ExecutionClock running,
    ref imported!"std.datetime.stopwatch".StopWatch latency,
    in imported!"snakebite.image.dependency".TestHooks testHooks,
    in bool startsAsProject,
    in string[] hostArguments,
    in bool collectGarbage,
    in bool endsProcess,
) {
    import core.memory: GC;
    import snakebite.run.modules: GuestModules;
    import snakebite.run.program: run, StartupReport, runDruntimeMain;

    const entry = GuestModules.Entry(start, compilation);
    StartupReport startup;
    int status;
    // A program with a C `main` is not started as a project either.
    if (!startsAsProject || start.hasCEntryPoint || start.betterC)
        status = run(start, compilation, hostArguments);
    else {
        startup = runDruntimeMain(
            start, compilation, testHooks, hostArguments, endsProcess);
        status = startup.status;
    }
    const programDuration = running.peek
        - startup.constructorDuration - startup.moduleInfoDuration;
    // Native objects can hold callback entries for guest destructors. Run
    // their finalizers while the backend and the frontend declarations that
    // those entries name are still alive.
    if (collectGarbage)
        GC.collect;
    return ExecutionReport(
        status,
        latency.peek,
        startup.constructorDuration,
        startup.moduleInfoDuration,
        programDuration,
        compilation,
    );
}
