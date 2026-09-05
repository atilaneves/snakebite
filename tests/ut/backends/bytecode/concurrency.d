module ut.backends.bytecode.concurrency;


import ut;
import snakebite.backends.backend: Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


// Regression test for issue #278. `Bytecode.call` used to compile a guest
// function - walking dmd's AST and calling dmd frontend semantic helpers -
// without holding the compiler lock the CTFE and interpreter backends
// already take for their own dmd-touching entry points (see
// `snakebite.frontend.compiler.withCompilerLock`). Two threads compiling
// different guest functions at once could then race on dmd's own
// process-global state and corrupt it for both - exactly what `bin/ut`'s
// parallel runner does, one guest function's first (cold) call per test
// thread. Before the fix, this test's rounds/thread count against the
// unlocked `Bytecode.call` reliably reproduced wrong results within the
// first round or two; against the locked version it passes every time.
//
// Every function's element type rotates through a handful of scalar
// widths and, every other round, a struct - each combination forces dmd to
// instantiate druntime's array-append template for that element type for
// the first time, the same construct
// `arrays.append.elementThroughIndexedSlice.Bytecode` (one of the tests
// seen failing under the parallel runner in issue #278) exercises. That
// first instantiation is a semantic operation, not a cache read, so
// `functionCount` concurrent first reaches of it is the race this guards
// against. Each round parses a freshly worded module (the element types
// rotate by round too) so `parseSnippet`'s source cache never turns a
// later round's compile into a cache hit that skips the race window.
//
// Every function returns a value unique to its index, so corruption is
// caught as a wrong answer even where it does not crash outright: one
// thread's compile reading back another's operand, type or AST node
// produces a value (or an unrelated compile failure) that belongs to no
// function here.
private enum functionCount = 64;
private enum threadCount = 32;
private enum rounds = 30;
private static immutable elementTypes = [
    "ubyte", "short", "int", "long", "float", "double",
];

private string guestSource(in size_t round) {
    string source = text(
        "module ut.backends.bytecode.concurrency_guest", round, ";\n",
        "struct S", round, " { long value; }\n",
    );
    foreach (i; 0 .. functionCount) {
        const useStruct = i % (elementTypes.length + 1) == elementTypes.length;
        if (useStruct)
            source ~= text(
                "long f", i, "() { S", round, "[] a; ",
                "foreach (j; 0 .. 3) a ~= S", round, "(", i, " + j); ",
                "long sum = 0; foreach (v; a) sum += v.value; ",
                "return sum; }\n",
            );
        else
            source ~= text(
                "long f", i, "() { ",
                elementTypes[i % elementTypes.length], "[] a; ",
                "foreach (j; 0 .. 3) a ~= cast(",
                elementTypes[i % elementTypes.length], ") (", i, " + j); ",
                "long sum = 0; foreach (v; a) sum += cast(long) v; ",
                "return sum; }\n",
            );
    }
    return source;
}

// `sum(i + j)` for `j` in `[0, 3)`.
private long expectedResult(in size_t index) {
    return 3 * index + 0 + 1 + 2;
}

@("compileFunction.concurrentCompilesOfDifferentFunctionsAgree")
unittest {
    import core.atomic: atomicLoad, atomicOp, atomicStore;
    import core.thread: Thread;

    foreach (round; 0 .. rounds) {
        auto guestModule = parseSnippet(guestSource(round));
        auto program = Program([guestModule]);

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
                    auto backend = new Bytecode(program);
                    foreach (which; 0 .. 2) {
                        const index =
                            (threadIndex * 2 + which) % functionCount;
                        auto function_ =
                            findFunction(guestModule, text("f", index));
                        long result;
                        backend.call(function_, &result, []);

                        const expected = expectedResult(index);
                        if (result != expected)
                            throw new Exception(text(
                                "f", index, "() returned ", result,
                                ", expected ", expected,
                            ));
                    }
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
