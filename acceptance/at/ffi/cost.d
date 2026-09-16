module at.ffi.cost;


import unit_threaded;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


extern(C) int abs(int);

private alias Native = extern(C) int function(int);

// Resolved at run time through `dlsym`, the same route the barrier itself
// uses to find a symbol. `__gshared` and filled once, so no optimiser can
// see `&abs` at compile time and turn the "indirect" baseline call into a
// direct one - which is what LDC's `-release -O` build did with
// `cast(Native) &abs` as a compile-time constant, making the baseline loop
// measure nothing at all.
private __gshared Native directAbs;


// What crossing the barrier costs, against the cheapest thing that could
// possibly cross it: a bare indirect call through a function pointer to the
// same `abs`. That is the shape the barrier performs minus its bookkeeping,
// so the gap between the two *is* the bookkeeping.
//
// A ratio rather than a time: both are measured in the same process, build
// and run, so machine speed, cache state and optimisation level move them
// together and cancel. A threshold in nanoseconds would not survive a
// different machine, and would say nothing about what the barrier itself
// adds.
//
// The plan is prepared before the measured loops. This keeps the timing
// gate focused on the steady-state call and removes the cold-path lookup.
//
// `bin/at` is built with LDC's `-release -O -flto=thin`, the same flags
// as `bin/sb`. This test's own ratio depends on that: an unoptimised
// build cannot inline or fold either loop, so the gap between a generic
// replay and a direct call is only meaningful with the optimiser on.
// An unoptimised build would show noise instead of the barrier's own
// cost, and the gate below would reject good builds for the wrong
// reason.
@("barrier.overhead")
@Flaky(5)
@Tags("timing")
unittest {
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.algorithm: sort;
    import std.stdio: writefln;

    auto guestModule = parseSnippet(q{
        extern(C) int abs(int);
    });
    auto function_ = findFunction(guestModule, "abs");
    assert(function_ !is null, "No function `abs` in the guest program");

    // Pin this thread to one core, then put the old mask back on exit.
    // A core migration mid-loop moves the tight loop to a cold cache.
    // That cost lands on baseline or barrier, whichever runs at that
    // moment, and the ratio then reports it as the barrier's own cost.
    // `bin/at` runs test modules on a pool of worker threads. A mask
    // left pinned would follow the worker into every later test, and
    // could pin two workers to the same core.
    version (linux) {
        import core.sys.linux.sched:
            cpu_set_t, CPU_SET, sched_getaffinity, sched_setaffinity;

        cpu_set_t oldMask;
        const savedMask =
            sched_getaffinity(0, cpu_set_t.sizeof, &oldMask) == 0;
        scope(exit) if (savedMask)
            cast(void) sched_setaffinity(0, cpu_set_t.sizeof, &oldMask);

        // `sched_getcpu` exists only for glibc and musl. `version
        // (linux)` alone covers other C runtimes too, so it is not
        // enough of a guard for this one function.
        version (CRuntime_Glibc) enum canPin = true;
        else version (CRuntime_Musl) enum canPin = true;
        else enum canPin = false;

        static if (canPin) {
            import core.sys.linux.sched: sched_getcpu;

            const cpu = sched_getcpu();
            if (cpu >= 0) {
                cpu_set_t mask;
                CPU_SET(cpu, &mask);
                if (sched_setaffinity(0, cpu_set_t.sizeof, &mask) != 0)
                    writefln("  warning: could not pin to core %d", cpu);
            } else {
                writefln("  warning: sched_getcpu failed; running unpinned");
            }
        } else {
            writefln(
                "  warning: this C runtime has no sched_getcpu; " ~
                "running unpinned");
        }
    } else {
        writefln(
            "  warning: no CPU pinning on this platform; the gate's " ~
            "bound assumes pinning");
    }

    // Enough iterations for a stable ratio and no more: this runs in
    // `ci.sh` on every build, so it buys its stability cheaply.
    enum n = 1_000_000;
    enum batch = 1_000;

    // Both loops do the same work either side of the barrier: read one
    // `int` argument from a slot, call `abs`, keep the result. The plan is
    // prepared before the loops, so only the barrier's execution differs.
    int argument = -42;
    int result;

    if (directAbs is null) {
        import core.sys.posix.dlfcn: dlsym;

        version (linux)
            import core.sys.linux.dlfcn: RTLD_DEFAULT;
        else
            import core.sys.posix.dlfcn: RTLD_DEFAULT;

        auto address = dlsym(RTLD_DEFAULT, "abs");
        assert(address !is null, "dlsym could not find `abs`");
        directAbs = cast(Native) address;
    }
    auto direct = directAbs;

    // The slot array is built once, outside both loops: a `[&argument]`
    // literal per iteration would allocate, and that allocation would be
    // measured as if the barrier had cost it.
    const(void)*[1] slots = [&argument];
    const int* directArgument = cast(const int*) slots[0];

    PlanCache cache;
    const plan = cache.of(function_);

    foreach (i; 0 .. 2_000) {
        cast(void) direct(argument);
        plan.call(&result, slots[]);
    }

    // Time each batch on its own, and keep the smallest batch time on
    // each side. A busy sibling core slows the cheap baseline loop more
    // than it slows the barrier loop, so the total time for each side
    // no longer scales the same way under load. Measured on
    // 2026-09-16: dividing the two totals read 4.0x alone but 1.68x
    // next to `at.bench.timing`, the real condition inside `bin/at` -
    // the same build, the same barrier, no change but the load.
    //
    // The smallest batch on each side is the batch that saw the least
    // contention. There are `n / batch` batches per round, interleaved
    // baseline then barrier, so both sides get an uncontended batch in
    // the same short window. Dividing the two smallest times then
    // stays close to the clean ratio, even under load.
    //
    // This is not the smallest of several ratios, which the old code
    // used to reject for good reason: that divides one noisy number by
    // another noisy number. Taking the minimum on each side first, and
    // dividing only once, removes the noise before the division.
    size_t sink;
    struct Round { double baseline; double barrier; double ratio; }
    Round[15] rounds;
    auto watch = StopWatch(AutoStart.no);
    foreach (sample; 0 .. rounds.length) {
        double baselineFloor = double.infinity;
        double barrierFloor = double.infinity;
        foreach (_; 0 .. n / batch) {
            watch.reset;
            watch.start;
            foreach (i; 0 .. batch) {
                result = direct(*directArgument);
                sink += cast(size_t) result;
            }
            watch.stop;
            const baselineBatch =
                watch.peek.total!"nsecs" / cast(double) batch;
            if (baselineBatch < baselineFloor)
                baselineFloor = baselineBatch;

            watch.reset;
            watch.start;
            foreach (i; 0 .. batch) {
                plan.call(&result, slots[]);
                sink += cast(size_t) result;
            }
            watch.stop;
            const barrierBatch =
                watch.peek.total!"nsecs" / cast(double) batch;
            if (barrierBatch < barrierFloor)
                barrierFloor = barrierBatch;
        }
        rounds[sample] =
            Round(baselineFloor, barrierFloor, barrierFloor / baselineFloor);
    }
    // 15 rounds, not 5: pinning (above) removes almost all of the
    // noise, but a handful of extra rounds is cheap insurance against
    // whatever pinning does not catch - a pause for a signal, a page
    // fault, a GC collection triggered elsewhere in the process.
    //
    // Sort by ratio, and read the median round as a whole. Sorting
    // each column on its own, as the old code did, prints a baseline
    // and a barrier that never shared a round with the printed ratio.
    sort!((a, b) => a.ratio < b.ratio)(rounds[]);
    const median = rounds.length / 2;
    writefln("  baseline %5.2f ns, barrier %5.2f ns, median-of-%d ratio %.6fx",
        rounds[median].baseline, rounds[median].barrier, rounds.length,
        rounds[median].ratio);

    result.should == 42;
    // `-release` strips `assert`, so this stays a `should` check: without
    // it, an optimiser that folds the baseline loop away would pass silently.
    sink.should.not == 0;

    // maxRatio is set from the floor above, not from a total. Measured
    // on 2026-09-16, `timeout 120 bin/at -d at.ffi.cost.barrier.overhead`,
    // on a machine already busy with other work (load average 6 to 28):
    //
    //   alone, 5 runs:                                 floor ratio 3.56-3.67x
    //   next to `at.bench.timing` (`bin/at`'s real mix), 5 runs: 3.56x
    //
    // The floor stays close to 3.6x in both conditions. Load no longer
    // moves it the way it moved the old ratio of totals (see above).
    //
    // A barrier with its dispatch doubled (one extra call to `_entry`
    // in `plan.d`, reverted before this commit) read a floor ratio of
    // 5.2-5.4x, alone and next to `at.bench.timing` alike, 3 runs each.
    // Clean and doubled stay apart by a wide margin in both conditions,
    // so 4.5 sits safely between them and stays a useful bound.
    //
    // `build/ci.sh` runs `bin/at -s '@timing'` on its own, after the
    // rest of the suite, so this test never shares the machine with
    // `bin/at`'s other, non-timing acceptance tests either.
    enum maxRatio = 4.5;
    // `-release` strips `assert`, so the gate is a `should` check, not an
    // `assert`. `bin/at` is always built with `-O`, so the ratio measures
    // the barrier itself rather than the cost of an unoptimised build.
    //
    // `shouldBeSmallerThan`, not a `<` operator, because unit-threaded's
    // `should` proxy has no `<`: `double.should < x` does not compile
    // (relational operators route through `opCmp`, which `Should` does
    // not define), so this stays the free-function form.
    rounds[median].ratio.shouldBeSmallerThan(maxRatio);
}
