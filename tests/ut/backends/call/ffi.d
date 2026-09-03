module ut.backends.call.ffi;


import ut.backends;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


private extern(C) ubyte[] snakebite_ut_dynamic_array() {
    static ubyte[] values = [17, 31, 47];
    return values;
}


// The bytecode backend can receive this value from a native call without
// copying it. A disabled copy constructor keeps the test outside its
// bytewise plain-struct path.
private struct NonCopyableAggregate {
    long first;
    long second;
    long third;

    @disable this(this);
}


private int nonCopyableAggregateCalls;


private extern(C) void snakebite_ut_reset_non_copyable_aggregate_calls() {
    nonCopyableAggregateCalls = 0;
}


private extern(C) NonCopyableAggregate
    snakebite_ut_non_copyable_aggregate() {
    ++nonCopyableAggregateCalls;
    return NonCopyableAggregate(17, 31, 47);
}


private extern(C) int snakebite_ut_non_copyable_aggregate_call_count() {
    return nonCopyableAggregateCalls;
}


private int remembered;


public extern(C) void snakebite_ut_remember(int value) {
    remembered = value;
}


public extern(C) int snakebite_ut_recall() {
    return remembered;
}


public extern(C) int snakebite_ut_add(int left, int right) {
    return left + right;
}


public extern(C) short snakebite_ut_narrow(byte left, ushort right) {
    return cast(short) (left + right);
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


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.unconfirmed,
        "pragma(mangle) native declarations are not routed through FFI"),
)) {
    @("aggregateReturn.localDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                struct NonCopyableAggregate {
                    long first;
                    long second;
                    long third;

                    @disable this(this);
                }

                pragma(mangle,
                    "snakebite_ut_reset_non_copyable_aggregate_calls")
                extern(C) void resetCalls();
                pragma(mangle, "snakebite_ut_non_copyable_aggregate")
                extern(C) NonCopyableAggregate getAggregate();
                pragma(mangle,
                    "snakebite_ut_non_copyable_aggregate_call_count")
                extern(C) int callCount();

                int answer() {
                    resetCalls();
                    auto value = getAggregate();
                    return callCount();
                }
            },
            "answer",
        );
    }
}


// These declarations cover different native signatures through the same
// guest call syntax. Together they require zero and several parameters,
// a void result, a discarded result, and narrow native-layout values.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.unconfirmed,
        "pragma(mangle) native declarations are not routed through FFI"),
)) {
    @("signatures.arityAndDiscard." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_remember")
                extern(C) void nativeRemember(int);
                pragma(mangle, "snakebite_ut_recall")
                extern(C) int nativeRecall();
                pragma(mangle, "snakebite_ut_add")
                extern(C) int nativeAdd(int, int);

                int answer() {
                    nativeRemember(10);
                    nativeAdd(100, 200);
                    return nativeAdd(nativeRecall(), 32);
                }
            },
            "answer",
        );
    }

    @("signatures.narrowValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(42).shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_narrow")
                extern(C) short nativeNarrow(byte, ushort);

                short answer() {
                    return nativeNarrow(byte(-2), ushort(44));
                }
            },
            "answer",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("callSite.cacheSurvivesPlanCacheGrowth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int repeat() {
                    import core.stdc.stdlib: abs;
                    int result;
                    for (int i = 0; i < 2; ++i) {
                        result = abs(-42);
                        if (i == 0)
                            result = abs(result);
                    }
                    return result;
                }
            },
            "repeat",
        );
    }
}


@("dynamicArrayReturn.nativeFFI.Interpreter")
@Tags("Interpreter")
unittest {
    // `findFunction` takes a mutable DMD module, so this local cannot be
    // const even though the test does not otherwise mutate it.
    auto module_ = parseSnippet(q{
        extern(C) ubyte[] snakebite_ut_dynamic_array();
    });
    // `PlanCache.of` takes a mutable DMD function declaration, so this local
    // cannot be const even though the test does not otherwise mutate it.
    auto function_ = findFunction(module_, "snakebite_ut_dynamic_array");
    assert(function_ !is null,
        "No `snakebite_ut_dynamic_array` function in the guest program");

    PlanCache cache;
    ubyte[] result;
    cache.of(function_).call(&result, []);

    result.length.should == 3;
    result[0].should == 17;
    result[1].should == 31;
    result[2].should == 47;
}

static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
