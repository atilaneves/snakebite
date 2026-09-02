// Benchmark harness for snakebite backends. Point it at a benchmark - a name
// under `examples/`, like `ct-easy`, or a path to any other project - and it
// runs the backends that benchmark declares in its `bench.backends` file
// (all of them if it has none), which `--backend` and `--exclude` still
// override. The frontend parses and semantically analyses the project
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
    string[] excluded;
    string[] declared;          // what the benchmark itself asks for
    string[] importPaths;       // bare directories only; dub knows its own
    string[] stringImportPaths; // ditto
    string projectDirectory;
    bool helpWanted;
}

version (BenchMain)
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
        "backend|b", "Benchmark only this backend; repeatable (default: "
        ~ "what the benchmark declares, else all).",
        &options.backends,
        "exclude|e", "Do not benchmark this backend; repeatable. Applies "
        ~ "after --backend.", &options.excluded,
        "import-path|I", "Import path for a bare directory of .d files; "
        ~ "repeatable.", &options.importPaths,
        "string-import-path|J", "String import path for a bare directory of "
        ~ ".d files; repeatable.", &options.stringImportPaths,
    );

    if (result.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [options] [benchmark]\n\n"
            ~ "A benchmark is a name under examples/ (default "
            ~ defaultBenchmark ~ ") or a path to a project directory.",
            result.options,
        );
        options.helpWanted = true;
        return options;
    }

    options.projectDirectory =
        projectDirectory(args.length > 1 ? args[1] : defaultBenchmark);
    options.declared = declaredBackends(options.projectDirectory);

    return options;
}

// A benchmark is named, not spelled out: `ct-easy` means `examples/ct-easy`.
// A path to a directory still works, for projects outside `examples/`.
private string projectDirectory(in string nameOrPath) {
    import std.array: join;
    import std.conv: text;
    import std.file: exists, isDir;
    import std.path: absolutePath, buildNormalizedPath;

    if (nameOrPath.exists && nameOrPath.isDir)
        return nameOrPath.absolutePath.buildNormalizedPath;

    const candidate = buildNormalizedPath(examplesDirectory, nameOrPath);
    if (candidate.exists && candidate.isDir)
        return candidate;

    throw new Exception(text(
        "unknown benchmark `", nameOrPath, "`; known: ",
        benchmarkNames.join(", "),
    ));
}

// Not every benchmark suits every backend - a backend that cannot run one
// yet would only ever report FAIL there. Each benchmark says which backends
// to run in a `bench.backends` file, one name per line, `#` comments and
// blank lines ignored. No file means all of them.
private string[] declaredBackends(in string directory) {
    import std.algorithm.iteration: filter, map, splitter;
    import std.algorithm.searching: canFind, startsWith;
    import std.array: array, join;
    import std.conv: text;
    import std.file: exists, readText;
    import std.path: buildPath;
    import std.string: strip;

    const file = buildPath(directory, backendsFileName);
    if (!file.exists)
        return null;

    // `const` would not convert back to the mutable `string[]` returned.
    auto names = file
        .readText
        .splitter('\n')
        .map!strip
        .filter!(line => line.length && !line.startsWith("#"))
        .array;

    foreach (name; names)
        if (!knownBackendNames.canFind(name))
            throw new Exception(text(
                file, ": unknown backend `", name, "`; known: ",
                knownBackendNames.join(", "),
            ));

    return names;
}

private enum backendsFileName = "bench.backends";

private string validate(in Options options) {
    import std.algorithm.searching: canFind;
    import std.array: join;
    import std.conv: text;

    if (options.runs == 0)
        return "need at least one measured run";

    foreach (name; options.backends ~ options.excluded)
        if (!knownBackendNames.canFind(name))
            return text(
                "unknown backend `", name, "`; known: ",
                knownBackendNames.join(", "),
            );

    if (!knownBackendNames.canFind!(name => selected(options, name)))
        return "no backends left to benchmark";

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
        project.sources.files,
        project.sources.importPaths,
        flags,
        project.sources.sourceOverrides,
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
            reports ~= benchmark!BackendType(
                backendName!BackendType,
                project.program,
                options.warmup,
                options.runs,
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

    if (options.excluded.canFind(name))
        return false;

    // `--backend` overrides what the benchmark declares; both filter down
    // from every known backend, so an empty list means all of them.
    const wanted = options.backends.length ? options.backends : options.declared;
    return wanted.length == 0 || wanted.canFind(name);
}

public BackendReport benchmark(BackendType)(
    in string name,
    imported!"snakebite.backends".Program program,
    in uint warmup,
    in uint runs,
) {
    import bench.capture: captureStdout;
    import bench.report: timingStatistics, updateTestCounts;
    // `run` is a free function over `Backend.call`; UFCS keeps the call
    // site reading like the interface method it used to be.
    import snakebite.backends.backend: run;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.stdio: write;

    BackendReport report;
    report.name = name;
    report.passed = true;

    const residentBefore = residentSetBytes;

    // A failing backend's diagnostics go to stderr, repeated over warmup +
    // measured runs. Noisy, but silencing them left failures with no
    // explanation at all; the noise is the lesser evil.
    Duration[] times;
    Duration[] compileTimes;
    foreach (round; 0 .. warmup + runs) {
        auto stopWatch = StopWatch(AutoStart.yes);
        auto backend = new BackendType(program);
        const compilationBefore = backend.compilationStatistics;
        const result = captureStdout(() => backend.run(program));
        const elapsed = stopWatch.peek;
        const compilationAfter = backend.compilationStatistics;
        const compilationElapsed =
            compilationAfter.duration - compilationBefore.duration;
        if (round >= warmup) {
            write(result.output);
            report.passed = report.passed && result.status == 0;
            report.hasCompile = compilationAfter.hasCompiler;
            if (report.hasCompile)
                compileTimes ~= compilationElapsed;
            times ~= elapsed;
            report.updateTestCounts(result.output);
        }
    }

    report.runTime = timingStatistics(times);
    if (report.hasCompile)
        report.compileTime = timingStatistics(compileTimes);

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

private enum defaultBenchmark = "ct-easy";

private string examplesDirectory() {
    import std.file: thisExePath;
    import std.path: buildNormalizedPath, dirName;

    return thisExePath.dirName.buildNormalizedPath("..", "examples");
}

private string[] benchmarkNames() {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: dirEntries, SpanMode;
    import std.path: baseName;

    return examplesDirectory
        .dirEntries(SpanMode.shallow)
        .filter!(entry => entry.isDir)
        .map!(entry => entry.name.baseName)
        .array
        .sort
        .release;
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
