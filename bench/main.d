// Benchmark harness for snakebite backends. Point it at an example project
// (default: examples/ct). The frontend parses and semantically analyses the
// project once, reported as `frontend` in the header so it never pollutes the
// per-backend numbers. Each backend then runs every unittest as its own entry
// point through `Backend.run`, warmup runs first, and the table reports pass
// counts, run-time statistics, the backend's own compile time (for backends
// that have a compile step) and resident memory growth.

private:


public int main(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import std.algorithm.searching: canFind;
    import std.array: join;
    import std.getopt: defaultGetoptPrinter, getopt;
    import std.stdio: stderr, writeln;

    uint runs = 10;
    uint warmup = 1;
    string[] backendFilter;

    auto options = getopt(
        args,
        "runs|r", "How many measured runs (default 10).", &runs,
        "warmup|w", "How many warmup runs (default 1).", &warmup,
        "backend|b", "Benchmark only this backend; repeatable (default all).",
        &backendFilter,
    );

    if (options.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [options] [example-directory]",
            options.options,
        );
        return 0;
    }

    if (runs == 0) {
        stderr.writeln("need at least one measured run");
        return 1;
    }

    foreach (name; backendFilter)
        if (!knownBackendNames.canFind(name)) {
            stderr.writeln(
                "unknown backend `", name, "`; known: ",
                knownBackendNames.join(", "),
            );
            return 1;
        }

    const exampleDirectory = args.length > 1 ? args[1] : defaultExampleDirectory;

    initialize(Snippets.no);

    Example example;
    try
        example = parseExample(exampleDirectory);
    catch (Exception exception) {
        stderr.writeln(exception.msg);
        return 1;
    }

    writeln(headerLine(example, warmup, runs));
    writeln;

    BackendReport[] reports;
    static foreach (BackendType; imported!"snakebite.backends".Backends)
        if (selected!BackendType(backendFilter))
            reports ~= benchmark!BackendType(example, warmup, runs);

    if (backendFilter.length == 0 || backendFilter.canFind(oracleName))
        reports ~= dmdReport(example, exampleDirectory, warmup, runs);

    printTable(reports);

    return 0;
}

// The example under benchmark: its root modules as one `Program`, every
// unittest in declaration order, and how long parse + semantic analysis took.
private struct Example {
    string name;
    double frontendMilliseconds;
    imported!"snakebite.backends".Program program;
    imported!"dmd.func".FuncDeclaration[] tests;
}

private Example parseExample(in string directory) {
    import snakebite.backends: Program;
    import snakebite.frontend.compiler: parseRootModules;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.path: absolutePath, baseName, buildNormalizedPath;

    const path = directory.absolutePath.buildNormalizedPath;
    const sources = sourceFiles(path);

    Example example;
    example.name = path.baseName;

    auto stopWatch = StopWatch(AutoStart.yes);
    auto parsed =
        parseRootModules(sources.files, sources.importPaths, sources.flags);
    example.frontendMilliseconds = stopWatch.elapsedMilliseconds;

    auto modules = parsed.map!(result => result.module_).array;
    example.program = Program(modules);
    foreach (module_; modules)
        collectUnitTests(module_.members, example.tests);

    return example;
}

private struct SourceSet {
    string[] files;
    string[] importPaths;
    imported!"snakebite.frontend.compiler".FrontendFlags flags;
}

// A dub project is described by dub itself (source files, import paths for it
// and its transitive dependencies, and the frontend-relevant flags), matching
// what `dub test` would compile; a bare directory of .d files works too.
private SourceSet sourceFiles(in string directory) {
    import std.conv: text;
    import std.file: exists, isDir;

    if (!directory.exists || !directory.isDir)
        throw new Exception(text("not a directory: ", directory));

    return isDubProject(directory) ? dubSourceSet(directory) : bareSourceSet(directory);
}

