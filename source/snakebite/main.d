module snakebite.main;


private:


public int main(string[] args) {
    import snakebite.cli: parseArgs;
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project: loadProject;
    import std.stdio: stderr, write;

    const parsed = parseArgs(args);
    if (parsed.diagnostic.length)
        (parsed.status == 0 ? imported!"std.stdio".stdout : stderr)
            .write(parsed.diagnostic);
    if (parsed.status != 0 || parsed.options.showHelp)
        return parsed.status;

    initialize(Snippets.no);

    try {
        auto project = loadProject(
            parsed.options.projectDirectory,
            parsed.options.importPaths,
            parsed.options.stringImportPaths,
        );
        const report = runBackend(parsed.options.backend, project.program);
        printStatistics(report);
        return report.status;
    } catch (Exception exception) {
        stderr.write("snakebite: ", exception.msg, "\n");
        return 1;
    }
}


private struct RunReport {
    int status;
    imported!"core.time".Duration runTime;
    imported!"snakebite.backends".CompilationStatistics compilation;
}


private RunReport runBackend(
    in string name,
    imported!"snakebite.backends".Program program,
) {
    import snakebite.backends.backend: run;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    static foreach (BackendType; imported!"snakebite.backends".Backends) {
        if (name == backendName!BackendType) {
            auto backend = new BackendType(program);
            auto stopWatch = StopWatch(AutoStart.yes);
            const status = run(backend, program);
            return RunReport(
                status,
                stopWatch.peek,
                backend.compilationStatistics,
            );
        }
    }

    assert(false, "backend name was validated by parseArgs");
}


private void printStatistics(in RunReport report) {
    import std.stdio: writefln, writeln;

    writefln("run time:     %.1f ms", milliseconds(report.runTime));
    if (report.compilation.hasCompiler)
        writefln(
            "compile time: %.1f ms",
            milliseconds(report.compilation.duration),
        );
    else
        writeln("compile time: n/a");
}


private double milliseconds(in imported!"core.time".Duration duration) {
    return duration.total!"hnsecs" / 10_000.0;
}


private enum backendName(BackendType) =
    imported!"std.uni".toLower(BackendType.stringof);
