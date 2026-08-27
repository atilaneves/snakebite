module ut.backends.call.exceptions;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("assert.passes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    assert(one() < two());
                    return 5;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.unconfirmed, "guest try/catch not implemented"),
)) {
    @("assert.fails.reports.the.line.of.the.assertion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                size_t result() {
                    import core.exception: AssertError;

                    size_t first;

                    try {
                        assert(two() < one());
                    } catch(AssertError e) {
                        first = e.line;
                    }

                    try { assert(two() < one()); }
                    catch(AssertError e) {
                        return e.line - first;
                    }

                    return 0;
                }
            },
            "result",
        );
    }
}

// `AssertError` derives from `Error`, not from `Exception`, so a
// `catch(Exception)` never matches a failing assertion: the error keeps
// unwinding to the `catch(AssertError)` outside it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.unconfirmed, "guest try/catch not implemented"),
)) {
    @("assert.fails.is.not.caught.by.catching.Exception." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    import core.exception: AssertError;

                    try {
                        try {
                            assert(two() < one());
                        } catch(Exception) {
                            return 7;
                        }
                    } catch(AssertError) {
                        return 9;
                    }

                    return 5;
                }
            },
            "result",
        );
    }
}
