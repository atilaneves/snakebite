module ut.backends.call.ffi;


import ut.backends;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


private extern(C) ubyte[] snakebite_ut_dynamic_array() {
    static ubyte[] values = [17, 31, 47];
    return values;
}


// `abs` is declared `extern(C)` with no body: nothing in the guest program
// implements it, so the only way to run these is to call the real symbol
// the host process already links against.
//
// Two cases, because either one alone passes for the wrong reason. A single
// negative argument would also pass if the argument never reached `abs` at
// all and the answer came from somewhere else, so the two differ in the
// value they expect back. A negative argument alone would also pass against
// a callee that merely negates, so one argument is positive: `abs` must
// leave it alone.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("abs.negative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    import core.stdc.stdlib: abs;
                    return abs(-42);
                }
            },
            "answer",
        );
    }

    @("abs.positive." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    import core.stdc.stdlib: abs;
                    return abs(7);
                }
            },
            "answer",
        );
    }
}


@("dynamicArrayReturn.nativeFFI.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        extern(C) ubyte[] snakebite_ut_dynamic_array();
    });
    auto function_ = findFunction(module_, "snakebite_ut_dynamic_array");
    assert(function_ !is null,
        "No `snakebite_ut_dynamic_array` function in the guest program");

    PlanCache cache;
    ubyte[] result;
    cache.of(function_).call(&result, []);

    result.length.shouldEqual(3);
    result[0].shouldEqual(17);
    result[1].shouldEqual(31);
    result[2].shouldEqual(47);
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.unconfirmed,
        "needs pointers, casts, slicing and slice assignment first"),
)) {
    @("malloc.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(2).shouldBeRetOf!(
            backend,
            q{
                ubyte allocArray() {
                    import core.stdc.stdlib: malloc, free;
                    enum length = 3;
                    auto ptr = cast(ubyte*) malloc(length);
                    auto slc = ptr[0 .. length];
                    slc[] = [0, 1, 2];
                    auto ret = ptr[2];
                    free(ptr);
                    return ret;
                }
            },
            "allocArray",
        );
    }

    @("malloc.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(5).shouldBeRetOf!(
            backend,
            q{
                ubyte allocArray() {
                    import core.stdc.stdlib: malloc, free;
                    enum length = 3;
                    auto ptr = cast(ubyte*) malloc(length);
                    auto slc = ptr[0 .. length];
                    slc[] = [3, 4, 5];
                    auto ret = ptr[2];
                    free(ptr);
                    return ret;
                }
            },
            "allocArray",
        );
    }
}
