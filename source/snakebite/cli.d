module snakebite.cli;


private:


public struct Options {
    import snakebite.backends: BackendName;

    import snakebite.projectoptions: ProjectOptions;

    public ProjectOptions project;
    alias project this;
    public BackendName backend;
    public string projectDirectory;
    public bool showHelp;
    // Real `bin/sb` use keeps optimisation: a guest run pays the image's
    // run time, not just its build time. This flag trades that away for
    // faster image builds, for a caller that only checks behaviour.
    public bool noOptimiseImage;
}


// `bin/sb`: run a project's unit tests and its `main` on one backend.
public int run(string[] args) {
    import snakebite.backends: BackendName;
    import snakebite.dependencyimage: Optimise;
    import snakebite.dub: fetchProject;
    import snakebite.execution: executeBackend, prepareSources, runProject;
    import snakebite.project: EndsProcess;
    import snakebite.gc: selectFrontendMemory;
    import std.file: exists, isDir;
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
        return runProject(
            projectDirectory,
            parsed.options.importPaths,
            parsed.options.stringImportPaths,
            parsed.options.versions,
            EndsProcess.yes,
            (directory, sources, discovery, enterWorkingDirectory) {
                auto preparation = prepareSources(
                    directory,
                    sources,
                    discovery,
                    parsed.options.backend != BackendName.ctfe,
                    parsed.options.noOptimiseImage ? Optimise.no : Optimise.yes,
                );
                enterWorkingDirectory();
                const report = executeBackend(
                    parsed.options.backend,
                    preparation.project.program,
                    [preparation.project.program.name]
                        ~ parsed.options.programArguments,
                    false,
                    true,
                );
                _statistics = Statistics(true, preparation, report);
                return report.status;
            },
        );
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
    // The backend's own cost. Each line below it is a part of it that no
    // other line includes, and `other` is the rest.
    const compile = report.compilation.duration;
    const other = report.latency - compile - report.moduleInfoDuration
        - report.constructorDuration - report.programDuration;
    writefln("%-20s %8.1f ms", "backend latency:", milliseconds(report.latency));
    if (report.compilation.hasCompiler)
        writefln("%-20s %8.1f ms", "  compile:", milliseconds(compile));
    writefln(
        "%-20s %8.1f ms",
        "  ModuleInfo:",
        milliseconds(report.moduleInfoDuration),
    );
    writefln(
        "%-20s %8.1f ms",
        "  module ctors:",
        milliseconds(report.constructorDuration),
    );
    writefln(
        "%-20s %8.1f ms",
        "  tests and main:",
        milliseconds(report.programDuration),
    );
    writefln("%-20s %8.1f ms", "  other:", milliseconds(other));
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
    import snakebite.projectoptions: parseProjectOptions;
    import std.getopt: GetOptException;

    CliResult result;
    string backendName = "bytecode";

    typeof(parseProjectOptions(args, result.options.project)) helpInfo;
    try {
        helpInfo = parseProjectOptions(
            args,
            result.options.project,
            "b|backend", "Select the backend (default: bytecode).",
                &backendName,
            "no-optimise-image", "Build the dependency image without optimisation (faster build, slower run).",
                &result.options.noOptimiseImage,
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
