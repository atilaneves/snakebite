module at.ffi.cost;


import unit_threaded;
import snakebite.ffi: LibffiPlan;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


extern(C) int abs(int);

private alias Native = extern(C) int function(int);


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
// `bin/at` is built unoptimised, so neither number is a release figure.
// The ratio is what this asserts on, and it is meaningful either way.
@("barrier.overhead")
@Flaky(5)
@Tags("timing")
unittest {
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.algorithm: sort;
    import std.stdio: stderr;

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
    auto direct = cast(Native) &abs;
    auto libffiEager = new LibffiPlan(function_);
    auto libffiDeferred = new LibffiPlan(function_, true);

    // The slot array is built once, outside both loops: a `[&argument]`
    // literal per iteration would allocate, and that allocation would be
    // measured as if the barrier had cost it.
    const(void)*[1] slots = [&argument];
    const int* directArgument = cast(const int*) slots[0];
    const plan = cache.of(function_);

    foreach (i; 0 .. 2_000) {
        cast(void) direct(argument);
        plan.call(&result, slots[]);
        libffiEager.call(&result, slots[]);
        libffiDeferred.call(&result, slots[]);
    }

    size_t sink;
    double[5] baselines;
    double[5] barriers;
    double[5] libffiEagerTimes;
    double[5] libffiDeferredTimes;
    double[5] ratios;
    double[5] eagerRatios;
    double[5] deferredRatios;
    foreach (sample; 0 .. ratios.length) {
        auto baselineWatch = StopWatch(AutoStart.no);
        auto barrierWatch = StopWatch(AutoStart.no);
        auto libffiEagerWatch = StopWatch(AutoStart.no);
        auto libffiDeferredWatch = StopWatch(AutoStart.no);
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

            libffiEagerWatch.start;
            foreach (i; 0 .. batch) {
                libffiEager.call(&result, slots[]);
                sink += cast(size_t) result;
            }
            libffiEagerWatch.stop;

            libffiDeferredWatch.start;
            foreach (i; 0 .. batch) {
                libffiDeferred.call(&result, slots[]);
                sink += cast(size_t) result;
            }
            libffiDeferredWatch.stop;
        }
        baselines[sample] = baselineWatch.peek.total!"nsecs"
            / cast(double) n;
        barriers[sample] = barrierWatch.peek.total!"nsecs"
            / cast(double) n;
        libffiEagerTimes[sample] = libffiEagerWatch.peek.total!"nsecs"
            / cast(double) n;
        libffiDeferredTimes[sample] = libffiDeferredWatch.peek.total!"nsecs"
            / cast(double) n;
        ratios[sample] = barriers[sample] / baselines[sample];
        eagerRatios[sample] = libffiEagerTimes[sample] / baselines[sample];
        deferredRatios[sample] = libffiDeferredTimes[sample]
            / baselines[sample];
    }
    sort(baselines[]);
    sort(barriers[]);
    sort(libffiEagerTimes[]);
    sort(libffiDeferredTimes[]);
    sort(ratios[]);
    sort(eagerRatios[]);
    sort(deferredRatios[]);
    stderr.writefln(
        "  baseline %5.2f ns, arity %5.2f ns (%4.1fx), " ~
        "libffi eager %5.2f ns (%4.1fx), libffi deferred %5.2f ns (%4.1fx)",
        baselines[2], barriers[2], ratios[2], libffiEagerTimes[2],
        eagerRatios[2], libffiDeferredTimes[2], deferredRatios[2],
    );

    result.should == 42;
    assert(sink != 0, "the baseline loop was optimised away");

    // Crossing the barrier should cost about what the call costs, not a
    // multiple of it.
    assert(ratios[2] < 2.0,
        "the barrier costs more than twice a direct call");
}
