module ut.ffi.cost;


import ut;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


extern(C) int abs(int);

private alias Native = extern(C) size_t function(size_t);


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
// Pinned as a failure because the bookkeeping is real and known: a plan is
// found by hashing the callee's declaration on every call, where a plan
// found once per call site would need no lookup at all. When that lands
// this test starts passing, `@ShouldFail` turns that into a red result,
// and this pin should be deleted rather than loosened.
//
// `bin/ut` is built unoptimised, so neither number is a release figure.
// The ratio is what this asserts on, and it is meaningful either way.
@("barrier.overhead")
@Tags("timing")
@ShouldFail("a plan is looked up per call, not prepared per call site")
unittest {
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.stdio: writefln;

    auto guestModule = parseSnippet(q{
        extern(C) int abs(int);
    });
    auto function_ = findFunction(guestModule, "abs");
    assert(function_ !is null, "No function `abs` in the guest program");

    PlanCache cache;
    enum n = 1_000_000;

    // Both loops do the same work either side of the barrier: read one
    // `int` argument from a slot, call `abs`, keep the result. Only the
    // barrier's own bookkeeping differs.
    int argument = -42;
    int result;
    auto direct = cast(Native) &abs;

    // The slot array is built once, outside both loops: a `[&argument]`
    // literal per iteration would allocate, and that allocation would be
    // measured as if the barrier had cost it.
    const(void)*[1] slots = [&argument];

    foreach (i; 0 .. 10_000) {
        cast(void) direct(cast(size_t) cast(long) argument);
        cache.of(function_).call(&result, slots[]);
    }

    size_t sink;
    auto watch = StopWatch(AutoStart.yes);
    foreach (i; 0 .. n)
        sink += direct(cast(size_t) cast(long) argument);
    const baseline = watch.peek.total!"nsecs" / cast(double) n;

    watch.reset;
    foreach (i; 0 .. n)
        cache.of(function_).call(&result, slots[]);
    const barrier = watch.peek.total!"nsecs" / cast(double) n;

    const ratio = barrier / baseline;
    writefln("  baseline %5.2f ns, barrier %5.2f ns, ratio %4.1fx",
        baseline, barrier, ratio);

    result.should == 42;
    assert(sink != 0, "the baseline loop was optimised away");

    // Crossing the barrier should cost about what the call costs, not a
    // multiple of it.
    assert(ratio < 2.0, "the barrier costs more than twice a direct call");
}
