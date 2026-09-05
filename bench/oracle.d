module bench.oracle;


import bench.report: BackendReport, updateTestCounts;
import core.time: Duration;
import snakebite.project: SourceSet;


// Not a `Backend` (see `oracleReport`), so it needs its own entry in the
// backend name list: `-b dmd` selects it the same way `-b ctfe` selects a
// real backend.
enum oracleName = "dmd";

// Not a `Backend`: the real workflow, spawned as subprocesses, always the
// `dmd` binary (never `$DC`) so the numbers don't shift with CI's compiler
// matrix.
//
// Its cells mean what they mean in the in-process rows, so that the rows
// can be compared: `cmp` is what makes the analysed program runnable
// (codegen and the linker here, bytecode generation there), `run` is that
// plus running the tests, and what a cycle pays before either - the
// frontend, and dub itself for a dub project - is reported under the table
// the way the header reports it for the in-process rows. An edit-to-test
// cycle of `dub test` is one process, so the pieces come from timing four:
// `dub test` after touching the sources (the whole cycle), `dub test` again
// with nothing to rebuild (dub's overhead plus the run), `dmd -o-` on the
// same sources (as close to the frontend alone as raw dmd gets), and the
// test binary by itself. See `cyclePieces` for the arithmetic. A bare
// directory has no dub: a straight `dmd -unittest -main` build stands in
// for the touched cycle, and the untouched one is the binary run alone.
//
// A throw-away `dub test` build first so the dependencies are compiled and
// cached; every timed round then touches the project's sources so plain
// `dub test` rebuilds only the project, as it would after a real edit.
// (`--force` would instead rebuild every dependency each round and measure
// that.)
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
    import snakebite.project: isDubProject;
    import std.conv: text;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.file: exists, remove, tempDir;
    import std.path: buildPath;
    import std.process: thisProcessID;
    import std.stdio: stderr;

    const dub = isDubProject(directory);

    BackendReport report;
    // The row's name reflects what's actually spawned and timed: `dub test`
    // for a dub project, raw `dmd` for a bare directory. `-b dmd` still
    // selects this row either way; see `oracleName`.
    report.name = dub ? "dub" : "dmd";
    report.isOracle = true;
    report.hasCompile = true;
    report.cycleOverheadLabel = dub ? "dub overhead" : null;

    const tmpBinary =
        buildPath(tempDir, "snakebite-bench-dmd-" ~ thisProcessID.text);
    scope(exit)
        if (tmpBinary.exists)
            tmpBinary.remove;

    const binary = dub ? dubTestBinary(directory) : TestBinary(tmpBinary, null);
    if (dub)
        throwawayDubTestBuild(directory);

    Duration[] overheads;
    Duration[] frontends;
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

        auto frontendWatch = StopWatch(AutoStart.yes);
        dmdParseOnly(sources);
        const frontend = frontendWatch.peek;

        auto touchedWatch = StopWatch(AutoStart.yes);
        const result = dub
            ? run(["dub", "test", "--compiler=dmd"], directory)
            : bareBuild(sources, tmpBinary);
        const touched = touchedWatch.peek;

        // No build product to time after a failed build: the round's
        // verdict is the failure, its times are left out.
        if (result.status != 0) {
            report.passed = false;
            if (failureOutput.length == 0)
                failureOutput =
                    result.stderr_.length ? result.stderr_ : result.stdout_;
            continue;
        }

        auto binaryWatch = StopWatch(AutoStart.yes);
        const binaryRun = run([binary.path], binary.workingDirectory);
        const binaryElapsed = binaryWatch.peek;

        // The bare build does not run the tests, so its cycle is the
        // build plus the run, and with nothing to rebuild it is the run.
        Duration cycle = touched + binaryElapsed;
        Duration untouched = binaryElapsed;
        if (dub) {
            cycle = touched;
            auto untouchedWatch = StopWatch(AutoStart.yes);
            run(["dub", "test", "--compiler=dmd"], directory);
            untouched = untouchedWatch.peek;
        }

        if (round < warmup)
            continue;

        const pieces = cyclePieces(cycle, untouched, frontend, binaryElapsed);
        overheads ~= pieces.overhead;
        frontends ~= frontend;
        compileTimes ~= pieces.compile;
        times ~= pieces.run;

        // The build is the memory-hungry step for a dub project too: dub
        // spawns dmd, and `time -v` reports the largest of the tree.
        if (result.ramBytes > report.ramBytes)
            report.ramBytes = result.ramBytes;
        if (binaryRun.ramBytes > report.ramBytes)
            report.ramBytes = binaryRun.ramBytes;

        // The bare build does not run the tests: their output, and the
        // verdict, are the binary's.
        const tests = dub ? result : binaryRun;
        report.updateTestCounts(tests.stdout_);
        if (tests.status != 0) {
            report.passed = false;
            if (failureOutput.length == 0)
                failureOutput =
                    tests.stderr_.length ? tests.stderr_ : tests.stdout_;
        }
    }

    // Every round failed to build: nothing to summarise, the verdict says
    // it all.
    if (times.length) {
        report.cycleOverhead = timingStatistics(overheads);
        report.cycleFrontend = timingStatistics(frontends);
        report.compileTime = timingStatistics(compileTimes);
        report.runTime = timingStatistics(times);
    }

    if (failureOutput.length)
        stderr.writeln("dmd oracle failed; its output:\n", failureOutput);

    return report;
}

