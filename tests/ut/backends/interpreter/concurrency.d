module ut.backends.interpreter.concurrency;


import ut;
import snakebite.backends.backend: Program;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


// Regression test for the frontend-lock narrowing this sits beside
// (`snakebite.backends.interpreter.walker`'s `Cache!(...).build` no
// longer wraps every cache miss in the compiler lock;
// `snakebite.frontend.compiler.forceIfNeeded` takes it only while a dmd
// forward reference is still unresolved). Every cache this exercises
// resolves dmd's own process-global frontend state on a genuine miss:
// `Cache!(FuncDeclaration, FrameLayout)`, `Cache!(FuncDeclaration,
// CallShape)`, `Cache!(FuncDeclaration, bool)` (needsClosure),
// `Cache!(FuncDeclaration, ClosureLayout)`, `Cache!(StaticChainKey,
// Hop[])`, and `Cache!(Type, TypeFacts)`. Two threads racing the very
// first call of a guest function that hits one of these - here, a fresh
// druntime array-append template instantiation for an element type no
// earlier round used, or a nested function reading its enclosing frame
// for the first time - must never corrupt dmd's shared AST or disagree
// about the answer, whether or not either thread ends up taking the
// frontend lock to get there.
//
// Half of each round's functions append to a dynamic array of a struct
// type declared fresh that round (`S<round>`, exactly
// `ut.backends.bytecode.concurrency`'s own trick) - guest code declared
// directly in a root module is already fully analysed by the time
// `parseSnippet` (called single-threaded, before any of this test's
// threads starts) returns, so only a type dmd has never seen before,
// like this one, still has real forcing left to race over: the append
// template's own first instantiation for `S<round>`, and `S<round>`'s
// own size, are both still-unresolved forward references at that point,
// worked out lazily on this test's first call into them - one struct
// name per round keeps every round, not just the first, a genuine cold
// race. The other half declare a nested function whose address is taken
// (dmd's own escape-analysis trigger for `needsClosure`) and that reads
// a captured outer local - not a race over dmd forcing (both functions
// are root-owned, so already resolved before the threads start, same as
// the append functions' own outer bodies), but still a genuine race over
// `_needsClosure`/`_closures`/`_staticChains`'s own `SharedTable`
// inserts, each keyed fresh every round. Every function returns a value
// unique to its own index, so a race that reads another thread's
// operand, type or AST node shows up as a wrong answer, not only a
// crash.
private enum functionCount = 16;
private enum threadCount = 8;
private enum rounds = 6;

private string guestSource(in size_t round) {
    string source = text(
        "module ut.backends.interpreter.concurrency_guest", round, ";\n",
        "struct S", round, " { long value; }\n",
    );
    foreach (i; 0 .. functionCount) {
        if (i % 2 == 0)
            source ~= text(
                "long f", i, "() { S", round, "[] a; ",
                "foreach (j; 0 .. 3) a ~= S", round, "(", i, " + j); ",
                "long sum = 0; foreach (v; a) sum += v.value; ",
                "return sum; }\n",
            );
        else
            source ~= text(
                "long f", i, "() { ",
                "long captured = ", i, "; ",
                "long inner() { return captured + 1; } ",
                "auto dg = &inner; ",
                "return dg(); }\n",
            );
    }
    return source;
}

// `sum(i + j)` for `j` in `[0, 3)`, for an appending function; `i + 1`
// for a nested-closure one.
private long expectedResult(in size_t index) {
    return index % 2 == 0 ? 3 * index + 0 + 1 + 2 : index + 1;
}

@("call.concurrentFirstCallsOfDifferentFunctionsAgree")
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
                    auto backend = new Interpreter(program);
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
