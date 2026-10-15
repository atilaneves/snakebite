module bench.oracle;


import bench.capture: ProcessResult, run = captureProcess;
import bench.report: BackendReport, updateTestCounts;
import core.time: Duration;
import snakebite.project: SourceSet;


// Not a `Backend` (see `oracleReport`), so it needs its own entry in the
// backend name list: `-b dmd` selects it the same way `-b ctfe` selects a
// real backend.
enum oracleName = "dmd";

// Not a `Backend`: the real workflow, spawned as subprocesses, using
// `dmd` for a bare directory and dub's default compiler for a dub project.
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
    in string[] programArguments = null,
) {
    import bench.report: timingStatistics;
    import snakebite.project: isDubProject;
    import snakebite.dub: DubTestProduct, dubTestProduct;
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

    const binary = dub
        ? dubTestProduct(directory) : DubTestProduct(tmpBinary, directory);
    if (dub)
        throwawayDubTestBuild(directory, programArguments);

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
            ? run(dubTestCommand(programArguments), directory)
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
        const binaryRun = run([binary.path] ~ programArguments, binary.workingDirectory);
        const binaryElapsed = binaryWatch.peek;

        // The bare build does not run the tests, so its cycle is the
        // build plus the run, and with nothing to rebuild it is the run.
        Duration cycle = touched + binaryElapsed;
        Duration untouched = binaryElapsed;
        if (dub) {
            cycle = touched;
            auto untouchedWatch = StopWatch(AutoStart.yes);
            run(dubTestCommand(programArguments), directory);
            untouched = untouchedWatch.peek;
        }

        if (round < warmup)
            continue;

        const pieces = cyclePieces(cycle, untouched, frontend, binaryElapsed);
        overheads ~= pieces.overhead;
        frontends ~= frontend;
        compileTimes ~= pieces.compile;
        times ~= pieces.run;

        if (binaryRun.ramBytes > report.ramBytes)
            report.ramBytes = binaryRun.ramBytes;

        // The bare build does not run the tests: their output, and the
        // verdict, are the binary's.
        const tests = dub ? result : binaryRun;
        report.updateTestCounts(tests.stdout_);
        if (tests.status != 0 || binaryRun.status != 0) {
            report.passed = false;
            if (failureOutput.length == 0)
                failureOutput =
                    binaryRun.status != 0
                        ? binaryRun.stderr_ ~ binaryRun.stdout_
                        : tests.stderr_ ~ tests.stdout_;
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
private void throwawayDubTestBuild(
    in string directory,
    in string[] programArguments,
) {
    run(dubTestCommand(programArguments), directory);
}

// `dub test` hands everything after `--` to the test binary, so the row
// runs the tests with the same program arguments as the other rows.
private string[] dubTestCommand(in string[] programArguments) {
    return ["dub", "test"]
        ~ (programArguments.length ? "--" ~ programArguments : null);
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

// Makes the file newer than its build products, so the next `dub test`
// rebuilds the project the way it would after a real edit.
private void touch(in string path) {
    import std.datetime.systime: Clock;
    import std.file: setTimes;

    const now = Clock.currTime;
    setTimes(path, now, now);
}
