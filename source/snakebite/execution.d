module snakebite.execution;


private:


public struct ExecutionReport {
    import core.time: Duration;
    import snakebite.backends: CompilationStatistics;

    public int status;
    public Duration runTime;
    public Duration constructorDuration;
    public Duration activationDuration;
    public CompilationStatistics compilation;
}


public struct PreparationReport {
    import core.time: Duration;
    import snakebite.project: Project;

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
    import snakebite.project: isDubProject;

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
    in imported!"snakebite.project".EndsProcess endsProcess,
    in int delegate(
        string,
        imported!"snakebite.project".SourceSet,
        imported!"core.time".Duration,
        void delegate(),
    ) body,
) {
    import snakebite.project: ProjectDirectory, sourceSet;
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
    in imported!"snakebite.dependencyimage".Optimise optimise
        = imported!"snakebite.dependencyimage".Optimise.yes,
) {
    import snakebite.project: sourceSet;
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
    imported!"snakebite.project".SourceSet sources,
    in imported!"core.time".Duration discovery,
    in bool nativeDependencies = true,
    in imported!"snakebite.dependencyimage".Optimise optimise
        = imported!"snakebite.dependencyimage".Optimise.yes,
) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project: loadProject, prepareDependencies;
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
) {
    import snakebite.backends: makeBackend;
    import snakebite.backends.backend: run;
    import snakebite.teststartup: TestStartupReport, runTestsAndMain;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import core.memory: GC;

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
    auto backend = makeBackend(name, program);
    import snakebite.backends.guestmodules: GuestModules;
    const entry = GuestModules.Entry(backend, program);
    TestStartupReport startup;
    int status;
    // Snippet callers construct Programs that do not start as a project,
    // and a program with a C `main` is not started as a project either.
    if (!program.startsAsProject || program.hasCEntryPoint || program.checks.betterC)
        status = run(backend, program, hostArguments);
    else {
        startup = runTestsAndMain(
            backend, program, hostArguments, endsProcess);
        status = startup.status;
    }
    // Native objects can hold callback entries for guest destructors. Run
    // their finalizers while the backend and the frontend declarations that
    // those entries name are still alive.
    if (collectGarbage)
        GC.collect;
    return ExecutionReport(
        status,
        stopWatch.peek,
        startup.constructorDuration,
        startup.activationDuration,
        backend.compilationStatistics,
    );
}
