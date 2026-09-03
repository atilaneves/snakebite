module snakebite.main;


private:


public int main(string[] args) {
    import snakebite.cli: parseArgs;
    import snakebite.execution: executeBackend, prepareProject;
    import std.stdio: stderr, write;

    const parsed = parseArgs(args);
    if (parsed.diagnostic.length)
        (parsed.status == 0 ? imported!"std.stdio".stdout : stderr)
            .write(parsed.diagnostic);
    if (parsed.status != 0 || parsed.options.showHelp)
        return parsed.status;

    try {
        auto preparation = prepareProject(
            parsed.options.projectDirectory,
            parsed.options.importPaths,
            parsed.options.stringImportPaths,
        );
        const report = executeBackend(
            parsed.options.backend,
            preparation.project.program,
        );
        printStatistics(preparation.duration, report);
        return report.status;
    } catch (Exception exception) {
        stderr.write("snakebite: ", exception.msg, "\n");
        return 1;
    }
}


private void printStatistics(
    in imported!"core.time".Duration frontendDuration,
    in imported!"snakebite.execution".ExecutionReport report,
) {
    import std.stdio: writefln;

    writefln("frontend time: %8.1f ms", milliseconds(frontendDuration));
    writefln("run time:      %8.1f ms", milliseconds(report.runTime));
    if (report.compilation.hasCompiler)
        writefln(
            "compile time:  %8.1f ms",
            milliseconds(report.compilation.duration),
        );
}


private double milliseconds(in imported!"core.time".Duration duration) {
    return duration.total!"hnsecs" / 10_000.0;
}
