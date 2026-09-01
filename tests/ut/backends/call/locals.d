module ut.backends.call.locals;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


@("locals.voidInitializerPerformsNoValueEvaluation.Interpreter")
@Tags("Interpreter")
unittest {
    43.shouldBeRetOf!(
        Interpreter,
        q{
            int result() {
                int value = void;
                value = 43;
                return value;
            }
        },
        "result",
    );
}


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

static foreach (backend; Matrix!()) {
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

@("locals.dynamicArrayInitialisesAcrossCalls.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        size_t appendOne() {
            string[] messages;
            messages ~= "failure";
            return messages.length;
        }
    });
    auto function_ = findFunction(module_, "appendOne");
    auto interpreter = interpreter(module_);

    size_t first;
    interpreter.call(function_, &first, []);
    first.shouldEqual(1);

    size_t second;
    interpreter.call(function_, &second, []);
    second.shouldEqual(1);
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE can't mutate a static local"),
)) {
    @("locals.staticPersistsAcrossCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A `static` local's storage lives once per function, not once per
        // call: `n` keeps whatever `inc` left it at, so five calls add
        // 8 + 9 + 10 + 11 + 12. A backend that re-runs the initialiser on
        // every call instead sees `n` reset to 7 each time, and returns 40.
        50UL.shouldBeRetOf!(
            backend,
            q{
                ulong inc() {
                    static ulong n = 7;
                    n += 1;
                    return n;
                }

                ulong kindaMain() {
                    ulong ret = 0;
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

@("locals.staticPersistsAcrossBackendCalls.Bytecode")
@Tags("Bytecode")
unittest {
    auto module_ = parseSnippet(q{
        int next() {
            static int value;
            value += 1;
            return value;
        }
    });
    auto function_ = findFunction(module_, "next");
    auto backend = new Bytecode(Program([module_]));

    int first;
    backend.call(function_, &first, []);
    first.shouldEqual(1);

    int second;
    backend.call(function_, &second, []);
    second.shouldEqual(2);
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE can't mutate a static local"),
)) {
    @("locals.staticDefaultInitialiser." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int read() {
                    static int value;
                    return value + 1;
                }
            },
            "read",
        );
    }
}
