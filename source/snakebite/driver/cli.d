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
    // The file that `--save` writes the compiled program to, or empty.
    public string save;
    // The file that `--load` reads the compiled program from, or empty.
    public string load;
}


// `bin/sb`: run a project's unit tests and its `main` on one backend.
public int run(string[] args) {
    import snakebite.backends: BackendName;
    import snakebite.image.preparation: Optimise;
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
    selectFrontendMemory(parsed.options.lowmem);

    try {
        if (parsed.options.load.length)
            return executeLoaded(
                parsed.options.load, parsed.options.programArguments,
                JitSetting(!parsed.options.noJit,
                    /*eager*/ false, parsed.options.jitPerfMap),
            ).status;
        // The project directory is where the compile runs: a relative path
        // of the caller must be absolute before that.
        const savePath = parsed.options.save.length
            ? parsed.options.save.absolutePath : "";
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
                if (savePath.length) {
                    saveProgram(
                        preparation.project.program,
                        savePath,
                        sources.workingDirectory.length
                            ? sources.workingDirectory : directory,
                        JitSetting(!parsed.options.noJit,
                            /*eager*/ false, parsed.options.jitPerfMap),
                    );
                    return 0;
                }
                enterWorkingDirectory();
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
    import snakebite.backends: parseBackendName, validBackendNames;
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
            "save", saveHelp, &result.options.save,
            "load", loadHelp, &result.options.load,
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

    if (const diagnostic = optionConflict(result.options, args.length))
        return CliResult(1, diagnostic ~ "\n" ~ helpText);

    if (result.options.load.length == 0)
        result.options.projectDirectory = args[1];
    return result;
}


// Why the options cannot be used together, or null. A loaded program is
// already compiled, so the options that describe a compile have no meaning
// with `--load`, and only the bytecode backend has a compiled program to
// save or load.
private string optionConflict(in Options options, in size_t argumentCount) {
    import snakebite.backends: BackendName;

    const saves = options.save.length != 0;
    const loads = options.load.length != 0;
    if (saves && loads)
        return "--save and --load cannot be used together";
    if ((saves || loads) && options.backend != BackendName.bytecode)
        return "--save and --load work with the bytecode backend only";
    if (!loads)
        return argumentCount == 2 ? null : "expected one project directory";
    if (argumentCount != 1)
        return "--load takes no project directory";
    if (options.importPaths.length || options.stringImportPaths.length
            || options.versions.length || options.noOptimiseImage)
        return "--load takes none of the options that describe a compile";
    return null;
}


private enum saveHelp = "Compile the program and write it to FILE; do not run it.";
private enum loadHelp = "Run the program that FILE holds; no project directory.";

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
    "  --save=FILE               " ~ saveHelp ~ "\n" ~
    "  --load=FILE               " ~ loadHelp ~ "\n" ~
    "  --lowmem                  "
        ~ imported!"snakebite.memory.gc".lowmemHelp ~ "\n" ~
    "  --no-jit                  "
        ~ imported!"snakebite.driver.options".noJitHelp ~ "\n" ~
    "  --jit-perf-map            " ~ jitPerfMapHelp ~ "\n" ~
    "  -h, --help                Show this help\n";
