module ut.backends.run.nativestack;


import ut.backends;


// Regression test for a native-stack overflow in the interpreter,
// originally found through `bin/sb -b interpreter dlib` segfaulting.
// dlib's filesystem walk creates a `core.thread.Fiber` with the default
// stack size to implement a recursive directory walk, calling
// `Fiber.yield()` deep inside its own recursion. The interpreter's own
// recursive tree walk costs far more native stack per nested guest call
// than compiled D does (`executeCall` -> `executeRaw` -> `visit` -> ...
// -> `executeCall` again for every guest call), so it used to overflow
// a `Fiber`'s small default stack after only a handful of levels -
// `walk` below recurses `depth` levels deep, comfortably past that,
// inside a `Fiber` given no explicit size (the same default dlib's own
// `Fiber` gets).
//
// A forced collection partway down also used to segfault on its own,
// even after switching to a bigger native stack for the walk:
// druntime's conservative GC scans "the current native stack" using the
// active `Fiber`'s own recorded bounds
// (`core.thread.context.StackContext.bstack`), which a plain `%rsp`
// switch leaves pointing at the small stack while a live `%rsp` reads
// from the bigger one - see
// `source/snakebite/backends/interpreter/nativestack.d`. `walk` forces
// a collection every few levels to exercise exactly that, and forces two
// more at the two points where the re-pointed `StackContext` is what the
// GC actually scans from the *main* context rather than from inside the
// walk itself: once while the fiber sits suspended mid-recursion
// (between the first and second `fiber.call()` in `main`, below), and
// once right after `Fiber.yield()` returns, before the walk starts
// unwinding back through every recursive frame.
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
                    // Right after resume: still on the dedicated stack,
                    // with the guest fiber's `StackContext` still
                    // re-pointed at it, before any unwinding starts.
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
                // deep on the dedicated stack, while this collection
                // runs from the main context.
                GC.collect();
                while (fiber.state != Fiber.State.TERM)
                    fiber.call();
                assert(deepest == depth);
            }
        });
    }
}
