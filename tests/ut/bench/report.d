module ut.bench.report;


import bench.report: BackendReport, updateTestCounts;
import core.time: msecs;
import ut;


@("inProcessSummary.providesCounts")
unittest {
    BackendReport report;

    report.updateTestCounts("22 test(s) run, 0 failed.\n");

    report.haveCounts.shouldBeTrue;
    report.passCount.shouldEqual(22);
    report.totalCount.shouldEqual(22);
}


@("compileSummary.providesMinimumAndMedian")
unittest {
    import bench.report: timingStatistics;

    const statistics = timingStatistics([3.msecs, 1.msecs, 2.msecs]);

    statistics.minimum.shouldEqual(1.msecs);
    statistics.median.shouldEqual(2.msecs);
    statistics.sigma.shouldEqual(1.msecs);
}


@("inProcessSummary.capturesNativeStdout")
unittest {
    import bench.capture: captureStdout;
    import core.sys.posix.unistd: systemWrite = write, STDOUT_FILENO;
    import std.algorithm.searching: canFind;

    enum summary = "22 test(s) run, 0 failed.\n";
    const result = captureStdout({
        return cast(int) systemWrite(
            STDOUT_FILENO, summary.ptr, summary.length,
        );
    });

    result.status.shouldEqual(summary.length);
    result.output.canFind(summary).shouldBeTrue;
}
