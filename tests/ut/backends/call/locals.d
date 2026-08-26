module ut.backends.call.locals;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("locals.literalInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A local variable's initialiser must run before the variable is
        // read. `sum` only holds `0` because its declaration statement
        // ran; nothing initialises the storage otherwise.
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
        // A local can be initialised from a function call as well as a
        // literal. The call must run before `a` is readable, and `a` is
        // returned unchanged so the test pins the declaration and its
        // initialiser rather than anything else.
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
