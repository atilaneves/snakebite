module ut.bench.measurement;


import bench.measurement: BackendRound, measureBackend;
import core.time: Duration, MonoTime, dur, msecs;
import snakebite.backends.backend: CompilationStatistics;
import ut;


@("reports.includeTotalTime")
unittest {
    string[] events;
    size_t clockIndex;
    auto timestamps = [ // const causes a delegate-result type error here.
        MonoTime.zero,
        MonoTime.zero + 15.msecs,
        MonoTime.zero + 30.msecs,
        MonoTime.zero + 45.msecs,
        MonoTime.zero + 60.msecs,
        MonoTime.zero + 75.msecs,
        MonoTime.zero + 90.msecs,
        MonoTime.zero + 105.msecs,
        MonoTime.zero + 120.msecs,
        MonoTime.zero + 135.msecs,
        MonoTime.zero + 150.msecs,
        MonoTime.zero + 165.msecs,
        MonoTime.zero + 180.msecs,
        MonoTime.zero + 195.msecs,
        MonoTime.zero + 210.msecs,
        MonoTime.zero + 225.msecs,
        MonoTime.zero + 240.msecs,
        MonoTime.zero + 255.msecs,
        MonoTime.zero + 270.msecs,
        MonoTime.zero + 285.msecs,
        MonoTime.zero + 300.msecs,
        MonoTime.zero + 315.msecs,
        MonoTime.zero + 330.msecs,
        MonoTime.zero + 345.msecs,
    ];
    size_t statisticsIndex;

    auto clock() {
        events ~= "clock";
        return timestamps[clockIndex++];
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
            &clock,
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
        "clock", "construct", "statistics", "run", "clock", "statistics",
    ]);
}
