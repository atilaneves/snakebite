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


public PreparationReport prepareProject(
    in string directory,
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
    in bool nativeDependencies = true,
    in string[] versions = null,
) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project:
        loadProject, projectStateDirectory, sourceSet, prepareDependencies;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import snakebite.teststartup: prepareTestStartup;
    import snakebite.dependencyimage: DependencyImage;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.string: fromStringz;

    // Two costs a user pays before any backend runs, timed apart: finding
    // the sources is not frontend work (for a dub project it is a `dub
    // describe` subprocess, which spawns the compiler too) and once counted
    // as frontend time it inflated that number by up to half.
    auto stopWatch = StopWatch(AutoStart.yes);
    auto sources = sourceSet(directory, importPaths, stringImportPaths, versions);
    const discovery = stopWatch.peek;

    stopWatch.reset;
    initialize(Snippets.no);
    auto project = loadProject(directory, sources);
    const stateDirectory = projectStateDirectory(project.directory);
    const frontendDuration = stopWatch.peek;
    stopWatch.reset;
    if (nativeDependencies)
        prepareDependencies(project);
    if (project.program.dependencyImage !is null)
        project.program.testHooks = project.program.dependencyImage.testHooks;
    auto startupImage = new DependencyImage;
    *startupImage = prepareTestStartup(stateDirectory,
        project.program.rootModules.map!(module_ =>
            module_.toPrettyChars.fromStringz.idup).array);
    project.program.testStartupImage = startupImage;
    return PreparationReport(project, discovery, frontendDuration, stopWatch.peek);
}


public ExecutionReport executeBackend(
    in imported!"snakebite.backends".BackendName name,
    imported!"snakebite.backends".Program program,
    in string[] hostArguments = null,
    in bool collectGarbage = true,
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
    scope backend = makeBackend(name, program);
    TestStartupReport startup;
    int status;
    // Snippet callers construct Programs without project startup metadata.
    if (program.testStartupImage is null)
        status = run(backend, program, hostArguments);
    else {
        startup = runTestsAndMain(backend, program, hostArguments);
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
