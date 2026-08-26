// Benchmark harness for snakebite backends. Point it at a project (default:
// examples/ct). The frontend parses and semantically analyses the project
// once, reported as `frontend` in the header so it never pollutes the
// per-backend numbers. Each backend then runs the whole program through
// `Backend.run` - the backend does whatever compiled D would do, the
// harness never collects or runs tests itself - and the table reports the
// verdict, run-time statistics, the backend's own compile time (for
// backends that have a compile step) and resident memory growth. A `dmd`
// row (bench.oracle) benchmarks the real workflow as subprocesses and
// doubles as the correctness oracle.
module bench.main;


import bench.report: BackendReport;
import bench.sources: SourceSet;
import core.time: Duration;


struct Options {
    uint runs = 10;
    uint warmup = 1;
    string[] backends;
    string[] importPaths;       // bare directories only; dub knows its own
    string[] stringImportPaths; // ditto
    string projectDirectory;
    bool helpWanted;
}

int main(string[] args) {
    import bench.report: printTable;
    import snakebite.frontend.compiler: Snippets, initialize;
    import std.stdio: stderr, writeln;

    Options options;
    try
        options = parseOptions(args);
    catch (Exception exception) {
        stderr.writeln(exception.msg);
        return 1;
    }

    if (options.helpWanted)
        return 0;

    if (const error = validate(options)) {
        stderr.writeln(error);
        return 1;
    }

    initialize(Snippets.no);

    Project project;
    try
        project = loadProject(options);
    catch (Exception exception) {
        stderr.writeln(exception.msg);
        return 1;
    }

    const reports = benchmarkAll(project, options);

    writeln(headerLine(project, options));
    writeln;
    printTable(reports);

    // A failing backend fails the process: build/ci.sh runs the bench as a
    // smoke test, and an exit status of 0 next to a FAIL row once let a
    // real regression through unreported.
    import std.algorithm.searching: all;
    return reports.all!(report => report.passed) ? 0 : 1;
}

private Options parseOptions(string[] args) {
    import std.getopt: defaultGetoptPrinter, getopt;

    Options options;
    auto result = getopt(
        args,
        "runs|r", "How many measured runs (default 10).", &options.runs,
        "warmup|w", "How many warmup runs (default 1).", &options.warmup,
        "backend|b", "Benchmark only this backend; repeatable (default all).",
        &options.backends,
        "import-path|I", "Import path for a bare directory of .d files; "
        ~ "repeatable.", &options.importPaths,
        "string-import-path|J", "String import path for a bare directory of "
        ~ ".d files; repeatable.", &options.stringImportPaths,
    );

    if (result.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [options] [project-directory]",
            result.options,
        );
        options.helpWanted = true;
        return options;
    }

    options.projectDirectory =
        args.length > 1 ? args[1] : defaultProjectDirectory;

    return options;
}

private string validate(in Options options) {
    import std.algorithm.searching: canFind;
    import std.array: join;
    import std.conv: text;

    if (options.runs == 0)
        return "need at least one measured run";

    foreach (name; options.backends)
        if (!knownBackendNames.canFind(name))
            return text(
                "unknown backend `", name, "`; known: ",
                knownBackendNames.join(", "),
            );

    return null;
}

// The project under benchmark: its root modules as one `Program`, its
// sources (the oracle rebuilds from them), and how long parse + semantic
// analysis took.
private struct Project {
    string name;
    string directory;
    Duration frontend;
    SourceSet sources;
    imported!"snakebite.backends".Program program;
}

private Project loadProject(in Options options) {
    import bench.sources: sourceSet;
    import snakebite.backends: Program;
    import snakebite.frontend.compiler: FrontendFlags, parseRootModules;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.path: absolutePath, baseName, buildNormalizedPath;

    Project project;
    project.directory =
        options.projectDirectory.absolutePath.buildNormalizedPath;
    project.name = project.directory.baseName;
    project.sources = sourceSet(
        project.directory,
        options.importPaths,
        options.stringImportPaths,
    );

    // String imports reach the frontend as `-J` flags, like any compiler.
    const flags = FrontendFlags(
        project.sources.flags.compilerArguments
        ~ project.sources.stringImportPaths.map!(path => "-J" ~ path).array,
    );

    auto stopWatch = StopWatch(AutoStart.yes);
    auto parsed = parseRootModules(
        project.sources.files, project.sources.importPaths, flags,
    );
    project.frontend = stopWatch.peek;

    project.program = Program(parsed);

    return project;
}

