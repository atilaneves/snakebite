module snakebite.main;


extern(C) __gshared string[] rt_options = ["gcopt=cleanup:none"];


private:


public int main(string[] args) {
    import snakebite.cli: parseArgs;
    import snakebite.backends: BackendName;
    import snakebite.dub: fetchProject;
    import snakebite.execution: executeBackend, prepareProject;
    import std.file: exists, isDir;
    import std.stdio: stderr, write;

    const parsed = parseArgs(args);
    if (parsed.diagnostic.length)
        (parsed.status == 0 ? imported!"std.stdio".stdout : stderr)
            .write(parsed.diagnostic);
    if (parsed.status != 0 || parsed.options.showHelp)
        return parsed.status;

    try {
        string projectDirectory = parsed.options.projectDirectory;
        if (!projectDirectory.exists || !projectDirectory.isDir)
            projectDirectory = fetchProject(projectDirectory);
        auto preparation = prepareProject(
            projectDirectory,
            parsed.options.importPaths,
            parsed.options.stringImportPaths,
            parsed.options.backend != BackendName.ctfe,
            parsed.options.versions,
        );
        const report = executeBackend(
            parsed.options.backend,
            preparation.project.program,
            [preparation.project.program.name] ~ parsed.options.programArguments,
            false,
        );
        printStatistics(preparation, report);
        return report.status;
    } catch (Exception exception) {
        stderr.write("snakebite: ", exception.msg, "\n");
        return 1;
    }
}


private void printStatistics(
    in imported!"snakebite.execution".PreparationReport preparation,
    in imported!"snakebite.execution".ExecutionReport report,
) {
    import snakebite.execution: discoveryLabel;
    import std.stdio: writefln;

    // Two one-off costs before any backend runs: finding out what to run
    // the frontend on, then the frontend itself.
    writefln(
        "%-20s %8.1f ms",
        discoveryLabel(preparation) ~ ":",
        milliseconds(preparation.discovery),
    );
    writefln(
        "%-20s %8.1f ms",
        "frontend time:",
        milliseconds(preparation.duration),
    );
    writefln(
        "%-20s %8.1f ms",
        "image time:",
        milliseconds(preparation.imageDuration),
    );
    writefln(
        "%-20s %8.1f ms",
        "module constructors:",
        milliseconds(report.constructorDuration),
    );
    writefln(
        "%-20s %8.1f ms",
        "test registration:",
        milliseconds(report.activationDuration),
    );
    writefln(
        "%-20s %8.1f ms",
        "run time:",
        milliseconds(report.runTime),
    );
    if (report.compilation.hasCompiler)
        writefln(
            "%-20s %8.1f ms",
            "compile time:",
            milliseconds(report.compilation.duration),
        );
}


private double milliseconds(in imported!"core.time".Duration duration) {
    return duration.total!"hnsecs" / 10_000.0;
}
