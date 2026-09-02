module ut.bench.measurement;


import bench.measurement: BackendRound, measureBackend;
import core.time: Duration, dur, msecs;
import snakebite.backends.backend: CompilationStatistics;
import ut;


@("reports.includeTotalTime")
unittest {
    string[] events;
    size_t statisticsIndex;

    auto elapsed(scope void delegate() operation) {
        events ~= "elapsed";
        operation();
        return 15.msecs;
    }

    auto construct() {
        events ~= "construct";
    }

    auto statistics() {
        events ~= "statistics";
        auto result = CompilationStatistics( // const makes its fields unusable.
            true,
            0,
            statisticsIndex++ % 2 ? 10.msecs : 5.msecs,
        );
        return result;
    }

    auto run() {
        events ~= "run";
        return BackendRound(0, "1 test(s) run, 0 failed.\n");
    }

    auto measure(in uint warmup, in uint runs) {
        return measureBackend(
            &elapsed,
            &construct,
            &statistics,
            &run,
            (string) {},
            "fake",
            warmup,
            runs,
        );
    }

    const cold = measure(0, 1);
    const repeated = measure(1, 10);

    cold.runTime.median.shouldEqual(15.msecs);
    repeated.runTime.median.shouldEqual(15.msecs);
    cold.compileTime.median.shouldEqual(5.msecs);
    repeated.compileTime.median.shouldEqual(5.msecs);
    (cold.runTime.median >= cold.compileTime.median).shouldBeTrue;
    (repeated.runTime.median >= repeated.compileTime.median).shouldBeTrue;
    cold.passCount.shouldEqual(1);
    cold.totalCount.shouldEqual(1);
    repeated.passCount.shouldEqual(1);
    repeated.totalCount.shouldEqual(1);

    events[0 .. 6].shouldEqual([
        "elapsed", "construct", "statistics", "run", "statistics", "elapsed",
    ]);
}
