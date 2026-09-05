module snakebite.execution;


private:


public struct ExecutionReport {
    public int status;
    public imported!"core.time".Duration runTime;
    public imported!"snakebite.backends".CompilationStatistics compilation;
}


public struct PreparationReport {
    public imported!"snakebite.project".Project project;
    // Finding out what to run the frontend on: `dub describe` for a dub
    // project, a directory scan otherwise.
    public imported!"core.time".Duration discovery;
    // The frontend itself: initialisation, parsing, semantic analysis.
    public imported!"core.time".Duration duration;
}


// What `PreparationReport.discovery` timed, for reports: dub itself for a
// dub project, a directory scan otherwise.
public string discoveryLabel(in PreparationReport report) {
    import snakebite.project: isDubProject;

    return isDubProject(report.project.directory)
        ? "dub overhead"
        : "source scan";
}


public PreparationReport prepareProject(
    in string directory,
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project: loadProject, sourceSet;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    // Two costs a user pays before any backend runs, timed apart: finding
    // the sources is not frontend work (for a dub project it is a `dub
    // describe` subprocess, which spawns the compiler too) and once counted
    // as frontend time it inflated that number by up to half.
    auto stopWatch = StopWatch(AutoStart.yes);
    auto sources = sourceSet(directory, importPaths, stringImportPaths);
    const discovery = stopWatch.peek;

    stopWatch.reset;
    initialize(Snippets.no);
    auto project = loadProject(directory, sources);
    return PreparationReport(project, discovery, stopWatch.peek);
}


public ExecutionReport executeBackend(
    in imported!"snakebite.backends".BackendName name,
    imported!"snakebite.backends".Program program,
) {
    import snakebite.backends: makeBackend;
    import snakebite.backends.backend: run;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    auto stopWatch = StopWatch(AutoStart.yes);
    scope backend = makeBackend(name, program);
    const status = run(backend, program);
    return ExecutionReport(
        status,
        stopWatch.peek,
        backend.compilationStatistics,
    );
}
