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
        // node bundles together. A backend that only walked
        // `CompoundStatement`/`ScopeStatement` children (the only
        // statement kinds this interpreter descended into before this
        // test) would refuse this node outright and never run the loop's
        // init statement or body, so this would fail before even
        // reaching the `return` inside it.
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
