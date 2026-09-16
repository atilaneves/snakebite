module ut.bench.report;


import bench.capture: captureStdout;
import bench.report:
    BackendReport, TimingStatistics, milliseconds, orderByMedianRunTime,
    timingStatistics, updateTestCounts;
import core.sys.posix.unistd: systemWrite = write, STDOUT_FILENO;
import core.time: dur, hnsecs, msecs;
import std.algorithm.iteration: map;
import std.algorithm.searching: canFind;
import std.stdio: File, stdout;
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
    const statistics = timingStatistics([3.msecs, 1.msecs, 2.msecs]);

    statistics.minimum.should == 1.msecs;
    statistics.median.should == 2.msecs;
    statistics.sigma.should == 1.msecs;
}


@("milliseconds.doesNotRoundNonzeroToZero")
unittest {
    milliseconds(1.hnsecs).should == "0.1 us";
    milliseconds(dur!"usecs"(1)).should == "1.0 us";
    milliseconds(1.msecs).should == "1.0 ms";
}


@("table.ordersBackendsByMedianRunTime")
unittest {
    BackendReport[] reports = [
        BackendReport(
            name: "slow",
            runTime: TimingStatistics(1.msecs, 3.msecs),
        ),
        BackendReport(
            name: "fast",
            runTime: TimingStatistics(3.msecs, 1.msecs),
        ),
    ];

    reports.orderByMedianRunTime.map!(report => report.name).should == [
        "fast", "slow",
    ];
}


@("inProcessSummary.capturesNativeStdout")
unittest {
    enum summary = "22 test(s) run, 0 failed.\n";
    const result = captureStdout({
        return cast(int) systemWrite(
            STDOUT_FILENO, summary.ptr, summary.length,
        );
    });

    result.status.should == summary.length;
    result.output.canFind(summary).should == true;
}

@("inProcessSummary.restoresReassignedStdout")
@Serial
unittest {
    auto original = stdout;
    scope(exit) stdout = original;
    auto redirected = File.tmpfile;
    captureStdout({
        stdout = redirected;
        return 0;
    });
    stdout.fileno.should == original.fileno;
}
