module ut.backends.run.nativestack;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// A guest `Fiber` of the default size (16 KiB) runs the guest code: a
// collection in the middle of a deep recursion, while the Fiber is
// suspended, and right after it resumes must keep the objects that the
// recursion holds.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call native functions such as "
        ~ "`core.thread.fiber.Fiber`'s constructor, `call` or `yield`"),
)) {
    @("nativeStack.deepFiberRecursionSurvivesGcAndYield." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            import core.thread.fiber: Fiber;

            enum depth = 40;
            int deepest;

            void walk(int level) {
                if (level > deepest)
                    deepest = level;
                if (level % 8 == 0)
                    GC.collect();
                if (level >= depth) {
                    Fiber.yield();
                    // Right after resume, before any unwinding starts.
                    GC.collect();
                    return;
                }
                walk(level + 1);
            }

            void entry() {
                walk(0);
            }

            void main() {
                auto fiber = new Fiber(&entry);
                fiber.call();
                assert(fiber.state != Fiber.State.TERM);
                // The fiber is suspended mid-recursion, `depth` frames
                // deep, while this collection runs from the main
                // context.
                GC.collect();
                while (fiber.state != Fiber.State.TERM)
                    fiber.call();
                assert(deepest == depth);
            }
        });
    }
}


// This depth is several times what the walker holds in the 8 MiB stack of a
// default Linux thread (about 3,000 guest calls): the walker needs more stack
// than the thread gives it. A guest that recurses this deep is a valid
// program, and compiled D does it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops at a fixed recursion limit far below this depth"),
)) {
    @("nativeStack.recursionDeeperThanTheThreadStackRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(10_000).shouldBeRetOf!(backend, q{
            size_t salt = 1;

            size_t walk(size_t n) {
                import core.volatile: volatileLoad;

                if (n == 0)
                    return 0;
                return walk(n - 1) + volatileLoad(&salt);
            }

            size_t answer() {
                return walk(10_000);
            }
        }, "answer");
    }
}


// A guest that recurses without end stops: the status is 1 and the message
// is on stderr, as for a Bytecode VM that runs out of frame stack. Compiled D
// ends with SIGSEGV, which would end `bin/ut`, so `Native` has no arm.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "compiled D ends with SIGSEGV, and that ends the test process"),
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops at a fixed recursion limit far below this depth"),
)) {
    @("nativeStack.runawayRecursionStopsTheRun." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            size_t walk(size_t n) {
                return 1 + walk(n + 1);
            }

            void main() {
                walk(0);
            }
        });
    }
}


// A call from guest code to host code at depth runs on the native stack that
// the guest code was entered on: a host function sees the `Fiber` of the
// guest, not an implementation detail of how deep the recursion is.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call native functions such as "
        ~ "`core.thread.fiber.Fiber`'s constructor, `call` or `getThis`"),
)) {
    @("nativeStack.hostCallAtDepthInAFiberSeesTheFiber." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.thread.fiber: Fiber;

            enum depth = 100;
            Fiber seen;

            void walk(int level) {
                if (level == depth) {
                    seen = Fiber.getThis;
                    return;
                }
                walk(level + 1);
            }

            void main() {
                auto fiber = new Fiber({ walk(0); });
                fiber.call;
                assert(seen is fiber);
            }
        });
    }
}


// A `Throwable` that a host function throws at depth reaches a guest
// `catch` far above it, and the guest `finally` in between runs.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops at a fixed recursion limit far below this depth"),
)) {
    @("nativeStack.hostThrowableAtDepthReachesGuestCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: UnicodeException, onUnicodeError;

            int finallyRuns;
            int catches;

            int guarded(int level) {
                try
                    return descend(level + 1) + 1;
                catch (UnicodeException) {
                    ++catches;
                    return -1;
                }
            }

            int cleaned(int level) {
                scope(exit) ++finallyRuns;
                return descend(level + 1) + 1;
            }

            int descend(int level) {
                if (level == 10_000) {
                    onUnicodeError("thrown by the host", 0);
                    return 0;
                }
                if (level == 6_000)
                    return cleaned(level);
                if (level == 2_000)
                    return guarded(level);
                return descend(level + 1) + 1;
            }

            void main() {
                assert(descend(0) == 1_999);
                assert(finallyRuns == 1);
                assert(catches == 1);
            }
        });
    }
}


