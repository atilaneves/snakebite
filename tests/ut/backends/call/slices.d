module ut.backends.call.slices;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("slices.length." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A string literal is a slice of code units the compiler already
        // laid out, so `.length` is the first word of the pair without
        // anything having to allocate.
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                size_t length_() {
                    string text = "hello";
                    return text.length;
                }
            },
            "length_",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.index." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        'e'.shouldBeRetOf!(
            backend,
            q{
                char second() {
                    string text = "hello";
                    size_t index = 1;
                    return text[index];
                }
            },
            "second",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.dollar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `$` inside an index is a variable of its own that no statement
        // declares: dmd rewrites `text[$ - 1]` into an index over a
        // declaration it makes for the array's length.
        'o'.shouldBeRetOf!(
            backend,
            q{
                char last() {
                    string text = "hello";
                    return text[$ - 1];
                }
            },
            "last",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.dollar.nested." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Each index expression has its own `$`. `oneIfLastIsSet` indexes
        // its own array while the outer index in `pick` is still being
        // evaluated, so the inner `$` must stand for `flag`'s length, and
        // the outer one for `text`'s again afterwards.
        'l'.shouldBeRetOf!(
            backend,
            q{
                size_t oneIfLastIsSet(string bytes) {
                    if(bytes[$ - 1])
                        return 1;
                    return 0;
                }

                char pick() {
                    string text = "hello";
                    string flag = "yo";
                    return text[$ - oneIfLastIsSet(flag) - 1];
                }
            },
            "pick",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.truth.null." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A `null` slice is false where D asks for a condition, and both
        // words of it are zero.
        1.shouldBeRetOf!(
            backend,
            q{
                int nothing() {
                    string text = null;
                    if(!text)
                        return 1;
                    return 0;
                }
            },
            "nothing",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.truth.literal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                int something() {
                    string text = "hello";
                    if(text)
                        return 2;
                    return 0;
                }
            },
            "something",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.comma." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Two expressions where a `for` initialiser wants one is a comma
        // expression, the same node dmd builds when it lowers one source
        // expression into several.
        13.shouldBeRetOf!(
            backend,
            q{
                int both() {
                    int i;
                    int j;
                    for(i = 0, j = 10; i < 3; i = i + 1) {
                    }
                    return i + j;
                }
            },
            "both",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter neither bounds-checks an index nor implements " ~
        "guest try/catch"),
)) {
    @("slices.index.outOfRange.throws.RangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // An index outside the array is a `RangeError`, which derives from
        // `Error`: compiled D checks every index it cannot prove in range.
        'x'.shouldBeRetOf!(
            backend,
            q{
                char past() {
                    import core.exception: RangeError;

                    string text = "hello";
                    size_t index = 5;

                    try
                        return text[index];
                    catch(RangeError)
                        return 'x';
                }
            },
            "past",
        );
    }
}