private bool isDubProject(in string directory) {
    import std.file: exists;
    import std.path: buildPath;

    foreach (recipe; ["dub.sdl", "dub.json"])
        if (buildPath(directory, recipe).exists)
            return true;

    return false;
}

// dub's test configuration: the same sources, import paths and flags
// `dub test` itself would build with, so the bench mirrors the real
// workflow.
private SourceSet dubSourceSet(in string directory) {
    import snakebite.dub: DubConfig, dubCompilerArguments, dubDescribe;
    import snakebite.frontend.compiler: FrontendFlags;
    import std.conv: text;

    auto files = dubDescribe(directory, "source-files", DubConfig.test);
    if (files.length == 0)
        throw new Exception(text("dub describe found no sources in ", directory));

    return SourceSet(
        files,
        dubDescribe(directory, "import-paths", DubConfig.test),
        FrontendFlags(dubCompilerArguments(directory, DubConfig.test)),
    );
}

// Sorted so test order and the header count are stable.
private SourceSet bareSourceSet(in string directory) {
    import std.algorithm.iteration: map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.conv: text;
    import std.file: SpanMode, dirEntries;

    auto files = dirEntries(directory, "*.d", SpanMode.depth)
        .map!(entry => entry.name)
        .array
        .sort
        .release;

    if (files.length == 0)
        throw new Exception(text("no D source files under ", directory));

    return SourceSet(files, [directory]);
}

// Unittests live at module scope, behind attribute declarations (`@("name")`,
// `static:`, ...), or inside aggregates; druntime runs all of them.
private void collectUnitTests(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref imported!"dmd.func".FuncDeclaration[] tests,
) {
    if (symbols is null)
        return;

    foreach (symbol; *symbols) {
        if (symbol is null)
            continue;

        if (auto test = symbol.isUnitTestDeclaration) {
            tests ~= test;
            continue;
        }

        if (auto attributes = symbol.isAttribDeclaration) {
            collectUnitTests(attributes.decl, tests);
            continue;
        }

        if (auto aggregate = symbol.isAggregateDeclaration)
            collectUnitTests(aggregate.members, tests);
    }
}

private struct BackendReport {
    string name;
    size_t passed;
    size_t total;
    double minimum;
    double median;
    double sigma;
    double compile; // NaN when the backend has no compile step
    long ramBytes;
    // True for the dmd row. It spawns whatever test runner the project
    // actually uses; against druntime's default runner (per-module, not
    // per-test - the case for examples/ct) that gives no per-test
    // granularity, so `passed`/`total` are exit-status only - either
    // everything passed or nothing is known to have.
    bool isOracle;
}

private BackendReport benchmark(BackendType)(
    Example example,
    in uint warmup,
    in uint runs,
) {
    import std.datetime.stopwatch: AutoStart, StopWatch;

    auto backend = new BackendType;

    BackendReport report;
    report.name = backendName!BackendType;
    report.total = example.tests.length;
    report.compile = double.nan;

    const residentBefore = residentSetBytes;

    // A failing test prints its diagnostic the way druntime prints an escaped
    // `Throwable`; repeated over warmup + measured runs that is noise, and
    // the pass column already reports failures, so drop it.
    auto silenced = silencedStderr;
    scope(exit) silenced.restore;

    static if (__traits(hasMember, BackendType, "compile")) {
        auto compileWatch = StopWatch(AutoStart.yes);
        backend.compile(example.program);
        report.compile = compileWatch.elapsedMilliseconds;
    }

    double[] times;
    foreach (round; 0 .. warmup + runs) {
        auto stopWatch = StopWatch(AutoStart.yes);

        size_t passed;
        foreach (test; example.tests)
            if (backend.run(example.program, test) == 0)
                ++passed;

        if (round >= warmup)
            times ~= stopWatch.elapsedMilliseconds;
        report.passed = passed;
    }

    fillTimingStatistics(report, times);

    report.ramBytes = residentSetBytes - residentBefore;
    if (report.ramBytes < 0)
        report.ramBytes = 0;

    return report;
}