// What the row reports, from the four processes timed per round.
struct CyclePieces {
    // The tool's own cost per cycle: dub's, before and after the compiler
    // it spawns. Nothing for a bare directory.
    Duration overhead;
    // Codegen and the linker: the compile minus its frontend.
    Duration compile;
    // Compile plus running the tests, as `run` is for the in-process rows.
    Duration run;
}

// `touched` is the whole cycle, `untouched` the same cycle with nothing to
// rebuild (so the tool's overhead plus the run), `frontend` the parse and
// sema alone, and `binary` the test run alone. Noise can push a difference
// below zero on a project too small to measure; zero it is then.
CyclePieces cyclePieces(
    in Duration touched,
    in Duration untouched,
    in Duration frontend,
    in Duration binary,
) @safe pure nothrow {
    import core.time: Duration;

    static Duration atLeastZero(in Duration duration) {
        return duration < Duration.zero ? Duration.zero : duration;
    }

    const overhead = atLeastZero(untouched - binary);
    const compile = atLeastZero(touched - untouched - frontend);
    return CyclePieces(overhead, compile, compile + binary);
}

// `-o-` suppresses codegen, so this is as close to parse+sema-only as raw
// dmd gets: the frontend cost a cycle pays, reported apart from the
// compile like the header's `frontend` is for the in-process rows.
private void dmdParseOnly(in SourceSet sources) {
    run(["dmd", "-o-"] ~ dmdArguments(sources) ~ sources.files);
}

// Builds the dependencies (and the project) once so the timed rounds only
// rebuild the project, as a real edit would.
private void throwawayDubTestBuild(in string directory) {
    run(["dub", "test", "--compiler=dmd"], directory);
}

private struct TestBinary {
    string path;
    string workingDirectory;
}

// Where `dub test` leaves the test binary and where it runs it, so the run
// alone can be timed the way dub does it.
private TestBinary dubTestBinary(in string directory) {
    import snakebite.dub: DubConfig, dubDescribe;
    import std.path: buildPath;

    const described = dubDescribe(
        directory,
        ["target-path", "target-name", "working-directory"],
        DubConfig.test,
    );
    foreach (list; described)
        if (list.length == 0)
            throw new Exception(
                "dub describe did not say where the test binary of "
                ~ directory ~ " is",
            );
    return TestBinary(
        buildPath(described[0][0], described[1][0]),
        described[2][0],
    );
}

// The bare-directory build: no dub, so a straight `-unittest -main` build
// of the binary the round then runs.
private ProcessResult bareBuild(in SourceSet sources, in string outputPath) {
    return run(
        ["dmd", "-unittest", "-main", "-of=" ~ outputPath]
        ~ dmdArguments(sources)
        ~ sources.files,
    );
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
