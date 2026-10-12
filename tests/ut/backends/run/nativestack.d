module ut.backends.run.nativestack;


import ut.backends;


// A guest `Fiber` runs the walker on the stack that the Fiber has, and
// druntime scans it: a collection in the middle of a deep recursion, while
// the Fiber is suspended, and right after it resumes must keep the objects
// that the recursion holds. The Fiber has an explicit stack size: the
// default one (16 KiB) is sized for compiled D, which needs far less
// stack for each call than the Interpreter does.
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
            enum stackBytes = 1024 * 1024;
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
                auto fiber = new Fiber(&entry, stackBytes);
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
    Omit!(Interpreter, Because.unconfirmed,
        "the walker runs on the stack it was entered on and uses far more of "
        ~ "it for each guest call than compiled D: 220000 calls overflow "
        ~ "8 MiB and the process dies with SIGSEGV"),
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