private void fillTimingStatistics(ref BackendReport report, double[] times) {
    import std.algorithm.sorting: sort;

    auto sorted = times.dup.sort.release;
    report.minimum = sorted[0];
    report.median = (sorted[$ / 2] + sorted[($ - 1) / 2]) / 2;
    report.sigma = standardDeviation(times);
}

// Not a `Backend`: the real workflow, spawned as subprocesses, always the
// `dmd` binary (never `$DC`) so the numbers don't shift with CI's compiler
// matrix. `dmd -o-` (parse+sema) is measured once as the `compile` cell,
// mirroring the in-process backends' compile step; each warmup/measured
// round then runs the full cycle (`dub test`, or a raw build+run for a bare
// directory) and its elapsed time minus that baseline is the round's sample
// - codegen+link+run, matching what the in-process backends' min/median
// measure. Doubles as the correctness oracle: a failing round is reported as
// `FAIL` rather than a pass count, since the project's own test runner is
// the one that ran - against druntime's default runner that's per-module,
// not per-test.
private BackendReport dmdReport(
    in Example example,
    in string directory,
    in uint warmup,
    in uint runs,
) {
    import std.conv: text;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.file: exists, remove, tempDir;
    import std.path: buildPath;
    import std.process: thisProcessID;
    import std.stdio: stderr;

    BackendReport report;
    report.name = oracleName;
    report.isOracle = true;
    report.total = example.tests.length;

    const sources = sourceFiles(directory);
    const dub = isDubProject(directory);
    const tmpBinary =
        buildPath(tempDir, "snakebite-bench-dmd-" ~ thisProcessID.text);
    scope(exit)
        if (tmpBinary.exists)
            tmpBinary.remove;

    auto compileWatch = StopWatch(AutoStart.yes);
    dmdParseOnly(sources);
    report.compile = compileWatch.elapsedMilliseconds;

    double[] times;
    bool allPassed = true;
    bool haveGranularCount;
    size_t granularPassed;
    string failureOutput;
    foreach (round; 0 .. warmup + runs) {
        auto stopWatch = StopWatch(AutoStart.yes);

        const result = dub
            ? runDubTest(directory)
            : runBareFullCycle(sources, tmpBinary);
        const elapsed = stopWatch.elapsedMilliseconds;

        if (round >= warmup) {
            times ~= elapsed - report.compile;

            size_t passedByRunner, totalByRunner;
            if (parseUnitThreadedSummary(result.output, passedByRunner, totalByRunner)) {
                haveGranularCount = true;
                granularPassed = passedByRunner;
            }

            if (!result.passed) {
                allPassed = false;
                if (failureOutput.length == 0)
                    failureOutput = result.output;
            }
        }
    }

    fillTimingStatistics(report, times);
    report.passed = haveGranularCount ? granularPassed : (allPassed ? report.total : 0);
    report.ramBytes = childrenPeakRssBytes;

    if (failureOutput.length)
        stderr.writeln("dmd oracle failed; its output:\n", failureOutput);

    return report;
}

// The shared baseline subtracted from the full-cycle time above: `-o-`
// suppresses codegen, so this is as close to parse+sema-only as raw dmd
// gets.
private void dmdParseOnly(in SourceSet sources) {
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.process: execute;

    execute(
        ["dmd", "-o-"]
        ~ sources.flags.compilerArguments
        ~ sources.importPaths.map!(path => "-I" ~ path).array
        ~ sources.files,
    );
}

// A full-cycle round: whether the project's own test runner (invoked below)
// reported success, and what it printed - `execute` merges stdout/stderr,
// which is where druntime's and unit-threaded's own summaries land.
private struct RoundResult {
    bool passed;
    string output;
}

