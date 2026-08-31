module at.ffi.cost;


import unit_threaded;
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
    auto direct = cast(Native) &abs;

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
    writefln("  baseline %5.2f ns, barrier %5.2f ns, ratio %4.1fx",
        baselines[2], barriers[2], ratios[2]);

    result.should == 42;
    assert(sink != 0, "the baseline loop was optimised away");

    // Crossing the barrier should cost about what the call costs, not a
    // multiple of it.
    assert(ratios[2] < 2.0,
        "the barrier costs more than twice a direct call");
}
