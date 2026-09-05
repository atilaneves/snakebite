module snakebite.execution;


private:


public struct ExecutionReport {
    public int status;
    public imported!"core.time".Duration runTime;
    public imported!"snakebite.backends".CompilationStatistics compilation;
}


public struct PreparationReport {
    public imported!"snakebite.project".Project project;
    public imported!"core.time".Duration duration;
}


public PreparationReport prepareProject(
    in string directory,
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project: loadProject, sourceSet;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    // `duration` is the frontend's time and nothing else. Finding the
    // sources is not frontend work - for a dub project it is a series of
    // `dub describe` subprocesses, each of which also spawns the compiler
    // to identify it - and once counted here it inflated the reported
    // frontend time by up to half.
    auto sources = sourceSet(directory, importPaths, stringImportPaths);

    auto stopWatch = StopWatch(AutoStart.yes);
    initialize(Snippets.no);
    auto project = loadProject(directory, sources);
    return PreparationReport(project, stopWatch.peek);
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
