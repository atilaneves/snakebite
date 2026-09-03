module bench.oracle;


import bench.report: BackendReport, updateTestCounts;
import bench.sources: SourceSet;
import core.time: Duration;


// Not a `Backend` (see `oracleReport`), so it needs its own entry in the
// backend name list: `-b dmd` selects it the same way `-b ctfe` selects a
// real backend.
enum oracleName = "dmd";

// Not a `Backend`: the real workflow, spawned as subprocesses, always the
// `dmd` binary (never `$DC`) so the numbers don't shift with CI's compiler
// matrix. `dmd -o-` (parse+sema) is measured once as the `compile` cell,
// mirroring the in-process backends' compile step. Each `run` measurement is
// the complete developer edit-to-test cycle, including compilation, as it is
// for the in-process backends.
//
// For a dub project the cycle is: a throw-away `dub test` build first so the
// dependencies are compiled and cached, then per round touch a project
// source file and run plain `dub test` - dub rebuilds only the project, as
// it would after a real edit. (`--force` would instead rebuild every
// dependency each round and measure that.) For a bare directory the cycle
// is a straight `dmd -unittest -main` build followed by running the binary.
//
// Doubles as the correctness oracle. Its pass cell has real counts only
// when the project's own test runner reports them (unit-threaded's summary
// line); druntime's default runner is per-module, so there the verdict is
// the exit status alone.
BackendReport oracleReport(
    in SourceSet sources,
    in string directory,
    in uint warmup,
    in uint runs,
) {
    import bench.report: timingStatistics;
    import bench.sources: isDubProject;
    import std.conv: text;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.file: exists, remove, tempDir;
    import std.path: buildPath;
    import std.process: thisProcessID;
    import std.stdio: stderr;

    const dub = isDubProject(directory);

    BackendReport report;
    // The row's name reflects what's actually spawned and timed for the
    // full cycle: `dub test` (dub's own overhead included - that's the
    // real experience) for a dub project, raw `dmd` for a bare directory.
    // `-b dmd` still selects this row either way; see `oracleName`.
    report.name = dub ? "dub" : "dmd";
    report.isOracle = true;
    report.hasCompile = true;

    const tmpBinary =
        buildPath(tempDir, "snakebite-bench-dmd-" ~ thisProcessID.text);
    scope(exit)
        if (tmpBinary.exists)
            tmpBinary.remove;

    if (dub)
        throwawayDubTestBuild(directory);

    Duration[] compileTimes;
    Duration[] times;
    report.passed = true;
    string failureOutput;
    foreach (round; 0 .. warmup + runs) {
        // Touching every source guarantees a project rebuild no matter
        // which files the test configuration actually includes (dub's
        // synthesized one excludes the main source file, for instance).
        if (dub)
            foreach (file; sources.files)
                touch(file);

        auto compileWatch = StopWatch(AutoStart.yes);
        dmdParseOnly(sources);
        const compileElapsed = compileWatch.peek;

        auto stopWatch = StopWatch(AutoStart.yes);
        const result = dub
            ? run(["dub", "test", "--compiler=dmd"], directory)
            : bareFullCycle(sources, tmpBinary);
        const elapsed = stopWatch.peek;

        if (round < warmup)
            continue;

        compileTimes ~= compileElapsed;
        times ~= elapsed;

        if (result.ramBytes > report.ramBytes)
            report.ramBytes = result.ramBytes;

        report.updateTestCounts(result.stdout_);

        if (result.status != 0) {
            report.passed = false;
            if (failureOutput.length == 0)
                failureOutput =
                    result.stderr_.length ? result.stderr_ : result.stdout_;
        }
    }

    report.compileTime = timingStatistics(compileTimes);
    report.runTime = timingStatistics(times);

    if (failureOutput.length)
        stderr.writeln("dmd oracle failed; its output:\n", failureOutput);

    return report;
}

// The shared baseline subtracted from the full-cycle time above: `-o-`
// suppresses codegen, so this is as close to parse+sema-only as raw dmd
// gets.
private void dmdParseOnly(in SourceSet sources) {
    run(["dmd", "-o-"] ~ dmdArguments(sources) ~ sources.files);
}

