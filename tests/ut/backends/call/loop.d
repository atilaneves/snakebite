module ut.backends.call.loop;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("loop.forRunsBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `for (long i = 0; 1; ) return 7;` is a `ForStatement` - dmd
        // gives it its own node distinct from `WhileStatement`/
        // `DoStatement` because it carries an optional init statement
        // (here, `long i = 0;`) and an optional increment expression
        // alongside the condition, none of which any other statement
        // node bundles together.
        //
        // The condition here is the literal `1`: dmd's flow analysis
        // recognises `for (...; 1; ...)` as unconditionally entering the
        // loop, the same as `while (true)`, so `seven` type-checks with
        // no `return` needed after the loop even though every real path
        // out of it is the `return 7;` inside the body.
        7L.shouldBeRetOf!(
            backend,
            q{
                long seven() {
                    for (long i = 0; 1; )
                        return 7;
                }
            },
            "seven",
        );
    }
}

// A loop that runs its body more than once, and stops. The count comes back
// as the answer, so a condition tested only once (never terminating, or
// running the body a single time) and an increment that never ran both
// disagree with it: without the increment `i` stays `0` and the loop cannot
// end, and without re-testing the condition it cannot end either.
//
// `one` is behind a call because dmd folds an all-literal expression during
// semantic analysis, and comes first because the native oracle mixes these
// declarations into a local delegate scope, where a nested function does not
// see a sibling declared later.
static foreach (backend; Matrix!()) {
    @("loop.forRepeatsAndTerminates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int count() {
                    int n = 0;
                    for (int i = 0; i < 3; ++i)
                        n += one();
                    return n;
                }
            },
            "count",
        );
    }
}