// The real workflow for a dub project: exactly what a developer runs, never
// `$DC` (see snakebite.dub's rationale for always using dmd here). `--force`
// is needed too: without it, dub's up-to-date check skips rebuilding after
// the first round and every later round would measure a bare re-run, not
// the build+link+run cycle the dmd row is meant to report.
private RoundResult runDubTest(in string directory) {
    import std.process: Config, execute;

    const result = execute(
        ["dub", "test", "--compiler=dmd", "--force"],
        null, Config.none, size_t.max, directory,
    );
    return RoundResult(result.status == 0, result.output);
}

// The real workflow for a bare directory: no dub to shell out to, so this is
// a straight `-unittest -main` build followed by running the binary.
private RoundResult runBareFullCycle(in SourceSet sources, in string outputPath) {
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.process: execute;

    const build = execute(
        ["dmd", "-unittest", "-main", "-of=" ~ outputPath]
        ~ sources.flags.compilerArguments
        ~ sources.importPaths.map!(path => "-I" ~ path).array
        ~ sources.files,
    );
    if (build.status != 0)
        return RoundResult(false, build.output);

    const run = execute([outputPath]);
    return RoundResult(run.status == 0, run.output);
}

// unit-threaded's own summary line ("17 test(s) run, 0 failed."), giving a
// real pass count where druntime's default runner only gives per-module
// success/failure. No match (druntime, or any other runner) means the
// caller falls back to exit-status-only.
private bool parseUnitThreadedSummary(
    in string output,
    out size_t passed,
    out size_t total,
) {
    import std.conv: to;
    import std.regex: matchFirst, regex;

    static summaryPattern = regex(`(\d+) test\(s\) run, (\d+) failed`);
    const match = output.matchFirst(summaryPattern);
    if (match.empty)
        return false;

    total = match[1].to!size_t;
    const failed = match[2].to!size_t;
    passed = total - failed;
    return true;
}

// The peak RSS of every subprocess dmdReport has spawned and waited on so
// far, via getrusage - simpler than wait4 (unbound in this druntime) and
// portable. ru_maxrss is in KiB on Linux.
private long childrenPeakRssBytes() {
    import core.sys.posix.sys.resource: getrusage, rusage, RUSAGE_CHILDREN;

    rusage usage;
    getrusage(RUSAGE_CHILDREN, &usage);
    return usage.ru_maxrss * 1024;
}

private enum backendName(BackendType) =
    imported!"std.uni".toLower(BackendType.stringof);

// Not a `Backend` (see `dmdReport`), so it needs its own entry: `-b dmd`
// selects it the same way `-b ctfe` selects a real backend.
private enum oracleName = "dmd";

private enum knownBackendNames = () {
    string[] names;
    static foreach (BackendType; imported!"snakebite.backends".Backends)
        names ~= backendName!BackendType;
    names ~= oracleName;
    return names;
}();

private bool selected(BackendType)(in string[] filter) {
    import std.algorithm.searching: canFind;

    return filter.length == 0 || filter.canFind(backendName!BackendType);
}

