module ut.bench.report;


import bench.report: BackendReport, updateTestCounts;
import core.time: dur, hnsecs, msecs;
import ut;


@("inProcessSummary.providesCounts")
unittest {
    BackendReport report;

    report.updateTestCounts("22 test(s) run, 0 failed.\n");

    report.haveCounts.should == true;
    report.passCount.should == 22;
    report.totalCount.should == 22;
}


@("compileSummary.providesMinimumAndMedian")
unittest {
    import bench.report: timingStatistics;

    const statistics = timingStatistics([3.msecs, 1.msecs, 2.msecs]);

    statistics.minimum.should == 1.msecs;
    statistics.median.should == 2.msecs;
    statistics.sigma.should == 1.msecs;
}


@("milliseconds.doesNotRoundNonzeroToZero")
unittest {
    import bench.report: milliseconds;

    milliseconds(1.hnsecs).should == "0.1 us";
    milliseconds(dur!"usecs"(1)).should == "1.0 us";
    milliseconds(1.msecs).should == "1.0 ms";
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

    result.status.should == summary.length;
    result.output.canFind(summary).should == true;
}
