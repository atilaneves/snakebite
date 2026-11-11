module snakebite.driver.cli;


private:


public struct Options {
    import snakebite.backends: BackendName;

    import snakebite.driver.options: ProjectOptions;

    public ProjectOptions project;
    alias project this;
    public BackendName backend;
    public string projectDirectory;
    public bool showHelp;
    public bool jitPerfMap;
    // Real `bin/sb` use keeps optimisation: a guest run pays the image's
    // run time, not just its build time. This flag trades that away for
    // faster image builds, for a caller that only checks behaviour.
    public bool noOptimiseImage;
    // `--save=<file>` compiles the project to a file and runs nothing.
    // `--load=<file>` runs a saved file and takes no project directory.
    public string savePath;
    public string loadPath;
}


// `bin/sb`: run a project's unit tests and its `main` on one backend.
public int run(string[] args) {
    import snakebite.backends: BackendName;
    import snakebite.image.dependency: Optimise;
    import snakebite.project.dub: fetchProject;
    import snakebite.driver.execution:
        executeBackend, executeLoaded, prepareSources, runProject, saveProgram;
    import snakebite.project.loading: EndsProcess;
    import snakebite.backends.bytecode.vm: JitSetting;
    import snakebite.memory.gc: selectFrontendMemory;
    import std.file: exists, isDir;
    import std.path: absolutePath;
    import std.stdio: stderr, stdout, write;

    const parsed = parseArgs(args);
    if (parsed.diagnostic.length)
        (parsed.status == 0 ? stdout : stderr)
            .write(parsed.diagnostic);
    if (parsed.status != 0 || parsed.options.showHelp)
        return parsed.status;
    // A saved program starts no frontend.
    if (parsed.options.loadPath.length)
        try
            return executeLoaded(
                parsed.options.loadPath, parsed.options.programArguments);
        catch (Exception exception) {
            stderr.write("snakebite: ", exception.msg, "\n");
            return 1;
        }
    selectFrontendMemory(parsed.options.lowmem);

    try {
        // The program runs in the working directory of the project, so a
        // relative path would name a file there.
        const savePath = parsed.options.savePath.length
            ? parsed.options.savePath.absolutePath : "";
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
                if (savePath.length) {
                    saveProgram(preparation.project.program, savePath);
                    return 0;
                }
                const report = executeBackend(
                    parsed.options.backend,
                    preparation.project.program,
                    [preparation.project.program.name]
                        ~ parsed.options.programArguments,
                    false,
                    true,
                    JitSetting(!parsed.options.noJit,
                        /*eager*/ false, parsed.options.jitPerfMap),
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
    imported!"snakebite.driver.execution".PreparationReport preparation;
    imported!"snakebite.driver.execution".ExecutionReport report;
}


private __gshared Statistics _statistics;


shared static ~this() {
    if (_statistics.pending)
        printStatistics(_statistics.preparation, _statistics.report);
}


private void printStatistics(
    in imported!"snakebite.driver.execution".PreparationReport preparation,
    in imported!"snakebite.driver.execution".ExecutionReport report,
) {
    import snakebite.driver.execution: discoveryLabel;
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
    import snakebite.backends: BackendName, parseBackendName,
        validBackendNames;
    import snakebite.driver.options: backendOption, parseProjectOptions;
    import std.getopt: GetOptException;

    CliResult result;
    string backendName = "bytecode";

    typeof(parseProjectOptions(args, result.options.project)) helpInfo;
    try {
        helpInfo = parseProjectOptions(
            args,
            result.options.project,
            backendOption(backendName).expand,
            "jit-perf-map", jitPerfMapHelp, &result.options.jitPerfMap,
            "no-optimise-image", "Build the dependency image without optimisation (faster build, slower run).",
                &result.options.noOptimiseImage,
            "save", saveHelp, &result.options.savePath,
            "load", loadHelp, &result.options.loadPath,
        );
    } catch (GetOptException exception) {
        return CliResult(1, exception.msg);
    }

    if (helpInfo.helpWanted) {
        result.options.showHelp = true;
        result.diagnostic = helpText;
        return result;
    }

    if (!parseBackendName(backendName, result.options.backend))
        return CliResult(
            1,
            "unknown backend: " ~ backendName ~ "\n" ~
                "valid backends: " ~ validBackendNames,
        );

    if (result.options.loadPath.length) {
        if (args.length != 1 || result.options.savePath.length)
            return CliResult(
                1, "--load takes no project directory and no --save\n"
                    ~ helpText);
        const unhonoured = optionIgnoredByLoad(result.options);
        if (unhonoured.length)
            return CliResult(
                1, "--load does not honour " ~ unhonoured ~ "\n" ~ helpText);
        return result;
    }
    if (args.length != 2)
        return CliResult(1, "expected one project directory\n" ~ helpText);

    result.options.projectDirectory = args[1];

    if (result.options.savePath.length
            && result.options.backend != BackendName.bytecode)
        return CliResult(1, "--save needs the bytecode backend\n");

    return result;
}


// A saved program carries what the options choose: its sources, its
// versions, its backend. Only the program arguments still apply at run time.
private string optionIgnoredByLoad(in Options options) {
    import snakebite.backends: BackendName;

    if (options.backend != BackendName.bytecode)
        return "--backend";
    if (options.importPaths.length)
        return "--import-path";
    if (options.stringImportPaths.length)
        return "--string-import-path";
    if (options.versions.length)
        return "--version";
    if (options.lowmem)
        return "--lowmem";
    if (options.noJit)
        return "--no-jit";
    if (options.jitPerfMap)
        return "--jit-perf-map";
    if (options.noOptimiseImage)
        return "--no-optimise-image";
    return "";
}


private enum saveHelp = "Compile the project to <file> and run nothing.";
private enum loadHelp = "Run a program saved with --save; no project directory.";
private enum jitPerfMapHelp = "Write JIT symbols to /tmp/perf-<pid>.map.";

private enum helpText =
    "Usage: sb [options] <directory> [-- program arguments...]\n" ~
    "\n" ~
    "Run `main` of the D program in a project directory.\n" ~
    "The program is built with -unittest.\n" ~
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
        ~ imported!"snakebite.memory.gc".lowmemHelp ~ "\n" ~
    "  --no-jit                  "
        ~ imported!"snakebite.driver.options".noJitHelp ~ "\n" ~
    "  --jit-perf-map            " ~ jitPerfMapHelp ~ "\n" ~
    "  --save <file>             " ~ saveHelp ~ "\n" ~
    "  --load <file>             " ~ loadHelp ~ "\n" ~
    "  -h, --help                Show this help\n";
