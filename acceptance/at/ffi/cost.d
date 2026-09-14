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

    PlanCache cache;
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
    const plan = cache.of(function_);

    foreach (i; 0 .. 2_000) {
        cast(void) direct(argument);
        plan.call(&result, slots[]);
    }

    size_t sink;
    double[5] baselines;
    double[5] barriers;
    double[5] ratios;
    foreach (sample; 0 .. ratios.length) {
        auto baselineWatch = StopWatch(AutoStart.no);
        auto barrierWatch = StopWatch(AutoStart.no);
        foreach (_; 0 .. n / batch) {
            baselineWatch.start;
            foreach (i; 0 .. batch) {
                result = direct(*directArgument);
                sink += cast(size_t) result;
            }
            baselineWatch.stop;

            barrierWatch.start;
            foreach (i; 0 .. batch) {
                plan.call(&result, slots[]);
                sink += cast(size_t) result;
            }
            barrierWatch.stop;
        }
        baselines[sample] = baselineWatch.peek.total!"nsecs"
            / cast(double) n;
        barriers[sample] = barrierWatch.peek.total!"nsecs"
            / cast(double) n;
        ratios[sample] = barriers[sample] / baselines[sample];
    }
    sort(baselines[]);
    sort(barriers[]);
    sort(ratios[]);
    writefln("  baseline %5.2f ns, barrier %5.2f ns, ratio %.6fx",
        baselines[2], barriers[2], ratios[2]);

    result.should == 42;
    // `-release` strips `assert`, so this stays a `should` check: without
    // it, an optimiser that folds the baseline loop away would pass silently.
    sink.should.not == 0;

    // Fixed from independent runs of a known-good revision: mean + 3 sample
    // standard deviations, rounded up. Do not let a candidate's own noise
    // raise its limit.
    //
    // Recalibrated against master (fe58792): 15 runs of `bin/at -d
    // at.ffi.cost` on an otherwise idle machine, one core pinned so the OS
    // could not migrate the tight timing loop mid-measurement - an unpinned
    // run can swap cores between the baseline half of a round and the
    // barrier half, which moves the printed ratio far more than the
    // barrier's own cost does. Printed ratios: 3.065571, 3.288746,
    // 3.291122, 3.293928, 3.294434, 3.295138, 3.297399, 3.298807, 3.300118,
    // 3.301615, 3.302570, 3.302705, 3.303412, 3.303819, 3.305789. Mean
    // 3.283, sample standard deviation 0.060, mean + 3 sd = 3.464, rounded
    // up to one decimal. The old 2.40 predated the optimised bin/at build
    // (see "Build the acceptance tests optimised"); it never matched this
    // build's own steady state and only passed when a retry got lucky.
    enum maxRatio = 3.5;
    // `-release` strips `assert`, so the gate is a `should` check, not an
    // `assert`. `bin/at` is always built with `-O`, so the ratio measures
    // the barrier itself rather than the cost of an unoptimised build.
    //
    // `shouldBeSmallerThan`, not a `<` operator, because unit-threaded's
    // `should` proxy has no `<`: `double.should < x` does not compile
    // (relational operators route through `opCmp`, which `Should` does
    // not define), so this stays the free-function form.
    ratios[2].shouldBeSmallerThan(maxRatio);
}
