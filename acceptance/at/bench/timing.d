module at.bench.timing;


import bench.benchmark: benchmark;
import bench.oracle: oracleReport;
import bench.report: timingStatistics;
import bench.sources: sourceSet;
import core.time: Duration;
import snakebite.backends: Backends, Program;
import snakebite.frontend.compiler: parseSnippets;
import std.conv: text;
import std.datetime.stopwatch: AutoStart, StopWatch;
import std.datetime.systime: Clock;
import std.file: exists, getcwd, remove, setTimes;
import std.path: buildPath;
import std.process: Config, execute;
import std.stdio: writefln;
import unit_threaded;


@("runTime.isConsistentAcrossRunCounts")
@Serial
@Tags("timing")
unittest {
    string source = "module benchmarkTimingConsistency; int main() { ";
    source ~= "int sum; for (int i; i < 10_000; ++i) sum += i; ";
    source ~= "return sum == 49_995_000 ? 0 : 1; } ";
    source ~= "void unused() { if (false) {";
    foreach (i; 0 .. 1_000)
        source ~= text("int local", i, " = ", i, ";");
    source ~= "}}";

    auto module_ = parseSnippets([source])[0];
    auto program = Program([module_]);

    static foreach (BackendType; Backends) {{
        const singleRun = benchmark!BackendType(
            BackendType.stringof,
            program,
            0,
            1,
        );
        const repeatedRuns = benchmark!BackendType(
            BackendType.stringof,
            program,
            2,
            10,
        );

        const singleMedian = singleRun.runTime.median.total!"hnsecs";
        const repeatedMedian = repeatedRuns.runTime.median.total!"hnsecs";
        enum tolerance = 5;
        singleMedian.shouldBeGreaterThan(repeatedMedian / tolerance);
        repeatedMedian.shouldBeGreaterThan(singleMedian / tolerance);
    }}
}


@("dub.runTime.matchesTouchedTestCycle")
@Flaky(5)
@Serial
@Tags("timing")
unittest {
    const directory = buildPath(getcwd, "examples", "ct-full");
    const objectFile = buildPath(directory, "ct-full-test-application.o");
    const objectFileExisted = objectFile.exists;
    scope(exit)
        if (!objectFileExisted && objectFile.exists)
            objectFile.remove;

    enum runs = 3;
    directDubTest(directory);
    Duration[] directTimes;
    foreach (_; 0 .. runs)
        directTimes ~= directDubTest(directory);

    const sources = sourceSet(directory, null, null);
    const report = oracleReport(sources, directory, 1, runs);
    report.passed.should == true;

    const direct = timingStatistics(directTimes).median;
    const benchmark = report.runTime.median;
    const ratio = benchmark.total!"hnsecs"
        / cast(double) direct.total!"hnsecs";
    writefln(
        "  direct %.1f ms, benchmark %.1f ms, ratio %.2fx",
        direct.total!"hnsecs" / 10_000.0,
        benchmark.total!"hnsecs" / 10_000.0,
        ratio,
    );

    enum tolerance = 1.5;
    assert(
        ratio >= 1.0 / tolerance && ratio <= tolerance,
        text(
            "benchmark latency is not within ", tolerance,
            " times the direct touch and dub test latency",
        ),
    );
}


private Duration directDubTest(in string directory) {
    const testFile = buildPath(directory, "source", "perf.d");
    touch(testFile);

    auto stopWatch = StopWatch(AutoStart.yes);
    const result = execute(
        ["dub", "test", "--compiler=dmd"],
        null,
        Config.none,
        size_t.max,
        directory,
    );
    const elapsed = stopWatch.peek;
    assert(result.status == 0, result.output);
    return elapsed;
}


private void touch(in string path) {
    const now = Clock.currTime;
    setTimes(path, now, now);
}