private BackendReport[] benchmarkAll(Project project, in Options options) {
    import bench.oracle: oracleName, oracleReport;

    BackendReport[] reports;
    static foreach (BackendType; imported!"snakebite.backends".Backends)
        if (selected(options, backendName!BackendType)) {
            auto backend = new BackendType;

            // Not every backend has a compile step (`Backend` doesn't
            // declare one - CTFE, say, interprets directly from the parsed
            // AST); `hasMember` needs the concrete type, so this stays at
            // the one call site that already has it, not inside `benchmark`.
            bool hasCompile;
            Duration compile;
            static if (__traits(hasMember, BackendType, "compile")) {
                import std.datetime.stopwatch: AutoStart, StopWatch;

                hasCompile = true;
                auto compileWatch = StopWatch(AutoStart.yes);
                backend.compile(project.program);
                compile = compileWatch.peek;
            }

            // A backend without druntime (CTFE) cannot run the project's
            // real `main` - for a dub project that's dub's own generated
            // test root, which drives unittests through druntime's
            // ModuleInfo runner rather than calling them itself. Swap in a
            // synthesized runner that calls every unittest directly; see
            // `parseUnittestRunner`. Every other backend runs the real
            // program.
            auto backendProject = project;
            if (!backend.hasDruntime) {
                import snakebite.backends: Program;
                import snakebite.frontend.compiler: parseUnittestRunner;

                backendProject.program = Program(
                    parseUnittestRunner(project.program.rootModules),
                );
            }

            reports ~= benchmark(
                backend,
                backendName!BackendType,
                backendProject,
                options.warmup,
                options.runs,
                hasCompile,
                compile,
            );
        }

    if (selected(options, oracleName))
        reports ~= oracleReport(
            project.sources, project.directory, options.warmup, options.runs,
        );

    return reports;
}

private bool selected(in Options options, in string name) {
    import std.algorithm.searching: canFind;

    return options.backends.length == 0 || options.backends.canFind(name);
}

private BackendReport benchmark(
    imported!"snakebite.backends".Backend backend,
    in string name,
    Project project,
    in uint warmup,
    in uint runs,
    in bool hasCompile,
    in Duration compile,
) {
    import bench.report: fillTimingStatistics;
    // `run` is a free function over `Backend.call`; UFCS keeps the call
    // site reading like the interface method it used to be.
    import snakebite.backends.backend: run;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    BackendReport report;
    report.name = name;
    report.hasCompile = hasCompile;
    report.compile = compile;

    const residentBefore = residentSetBytes;

    // A failing backend's diagnostics go to stderr, repeated over warmup +
    // measured runs. Noisy, but silencing them left failures with no
    // explanation at all; the noise is the lesser evil.
    Duration[] times;
    foreach (round; 0 .. warmup + runs) {
        auto stopWatch = StopWatch(AutoStart.yes);
        report.passed = backend.run(project.program) == 0;
        if (round >= warmup)
            times ~= stopWatch.peek;
    }

    fillTimingStatistics(report, times);

    report.ramBytes = residentSetBytes - residentBefore;
    if (report.ramBytes < 0)
        report.ramBytes = 0;

    return report;
}

private enum backendName(BackendType) =
    imported!"std.uni".toLower(BackendType.stringof);

private enum knownBackendNames = () {
    string[] names;
    static foreach (BackendType; imported!"snakebite.backends".Backends)
        names ~= backendName!BackendType;
    names ~= imported!"bench.oracle".oracleName;
    return names;
}();

private string headerLine(in Project project, in Options options) {
    import bench.report: milliseconds;
    import std.conv: text;

    return text(
        project.name,
        "   frontend ", milliseconds(project.frontend),
        "   ", hostCompiler,
        "   ", options.warmup, "+", options.runs, " runs",
    );
}

// The compiler that built this binary, and thereby the backends: the numbers
// mean little without knowing whether the backends were optimised.
private string hostCompiler() {
    import std.conv: text;

    version (LDC)
        enum compiler = "LDC";
    else version (DigitalMars)
        enum compiler = "DMD";
    else version (GNU)
        enum compiler = "GDC";
    else
        enum compiler = "D";

    version (D_Optimized)
        enum flags = " -O";
    else
        enum flags = "";

    return text(compiler, " ", __VERSION__, flags);
}

private string defaultProjectDirectory() {
    import std.file: thisExePath;
    import std.path: buildNormalizedPath, dirName;

    return thisExePath.dirName.buildNormalizedPath("..", "examples", "ct");
}

// This process's resident set, from /proc/self/statm. In-process backends
// have no per-run peak to isolate, so the table reports how much the
// resident set grew across one backend's whole benchmark.
private long residentSetBytes() {
    import core.sys.posix.unistd: _SC_PAGESIZE, sysconf;
    import std.conv: to;
    import std.file: readText;
    import std.string: split;

    const fields = readText("/proc/self/statm").split;
    return fields[1].to!long * sysconf(_SC_PAGESIZE);
}