// A host function that a guest function calls at depth can call back into
// guest code, which recurses deeply again.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot pass a function to a native function such as `qsort`"),
)) {
    @("nativeStack.guestCallbackUnderHostCallAtDepth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdlib: qsort;

            enum depth = 10_000;
            size_t walked;

            size_t walk(size_t n) {
                return n == 0 ? 0 : 1 + walk(n - 1);
            }

            extern(C) int compare(scope const void* a, scope const void* b) {
                walked += walk(depth);
                return *cast(const(int)*) a - *cast(const(int)*) b;
            }

            size_t descend(size_t n) {
                if (n == 0) {
                    int[2] values = [2, 1];
                    qsort(values.ptr, values.length, int.sizeof, &compare);
                    assert(values[0] == 1);
                    return 0;
                }
                return 1 + descend(n - 1);
            }

            void main() {
                assert(descend(depth) == depth);
                assert(walked == depth);
            }
        });
    }
}


// Execution that a guest runs on a `Fiber` after a deep recursion that
// made callbacks is not confused with the recursion that came before.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot pass a function to a native function such as `qsort`"),
)) {
    @("nativeStack.callbackInAFiberAfterDeepRecursion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdlib: qsort;
            import core.thread.fiber: Fiber;

            enum depth = 10_000;
            size_t walked;

            size_t walk(size_t n) {
                return n == 0 ? 0 : 1 + walk(n - 1);
            }

            extern(C) int deepCompare(scope const void* a, scope const void* b) {
                walked += walk(depth);
                return *cast(const(int)*) a - *cast(const(int)*) b;
            }

            extern(C) int compare(scope const void* a, scope const void* b) {
                return *cast(const(int)*) a - *cast(const(int)*) b;
            }

            size_t descend(size_t n) {
                if (n == 0) {
                    int[2] values = [2, 1];
                    qsort(values.ptr, values.length, int.sizeof, &deepCompare);
                    return 0;
                }
                return 1 + descend(n - 1);
            }

            void main() {
                assert(descend(depth) == depth);
                int[2] values = [2, 1];
                auto fiber = new Fiber({
                    qsort(values.ptr, values.length, int.sizeof, &compare);
                });
                fiber.call;
                assert(values[0] == 1);
                assert(walked == depth);
            }
        });
    }
}


// A guest destructor that the collector runs has stack to run on, when the
// collection starts at a depth that made the thread use its pieces.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call `GC.collect`"),
)) {
    @("nativeStack.destructorRunByCollectionAtDepth."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;

            class Dying {
                ~this() {
                    ++destroyed;
                }
            }

            int destroyed;

            void garbage() {
                foreach (_; 0 .. 1_000)
                    new Dying;
            }

            size_t walk(size_t n) {
                if (n == 0) {
                    garbage;
                    GC.collect;
                    return 0;
                }
                return 1 + walk(n - 1);
            }

            void main() {
                assert(walk(10_000) == 10_000);
                assert(destroyed > 0);
            }
        });
    }
}


// The same in a `Fiber` of the default size, which has no room for the
// walker and thus always runs on a piece.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call native functions such as "
        ~ "`core.thread.fiber.Fiber`'s constructor or `GC.collect`"),
)) {
    @("nativeStack.destructorRunByCollectionInAFiber." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            import core.thread.fiber: Fiber;

            class Dying {
                ~this() {
                    ++destroyed;
                }
            }

            int destroyed;

            void garbage() {
                foreach (_; 0 .. 1_000)
                    new Dying;
            }

            void main() {
                auto fiber = new Fiber({
                    garbage;
                    GC.collect;
                });
                fiber.call;
                assert(destroyed > 0);
            }
        });
    }
}


// A value that a host `Fiber` keeps only in its own frame survives a
// collection that a guest call starts.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the test calls one parsed guest function through `call`"),
    Omit!(Ctfe, Because.inexpressible,
        "the test calls one parsed guest function through `call`"),
)) {
    @("nativeStack.hostFiberOwnStackSurvivesCollectionDuringGuestCall."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.thread.fiber: Fiber;

        auto guestModule = parseSnippet(q{
            void forceCollection() {
                import core.memory: GC;

                GC.collect;
            }
        });
        auto function_ = findFunction(guestModule, "forceCollection");
        auto evaluator = Owned!backend(Program([guestModule]));

        static class Box {
            int value;
        }

        int survivorValue = -1;
        auto fiber = new Fiber({
            auto box = new Box;
            box.value = 42;

            evaluator.call(function_, null, []);

            // A block that the collection freed is the first one that a
            // same-size allocation gets back.
            foreach (_; 0 .. 64)
                cast(void) new Box;

            survivorValue = box.value;
        });
        fiber.call;

        survivorValue.should == 42;
    }
}
