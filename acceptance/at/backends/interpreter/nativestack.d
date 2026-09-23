module at.backends.interpreter.nativestack;


import unit_threaded;
import snakebite.backends.backend: Program;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// Regression gate for the interpreter's dedicated native stack
// (`source/snakebite/backends/interpreter/nativestack.d`): entering guest
// code from inside a guest `core.thread.Fiber` switches onto a fresh
// `InterpreterStack` for that (thread, fiber) context (ADR-0006's
// `PerThread!(Evaluator, true)`, walker.d), and that context is never
// released while the thread lives (`snakebite.hostthreads.PerThread`). A
// fiber that enters guest code once and then terminates therefore leaves
// its `InterpreterStack` registered for the rest of the process, so
// whatever that registration costs on every later collection is paid
// forever, once per fiber that ever touched guest code.
//
// A `GC.addRange` over the whole dedicated stack used to be exactly such a
// cost: `Evaluator.runOnInterpreterStack` (walker.d) already re-points the
// switched-to guest `Fiber`'s own `StackContext.bstack` at this stack
// while a call runs on it, so druntime's ordinary stack scan already
// covers every live byte on it - a separate `addRange`'d region never
// finds a pointer that scan does not, and pays full collection-time
// scanning for it regardless.
//
// This creates `fiberCount` short-lived fibers, each entering guest code
// exactly once, then compares `GC.collect()`'s own cost before and after -
// the ratio, not an absolute time, so machine speed cancels. A
// permanently-live, `addRange`'d 8 MiB region per fiber
// (`defaultInterpreterStackBytes`, nativestack.d) moves that ratio by a
// wide margin; no such registration barely moves it at all, since
// `InterpreterStack`'s live bytes are already covered by the context scan.
@("nativeStack.perFiberEntryDoesNotGrowCollectionCost")
@Flaky(3)
@Serial
@Tags("timing")
unittest {
    import core.thread.fiber: Fiber;
    import core.memory: GC;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.stdio: writefln;

    auto guestModule = parseSnippet(q{
        int identity() { return 42; }
    });
    auto function_ = findFunction(guestModule, "identity");
    assert(function_ !is null, "No function `identity` in the guest program");
    auto backend = new Interpreter(Program([guestModule]));

    // One warm-up call outside any fiber: the cold path (frame layout,
    // type facts) is not what this measures.
    int result;
    backend.call(function_, &result, []);

    // The smallest of a few rounds, not their total: one collection
    // paused by an unrelated scheduler hiccup would otherwise inflate
    // both readings unevenly and move the ratio for a reason that has
    // nothing to do with this stack.
    enum collectRounds = 7;
    double collectFloorMs() {
        auto watch = StopWatch(AutoStart.no);
        double floor = double.infinity;
        foreach (_; 0 .. collectRounds) {
            watch.reset;
            watch.start;
            GC.collect();
            watch.stop;
            const ms = watch.peek.total!"nsecs" / 1_000_000.0;
            if (ms < floor)
                floor = ms;
        }
        return floor;
    }

    const before = collectFloorMs();

    // Each fiber enters guest code exactly once and then terminates.
    // Nothing resumes it again, but its `Evaluator` - and, before this
    // gate's own fix, its `InterpreterStack` - lives on in
    // `PerThread!(Evaluator, true)`'s per-thread table for as long as
    // this thread does (`snakebite.hostthreads`).
    enum fiberCount = 100;
    foreach (_; 0 .. fiberCount) {
        auto fiber = new Fiber({
            int fiberResult;
            backend.call(function_, &fiberResult, []);
        });
        fiber.call();
    }

    const after = collectFloorMs();
    const ratio = after / before;

    writefln("  before %.3f ms, after %.3f ms, ratio %.3fx",
        before, after, ratio);

    // Measured on 2026-09-23, `timeout 120 bin/at -d
    // at.backends.interpreter.nativestack.nativeStack.perFiberEntryDoesNotGrowCollectionCost`,
    // 5 single-attempt runs each way (`before`/`after` here already pay
    // for the frame stacks the 100 fibers legitimately, and expectedly,
    // commit - see `source/snakebite/framestack.d` - so neither floor is
    // anywhere near 1x; what moves between them is only this stack's own
    // registration):
    //
    //   with the redundant `GC.addRange` (an extra ~800 MiB live across
    //   100 fibers' worth of 8 MiB dedicated stacks): floor ratio
    //   20.8-23.0x.
    //   without it (this stack's own live bytes already covered by the
    //   re-pointed `StackContext.bstack` scan): floor ratio 6.6-8.5x.
    //
    // The two stay apart by roughly 2.5-3x in both directions, so 14.0 -
    // squarely in the gap between the two clusters - stays a useful
    // bound with wide margin either side.
    enum maxRatio = 14.0;
    ratio.shouldBeSmallerThan(maxRatio);
}
