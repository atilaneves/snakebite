module ut.backends.call.locals;


import ut.backends;


static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("locals.noInitialiser." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        20.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int total() {
                    int ret;  // blit init
                    ret += ten();
                    ret += ten();
                    return ret;
                }
            },
            "total",
        );
    }
}

static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible, "CTFE can't mutate a static local"),
)) {
    @("locals.staticPersistsAcrossCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A `static` local's storage lives once per function, not once per
        // call: `n` keeps whatever `inc` left it at, so five calls add
        // 1 + 2 + 3 + 4 + 5. A backend that re-runs the initialiser on
        // every call instead sees `n` reset to 0 each time, and returns 5.
        15.shouldBeRetOf!(
            backend,
            q{
                int inc() {
                    static int n = 0;
                    n += 1;
                    return n;
                }

                int kindaMain() {
                    int ret = 0;
                    foreach(i; 0 .. 5) {
                        ret += inc();
                    }
                    return ret;
                }
            },
            "kindaMain",
        );
    }
}