private string headerLine(
    in Example example,
    in uint warmup,
    in uint runs,
) {
    import std.conv: text;

    return text(
        example.name,
        "   ", example.tests.length, " tests",
        "   frontend ", milliseconds(example.frontendMilliseconds),
        "   ", hostCompiler,
        "   ", gitCommit,
        "   ", warmup, "+", runs, " runs",
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

// The snakebite commit next to this binary, so a saved benchmark line
// identifies what it measured. The working tree may be dirty; the commit is
// still the closest stable identity there is.
private string gitCommit() {
    import std.file: thisExePath;
    import std.path: dirName;
    import std.process: execute;
    import std.string: strip;

    const result = execute([
        "git", "-C", thisExePath.dirName, "rev-parse", "--short=8", "HEAD",
    ]);
    return result.status == 0 ? result.output.strip : "unknown";
}

private string defaultExampleDirectory() {
    import std.file: thisExePath;
    import std.path: buildNormalizedPath, dirName;

    return thisExePath.dirName.buildNormalizedPath("..", "examples", "ct");
}

private void printTable(in BackendReport[] reports) {
    import std.algorithm.comparison: max;
    import std.algorithm.searching: find;
    import std.array: replicate;
    import std.conv: text;
    import std.format: format;
    import std.math: isNaN;
    import std.range: empty, front, walkLength;
    import std.stdio: writeln;

    const oracle = reports.find!(report => report.isOracle);
    // Absent (e.g. `-b ctfe` excludes it) means nothing to cross-check
    // against, not a failure.
    const oracleFailed = !oracle.empty && oracle.front.passed != oracle.front.total;

    string[][] rows = [
        ["backend", "pass", "min", "median", "σ", "compile", "RAM"],
    ];
    foreach (report; reports) {
        // The oracle has no per-test granularity: exit-status only, so a
        // failure can't be expressed as a partial pass count.
        string passCell = report.isOracle && report.passed != report.total
            ? "FAIL"
            : text(report.passed, "/", report.total);
        // A backend claiming a clean run while the oracle itself failed is
        // unverified, not confirmed correct.
        if (oracleFailed && !report.isOracle && report.passed == report.total)
            passCell ~= " *";

        rows ~= [
            report.name,
            passCell,
            milliseconds(report.minimum),
            milliseconds(report.median),
            format!"%.1f"(report.sigma),
            report.compile.isNaN ? "-" : milliseconds(report.compile),
            memory(report.ramBytes),
        ];
    }

    size_t[] widths = new size_t[rows[0].length];
    foreach (row; rows)
        foreach (i, cell; row)
            widths[i] = max(widths[i], cell.walkLength);

    foreach (row; rows) {
        string line;
        foreach (i, cell; row) {
            const padding = " ".replicate(widths[i] - cell.walkLength);
            line ~= i == 0 ? cell ~ padding : "  " ~ padding ~ cell;
        }
        writeln(line);
    }

    if (oracleFailed)
        writeln("\n* dmd oracle failed this run; pass counts unverified");
}

private double elapsedMilliseconds(
    in imported!"std.datetime.stopwatch".StopWatch stopWatch,
) {
    return stopWatch.peek.total!"usecs" / 1000.0;
}

private double standardDeviation(in double[] values) {
    import std.algorithm.iteration: map, sum;
    import std.math: sqrt;

    if (values.length < 2)
        return 0;

    const mean = values.sum / values.length;
    const variance =
        values.map!(value => (value - mean) ^^ 2).sum / (values.length - 1);
    return variance.sqrt;
}

private string milliseconds(in double value) {
    import std.format: format;

    return format!"%.1f ms"(value);
}

private string memory(in long bytes) {
    import std.format: format;

    if (bytes >= 1024 * 1024)
        return format!"%.1f MiB"(bytes / (1024.0 * 1024.0));
    if (bytes >= 1024)
        return format!"%.0f KiB"(bytes / 1024.0);
    return format!"%d B"(bytes);
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

// Holds the saved stderr file descriptor while fd 2 points at /dev/null.
private struct SilencedStderr {
    private int _saved = -1;

    public void restore() @trusted nothrow @nogc {
        import core.stdc.stdio: fflush, stderr;
        import core.sys.posix.unistd: close, dup2;

        if (_saved < 0)
            return;

        fflush(stderr);
        dup2(_saved, 2);
        close(_saved);
        _saved = -1;
    }
}

// @trusted: dup/dup2/open/close operate only on file descriptors this
// function owns; a failed setup leaves stderr untouched with _saved == -1 so
// restore is a no-op.
private SilencedStderr silencedStderr() @trusted nothrow @nogc {
    import core.stdc.stdio: fflush, stderr;
    import core.sys.posix.fcntl: O_WRONLY, open;
    import core.sys.posix.unistd: close, dup, dup2;

    const sink = open("/dev/null", O_WRONLY);
    if (sink < 0)
        return SilencedStderr.init;

    SilencedStderr silenced;
    fflush(stderr);
    silenced._saved = dup(2);
    dup2(sink, 2);
    close(sink);

    return silenced;
}