// Builds the dependencies (and the project) once so the timed rounds only
// rebuild the project, as a real edit would.
private void throwawayDubTestBuild(in string directory) {
    run(["dub", "test", "--compiler=dmd"], directory);
}

// The bare-directory cycle: no dub, so a straight `-unittest -main` build
// followed by running the binary. A failed build is the round's result; the
// binary never ran.
private ProcessResult bareFullCycle(in SourceSet sources, in string outputPath) {
    const build = run(
        ["dmd", "-unittest", "-main", "-of=" ~ outputPath]
        ~ dmdArguments(sources)
        ~ sources.files,
    );
    if (build.status != 0)
        return build;

    auto result = run([outputPath]);
    if (build.ramBytes > result.ramBytes)
        result.ramBytes = build.ramBytes;
    return result;
}

private string[] dmdArguments(in SourceSet sources) {
    import std.algorithm.iteration: map;
    import std.array: array;

    return sources.flags.compilerArguments.dup
        ~ sources.importPaths.map!(path => "-I" ~ path).array
        ~ sources.stringImportPaths.map!(path => "-J" ~ path).array
        ~ sources.linkerFlags.map!(flag => "-L" ~ flag).array;
}

private struct ProcessResult {
    int status;
    string stdout_;
    string stderr_;
    long ramBytes;
}

// The two streams stay separate: the test runner's summary is parsed from
// stdout, while stderr carries the diagnostics worth showing on failure.
// Temp files rather than pipes, so a chatty child can never deadlock on a
// full pipe buffer.
//
// The command runs under `/usr/bin/time -v`, its own report going to a
// third file so it never mixes into the command's real output; `time`
// propagates the command's own exit status. This process (holding a parsed
// frontend, possibly a whole `Program`) can be memory-heavy itself, and
// `getrusage(RUSAGE_CHILDREN)` measured directly from it is unusable: a
// forked child inherits the parent's resident pages copy-on-write, and that
// briefly-shared memory counts toward the child's reported peak too - a
// small `dmd` invocation read back as using a gigabyte. `time` is a
// lightweight process with nothing of its own to inherit, so what it
// reports for its child is the child's actual usage.
private ProcessResult run(in string[] command, in string workDir = null) {
    import std.conv: text, to;
    import std.file: readText, remove, tempDir;
    import std.path: buildPath;
    import std.process: spawnProcess, thisProcessID, wait;
    import std.regex: matchFirst, regex;
    import std.stdio: File, stdin;

    const prefix = buildPath(
        tempDir, "snakebite-bench-capture-" ~ thisProcessID.text,
    );
    const stdoutPath = prefix ~ ".out";
    const stderrPath = prefix ~ ".err";
    const timePath = prefix ~ ".time";
    scope(exit) {
        stdoutPath.remove;
        stderrPath.remove;
        timePath.remove;
    }

    auto stdoutFile = File(stdoutPath, "w");
    auto stderrFile = File(stderrPath, "w");
    auto pid = spawnProcess(
        ["/usr/bin/time", "-v", "-o", timePath] ~ command,
        stdin, stdoutFile, stderrFile, null,
        imported!"std.process".Config.none, workDir,
    );
    const status = wait(pid);
    stdoutFile.close;
    stderrFile.close;

    long ramBytes;
    static rssPattern = regex(`Maximum resident set size \(kbytes\): (\d+)`);
    const match = timePath.readText.matchFirst(rssPattern);
    if (!match.empty)
        ramBytes = match[1].to!long * 1024;

    return ProcessResult(status, readText(stdoutPath), readText(stderrPath), ramBytes);
}

// Makes the file newer than its build products, so the next `dub test`
// rebuilds the project the way it would after a real edit.
private void touch(in string path) {
    import std.datetime.systime: Clock;
    import std.file: setTimes;

    const now = Clock.currTime;
    setTimes(path, now, now);
}
