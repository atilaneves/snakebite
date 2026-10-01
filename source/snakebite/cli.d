module snakebite.cli;


private:


public struct Options {
    import snakebite.backends: BackendName;

    public BackendName backend;
    public string[] importPaths;
    public string[] stringImportPaths;
    public string[] versions;
    public string projectDirectory;
    public string[] programArguments;
    public bool showHelp;
    // Real `bin/sb` use keeps optimisation: a guest run pays the image's
    // run time, not just its build time. This flag trades that away for
    // faster image builds, for a caller that only checks behaviour.
    public bool noOptimiseImage;
    public bool lowmem;
}


// `bin/sb`: run a project's unit tests and its `main` on one backend.
public int run(string[] args) {
    import snakebite.backends: BackendName;
    import snakebite.dependencyimage: Optimise;
    import snakebite.dub: fetchProject;
    import snakebite.execution: executeBackend, prepareProject;
    import snakebite.gc: selectFrontendMemory;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.file: chdir, exists, isDir;
    import std.path: absolutePath;
    import std.stdio: stderr, stdout, write;

    const parsed = parseArgs(args);
    if (parsed.diagnostic.length)
        (parsed.status == 0 ? stdout : stderr)
            .write(parsed.diagnostic);
    if (parsed.status != 0 || parsed.options.showHelp)
        return parsed.status;
    selectFrontendMemory(parsed.options.lowmem);

    try {
        string projectDirectory = parsed.options.projectDirectory;
        if (!projectDirectory.exists || !projectDirectory.isDir)
            projectDirectory = fetchProject(projectDirectory);
        projectDirectory = projectDirectory.absolutePath;
        const importPaths = parsed.options.importPaths
            .map!(path => path.absolutePath).array;
        const stringImportPaths = parsed.options.stringImportPaths
            .map!(path => path.absolutePath).array;
        // The process ends with the program, and the module destructors run
        // when it does: they see the directory that `main` saw.
        chdir(projectDirectory);
        auto preparation = prepareProject(
            projectDirectory,
            importPaths,
            stringImportPaths,
            parsed.options.backend != BackendName.ctfe,
            parsed.options.versions,
            parsed.options.noOptimiseImage ? Optimise.no : Optimise.yes,
        );
        const report = executeBackend(
            parsed.options.backend,
            preparation.project.program,
            [preparation.project.program.name] ~ parsed.options.programArguments,
            false,
            true,
        );
        _statistics = Statistics(true, preparation, report);
        return report.status;
    } catch (Exception exception) {
        stderr.write("snakebite: ", exception.msg, "\n");
        return 1;
    }
}


// The report comes after everything the program prints. The module
// destructors of the program run when the process ends, so the report waits
// for the destructors of the host, which run after the program's.
private struct Statistics {
    bool pending;
    imported!"snakebite.execution".PreparationReport preparation;
    imported!"snakebite.execution".ExecutionReport report;
}


private __gshared Statistics _statistics;


shared static ~this() {
    if (_statistics.pending)
        printStatistics(_statistics.preparation, _statistics.report);
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


public struct CliResult {
    public int status;
    public string diagnostic;
    public Options options;
}


public CliResult parseArgs(string[] args) {
    import snakebite.backends: parseBackendName, validBackendNames;
    import snakebite.gc: lowmemHelp;
    import std.algorithm.searching: countUntil;
    import std.getopt: getopt, GetOptException;

    CliResult result;
    const separator = args.countUntil("--");
    if (separator >= 0) {
        result.options.programArguments = args[separator + 1 .. $].dup;
        args = args[0 .. separator];
    }
    string backendName = "bytecode";

    typeof(getopt(args)) helpInfo;
    try {
        helpInfo = getopt(
            args,
            "b|backend", "Select the backend (default: bytecode).",
                &backendName,
            "I|import-path", "Add an import path.",
                &result.options.importPaths,
            "J|string-import-path", "Add a string import path.",
                &result.options.stringImportPaths,
            "version", "Define a version identifier (repeatable).",
                &result.options.versions,
            "no-optimise-image", "Build the dependency image without optimisation (faster build, slower run).",
                &result.options.noOptimiseImage,
            "lowmem", lowmemHelp, &result.options.lowmem,
        );
    } catch (GetOptException exception) {
        return CliResult(1, exception.msg);
    }

    if (helpInfo.helpWanted) {
        result.options.showHelp = true;
        result.diagnostic = helpText;
        return result;
    }

    if (args.length != 2)
        return CliResult(1, "expected one project directory\n" ~ helpText);

    result.options.projectDirectory = args[1];
    if (!parseBackendName(backendName, result.options.backend))
        return CliResult(
            1,
            "unknown backend: " ~ backendName ~ "\n" ~
                "valid backends: " ~ validBackendNames,
        );

    return result;
}


private enum helpText =
    "Usage: sb [options] <directory> [-- program arguments...]\n" ~
    "\n" ~
    "Run the D unit tests in a project directory.\n" ~
    "Pass arguments after -- to the program (for example: -- -d).\n" ~
    "\n" ~
    "Options:\n" ~
    "  -b, --backend <name>      Select the backend (default: bytecode)\n" ~
    "                            valid: "
        ~ imported!"snakebite.backends".validBackendNames ~ "\n" ~
    "  -I, --import-path <path>  Add an import path for a bare directory\n" ~
    "  -J, --string-import-path <path>\n" ~
    "                            Add a string import path for a bare directory\n" ~
    "  --version=<identifier>    Define a version identifier (repeatable)\n" ~
    "  --no-optimise-image       Build the dependency image without\n" ~
    "                            optimisation (faster build, slower run)\n" ~
    "  --lowmem                  "
        ~ imported!"snakebite.gc".lowmemHelp ~ "\n" ~
    "  -h, --help                Show this help\n";
