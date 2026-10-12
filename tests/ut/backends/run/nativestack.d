module ut.backends.run.nativestack;


import ut.backends;


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


// Compiled D reaches this depth in the 8 MiB stack of a default Linux
// thread. A guest that recurses this deep is a valid program.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops at a fixed recursion limit far below this depth"),
)) {
    @("nativeStack.deepRecursionReachesCompiledDepth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(220_000).shouldBeRetOf!(backend, q{
            size_t salt = 1;

            size_t walk(size_t n) {
                import core.volatile: volatileLoad;

                if (n == 0)
                    return 0;
                return walk(n - 1) + volatileLoad(&salt);
            }

            size_t answer() {
                return walk(220_000);
            }
        }, "answer");
    }
}


// A call from guest code to host code runs on the native stack that the
// guest code was entered on: a host function sees the thread, not an
// implementation detail of how deep the recursion is.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call native functions such as "
        ~ "`core.thread.fiber.Fiber.getThis`"),
)) {
    @("nativeStack.hostCallAtDepthOnAThreadSeesNoFiber." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.thread.fiber: Fiber;

            enum depth = 10_000;
            int fibersSeen;

            void walk(int level) {
                if (level == depth) {
                    fibersSeen += Fiber.getThis !is null;
                    return;
                }
                walk(level + 1);
            }

            void main() {
                walk(0);
                assert(fibersSeen == 0);
            }
        });
    }
}


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
