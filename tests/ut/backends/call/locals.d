module ut.backends.call.locals;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("locals.literalInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `long sum = 0;` is a `VarDeclaration` with an `ExpInitializer`
        // wrapping the literal `0`. dmd represents the declaration itself
        // as a `DeclarationExp` inside an `ExpStatement` - the same shape
        // any local declaration takes as a statement. The initialiser is
        // part of that statement, so `sum` reads as `0` only if the
        // statement ran; D leaves the storage indeterminate otherwise.
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
        // instead of a literal: D allows any expression to initialise a
        // local, and the call must run before the local is readable. The
        // local is returned unchanged rather than combined with anything,
        // so what this pins is the declaration and its initialiser, not
        // whatever else the expression could have been.
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
