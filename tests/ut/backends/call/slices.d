module ut.backends.call.slices;


import ut.backends;


// A string literal is the one dynamic array a guest can obtain without
// allocating: its code units already exist, so the array is a pair aimed
// at them, exactly as a compiled program's would be aimed at its read-only
// data.
static foreach (backend; Matrix!()) {
    @("slices.length." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3UL.shouldBeRetOf!(
            backend,
            q{
                ulong result() {
                    auto s = "abc";
                    return s.length;
                }
            },
            "result",
        );
    }
}

// The last element, not the first: a backend that read the pointer without
// the index would answer 'a'.
static foreach (backend; Matrix!()) {
    @("slices.index." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        'c'.shouldBeRetOf!(
            backend,
            q{
                char result() {
                    auto s = "abc";
                    return s[2];
                }
            },
            "result",
        );
    }
}

// `$` inside an index is the array's own length. It is a variable no
// statement declares, so it has no frame slot of its own and must be bound
// before the index is worked out.
static foreach (backend; Matrix!()) {
    @("slices.dollar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        'c'.shouldBeRetOf!(
            backend,
            q{
                char result() {
                    auto s = "abc";
                    return s[$ - 1];
                }
            },
            "result",
        );
    }
}

// A second `$` in the same function, over an array of a different length,
// so a backend binding one length for the whole function disagrees.
static foreach (backend; Matrix!()) {
    @("slices.dollarPerArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        'z'.shouldBeRetOf!(
            backend,
            q{
                char result() {
                    auto three = "abc";
                    auto five = "vwxyz";
                    char kept = three[$ - 3];
                    kept = five[$ - 1];
                    return kept;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.truthy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    auto s = "abc";
                    int ret = 0;
                    if (s)
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("slices.falsy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    string s;
                    int ret = 0;
                    if (!s)
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

// A `static` array starts out `null`, and its storage is one array per
// program rather than one per call, so it is the backend's to make rather
// than a frame's.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable static variable"),
)) {
    @("slices.staticStartsNull." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    static int[] arr;
                    int ret = 0;
                    if (!arr)
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

// Reaching outside the array would read host memory the guest never owned.
// Compiled D answers this with a `RangeError`, which the oracle cannot run
// as a returned value, so this is pinned for the interpreter alone.
@("slices.indexOutOfBounds.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        char result() {
            auto s = "abc";
            return s[$ - 4];
        }
    });
    auto function_ = findFunction(module_, "result");

    char result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}

// `arr = [0]` allocates, and dmd lowers it to a druntime hook, which is
// neither reimplemented here nor called. Pinned so that the array literal
// is a refusal rather than a wrong answer.
@("slices.arrayLiteral.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int result() {
            static int[] arr;
            arr = [0];
            return arr[0];
        }
    });
    auto function_ = findFunction(module_, "result");

    int result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}

// `arr ~= x` allocates the same way, through a druntime hook of its own.
@("slices.append.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int result() {
            static int[] arr;
            arr ~= 1;
            return arr[0];
        }
    });
    auto function_ = findFunction(module_, "result");

    int result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}
