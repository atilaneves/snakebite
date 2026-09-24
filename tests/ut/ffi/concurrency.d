module ut.ffi.concurrency;


import ut;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


// Regression test for the frontend-lock narrowing `PlanCache.of`/
// `signatureOf`/`variadicOf`/`rawPlanOf` no longer take: they used to
// wrap their whole miss path (`_shapeOf`, which classifies a callee's
// parameter and return types for the System V AMD64 ABI, reading a
// struct's own `.size`/`.alignsize` directly, not through `snakebite.
// nativelayout.TypeFacts`) in the frontend compiler lock. `_shapeOf` now
// forces every dmd forward reference a struct or enum type could still
// have up front, through `TypeFacts.of` (self-guarded, `snakebite.
// frontend.compiler.forceIfNeeded`), before doing anything unlocked -
// see `_shapeOf`'s own doc (`snakebite.ffi.plan`).
//
// A guest struct passed by value across the FFI boundary is exactly the
// forward reference this forces: dmd never determines its size until
// something asks (`AggregateDeclaration.determineSize`), and a guest
// program's own struct declaration, parsed but never used natively, is
// exactly that "never asked yet" state. Many threads racing the very
// first `PlanCache.of` for a fresh struct type must never corrupt dmd's
// shared AST (`dsymbolsem.finalizeSize`'s field-offset loop resets and
// refills `StructDeclaration.fields`, an unprotected dynamic array, as
// it runs - two threads racing it is a real, unguarded write/write race,
// not only a stale-read one) or disagree about the struct's own size,
// whether or not any of them ends up taking the frontend lock to get
// there. `snakebite_ut_concurrency_wide` (below), not one of `tests/ut/
// ffi/plan.d`'s own fixtures, uses `fieldCount` `int` fields, not two,
// so that loop runs long enough for two threads to plausibly overlap -
// both sides of the barrier declare the same `fieldCount` fields, so the
// classification this forces is still real System V AMD64 ABI
// classification (a struct this size passes through the hidden-pointer
// "memory" class, not registers), never breaking the native-layout
// agreement this test exists to check.
//
// Caveat, checked directly rather than assumed: even at `fieldCount`
// fields, `threadCount` threads and `rounds` rounds, this did not
// reproduce a failure in this sandbox with the fix's own forcing
// temporarily deleted (unlike `ut.backends.interpreter.concurrency`/
// `ut.backends.bytecode.concurrency`'s sibling races, both reliable red
// before their fix - a whole function body's `semantic3` walk is a far
// larger critical section than one struct's field-offset loop, and
// likely the available parallelism here does not interleave a section
// this short often enough to hit it). The fix stays, justified by
// reading dmd's own source (this test's own doc, and `_shapeOf`'s), not
// by this test alone; this test is kept as an end-to-end correctness
// check under concurrent load for a cold FFI struct, not as proof of
// the race.
private enum threadCount = 32;
private enum rounds = 4;
private enum fieldCount = 300;

private string guestFields() {
    string source;
    foreach (i; 0 .. fieldCount)
        source ~= text("int pad", i, "; ");
    return source;
}

private string guestSource(in size_t round) {
    return text(
        "module ut.ffi.concurrency_guest", round, ";\n",
        "struct Wide", round, " { ", guestFields(), "int first; ",
        "int second; }\n",
        "extern(C) Wide", round, " snakebite_ut_concurrency_wide(",
        "Wide", round, " value);\n",
    );
}

// The host-side layout `snakebite_ut_concurrency_wide` (below) reads and
// writes through raw pointers - matches each round's guest `Wide<round>`
// byte for byte (`fieldCount` `int` padding fields, then two more), which
// is all FFI's native layout ever checks (this project's own rule: no
// marshalling, guest and host share one layout).
private struct Wide {
    int[fieldCount] pad;
    int first;
    int second;
}

private extern(C) Wide snakebite_ut_concurrency_wide(Wide value) {
    value.first += 1;
    value.second += 2;
    return value;
}

@("plan.concurrentFirstPlansOfAFreshStructTypeAgree")
unittest {
    import core.atomic: atomicLoad, atomicOp, atomicStore;
    import core.thread: Thread;

    foreach (round; 0 .. rounds) {
        auto guestModule = parseSnippet(guestSource(round));
        auto function_ =
            findFunction(guestModule, "snakebite_ut_concurrency_wide");
        assert(function_ !is null,
            "No `snakebite_ut_concurrency_wide` in the guest program");

        PlanCache cache;

        shared size_t ready = 0;
        shared bool go = false;
        Throwable[threadCount] failures;

        auto threads = new Thread[threadCount];
        foreach (t; 0 .. threadCount) {
            const threadIndex = t;
            threads[t] = new Thread({
                atomicOp!"+="(ready, 1);
                while (!atomicLoad(go)) {}

                try {
                    Wide value;
                    value.first = 39 + cast(int) threadIndex;
                    value.second = 58;
                    Wide result;
                    cache.of(function_)
                        .call(&result, [cast(const void*) &value]);

                    Wide expected = value;
                    expected.first += 1;
                    expected.second += 2;
                    if (result != expected)
                        throw new Exception(text(
                            "snakebite_ut_concurrency_wide(...) returned "
                            ~ "first=", result.first, " second=",
                            result.second, ", expected first=",
                            expected.first, " second=", expected.second,
                        ));
                } catch (Throwable throwable)
                    failures[threadIndex] = throwable;
            });
            threads[t].start;
        }

        while (atomicLoad(ready) < threadCount) {}
        atomicStore(go, true);

        foreach (t; 0 .. threadCount)
            threads[t].join;

        foreach (t; 0 .. threadCount)
            if (failures[t] !is null)
                throw new UnitTestException(
                    text(
                        "round ", round, ", thread ", t, ": ",
                        failures[t].msg,
                    ),
                    __FILE__, __LINE__,
                );
    }
}
