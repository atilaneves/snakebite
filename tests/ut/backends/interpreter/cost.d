module ut.backends.interpreter.cost;


import ut;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import dmd.dmodule: Module;
import dmd.func: FuncDeclaration;
import std.conv: text;


// How many trips round the loop each of the two guest functions
// `loopFunction` writes makes. The lookup budget below is measured over
// the difference.
private enum fewTrips = 10;
private enum manyTrips = 110;

// Every guest program these tests run. None of them allocates: no `new`,
// no array literal, no concatenation, nothing that reaches druntime's
// allocator, so any byte the GC counts during a run came from the
// interpreter and not from the program it was asked to run.
private enum guest = q{
    long identity(long value) {
        return value;
    }

    long arithmetic() {
        long sum = 0;
        for (long i = 0; i < 100; ++i)
            sum += i;
        return sum;
    }

    long calls() {
        long sum = 0;
        for (long i = 0; i < 100; ++i)
            sum += identity(i);
        return sum;
    }

    int ffi() {
        import core.stdc.stdlib: abs;
        int sum = 0;
        for (int i = 0; i < 100; ++i)
            sum += abs(i);
        return sum;
    }
} ~ loopFunction("few", fewTrips) ~ loopFunction("many", manyTrips);

// The two functions the lookup budget is measured across, written by one
// function so that they can differ in nothing but their trip count.
private string loopFunction(in string name, in int trips) {
    return text("
        long ", name, "() {
            long sum = 0;
            for (long i = 0; i < ", trips, "; ++i)
                sum += i;
            return sum;
        }
    ");
}


// A bare loop over locals: no call of any kind, so this is the evaluator's
// own statement and expression walking with nothing else in the way.
@("steadyState.arithmetic.allocatesNothing")
@Tags("interpreter")
unittest {
    shouldNotAllocate("arithmetic");
}


// A guest function calling a guest function in a loop, which is what
// pushes and pops a frame and fills a parameter slot on every trip.
@("steadyState.guestCall.allocatesNothing")
@Tags("interpreter")
unittest {
    shouldNotAllocate("calls");
}


// Crossing the FFI barrier in a loop: the argument slots a call hands over
// and the register words it widens them into are fixed-size buffers, so no
// call builds an array for either.
@("steadyState.ffiCall.allocatesNothing")
@Tags("interpreter")
unittest {
    shouldNotAllocate("ffi");
}


// The interpreter reaches its steady state after the first call to a
// function - its frame layout is computed once and kept, and so is every
// answer about a type - and from there a call runs out of storage it
// already has: frame slots come off a buffer allocated once, and every
// scratch destination is a fixed-size buffer on the host stack. A
// steady-state call therefore costs the collector nothing at all, which is
// an exact zero rather than a threshold.
//
// `allocatedInCurrentThread` and not `GC.stats.usedSize`: the latter is
// process-wide, and `bin/ut` runs its tests in parallel by default, so
// another test allocating between the two readings would fail this one at
// random. That was seen in practice - passing under `-s`, failing without
// it - so the per-thread counter is load-bearing, not a stylistic choice.
private void shouldNotAllocate(
    in string functionName,
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    import core.memory: GC;

    auto backend = new Interpreter;
    auto function_ = guestFunction(parseSnippet(guest), functionName);
    long result;

    // More than one warm-up call: the first reaches every cold path, and
    // the ones after it cover the one-off costs that are invisible in the
    // source - an associative array growing past a bucket threshold, or
    // the GC creating the pool for a size class the first time anything
    // asks for one.
    foreach (_; 0 .. 4)
        backend.call(function_, &result, []);

    enum calls = 100;
    const before = GC.allocatedInCurrentThread;
    foreach (_; 0 .. calls)
        backend.call(function_, &result, []);
    const allocated = GC.allocatedInCurrentThread - before;

    if (allocated != 0)
        throw new UnitTestException(
            text("`", functionName, "` allocated ", allocated,
                " byte(s) across ", calls, " steady-state calls; a ",
                "steady-state call must allocate nothing"),
            file, line,
        );
}


// A variable is reached by name, so finding where it lives is a lookup
// the evaluator cannot avoid paying - but one, not two. `sum += i` in
// `for (long i = 0; i < n; ++i)` reaches four variables: `i` in the
// condition, `sum` and `i` in the body, and `i` again in the increment,
// since a compound assignment reaches its target once rather than once to
// read it and again to write it.
private enum nameLookupsPerIteration = 4;

// A type's size, alignment and signedness are fixed for the life of the
// program, so the evaluator asks about each type once and keeps the
// answer rather than asking once per node it visits. What is left is the
// two changes of type each iteration makes: the condition `i < n` is
// `bool` where everything around it is `long`, and the kept answer is the
// last type asked about, so the type changing back and forth costs one
// lookup each way. Every other question an iteration asks about a type is
// answered without one.
private enum typeLookupsPerIteration = 2;


// An iteration of the loop may cost one lookup per variable it reaches,
// and two more for a `bool` condition among `long`s - not a lookup per
// node visited.
//
// Measured as the difference between two functions that differ only in how
// many times they go round the loop, so what a call pays regardless of the
// loop - finding the frame layout, running the two declarations, reading
// the result back - cancels instead of having to be counted.
@("steadyState.lookupsPerIteration")
@Tags("interpreter")
unittest {
    shouldCostPerIteration!"name"(nameLookupsPerIteration);
    shouldCostPerIteration!"type"(typeLookupsPerIteration);
}


// How many calls to each of the two functions the difference is taken
// over. One would do - the steady state is deterministic - but a count
// that only appeared on some calls would then be a coin toss rather than
// a failure.
private enum perIterationCalls = 10;

// Runs the two functions that differ only in trip count and checks what
// the extra iterations cost in lookups of one kind against `budget` per
// iteration.
private void shouldCostPerIteration(string kind)(
    in size_t budget,
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    auto guestModule = parseSnippet(guest);
    auto backend = new Interpreter;
    long result;

    auto few = guestFunction(guestModule, "few");
    auto many = guestFunction(guestModule, "many");

    // The first call to each is the cold one: it computes a frame layout
    // and asks about every type in the function for the first time.
    backend.call(few, &result, []);
    backend.call(many, &result, []);

    size_t spent(FuncDeclaration function_) {
        const before = mixin("backend." ~ kind ~ "Lookups");
        foreach (_; 0 .. perIterationCalls)
            backend.call(function_, &result, []);

        return mixin("backend." ~ kind ~ "Lookups") - before;
    }

    const iterations = perIterationCalls * (manyTrips - fewTrips);
    const spentTotal = spent(many) - spent(few);

    if (spentTotal != iterations * budget)
        throw new UnitTestException(
            text(iterations, " extra loop iterations cost ", spentTotal,
                " ", kind, " lookup(s); the budget is ", budget,
                " per iteration, ", iterations * budget, " in total"),
            file, line,
        );
}


private FuncDeclaration guestFunction(Module guestModule, in string name) {
    auto function_ = findFunction(guestModule, name);
    assert(function_ !is null,
        text("No function `", name, "` in the guest program"));

    return function_;
}
