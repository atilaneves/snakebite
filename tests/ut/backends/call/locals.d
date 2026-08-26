module ut.backends.call.locals;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("locals.literalInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `long sum = 0;` is a `VarDeclaration` with an `ExpInitializer`
        // wrapping the literal `0`. dmd represents the declaration itself
        // as a `DeclarationExp` inside an `ExpStatement` - the same shape
        // any local declaration takes as a statement - so a backend that
        // skipped running that statement would leave `sum`'s storage
        // uninitialized and return garbage instead of `0`.
        0L.shouldBeRetOf!(
            backend,
            q{
                long zero() {
                    long sum = 0;
                    return sum;
                }
            },
            "zero",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("locals.callInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `auto x = f();` still parses as a `DeclarationExp` wrapping a
        // `VarDeclaration`, but its `ExpInitializer` wraps a `CallExp`
        // instead of a literal, so a backend that special-cased only
        // literal initializers would fail this while still passing the
        // one above. Returning the local rather than combining it with
        // another expression keeps this test isolated to declarations:
        // the interpreter does not yet evaluate arithmetic expressions,
        // and that is a different feature from running a local's
        // initializer.
        6.shouldBeRetOf!(
            backend,
            q{
                int six() {
                    return 6;
                }

                int copy() {
                    auto a = six();
                    return a;
                }
            },
            "copy",
        );
    }
}
