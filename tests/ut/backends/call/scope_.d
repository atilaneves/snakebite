module ut.backends.call.scope_;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("scope.nestedLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `{ long sum = 3; return sum; }` inside a function body is a
        // `ScopeStatement` wrapping a `CompoundStatement` - dmd gives every
        // `{ ... }` block its own scope this way, even one with no `if`,
        // `while`, or other construct introducing it, so a bare nested
        // block still gets its own AST node. `sum` is declared inside that
        // nested block rather than the function's top-level statement
        // list, and D scopes it to that block while still giving it
        // storage for the block's lifetime.
        3L.shouldBeRetOf!(
            backend,
            q{
                long three() {
                    {
                        long sum = 3;
                        return sum;
                    }
                }
            },
            "three",
        );
    }
}
