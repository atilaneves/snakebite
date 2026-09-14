module ut.backends.call.ffi;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


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


// A real `extern(D)` function, not `extern(C)`: on dmd, the host compiler
// that builds `bin/ut`, its parameters reach the registers and the stack
// in reversed declaration order (`snakebite.ffi.abi.reversedDParameters`).
// Nine ABI words (four two-eightbyte `string`s plus one `int`) spill two
// of the four strings to the stack, exercising the same stack-order rule
// `ut.ffi.plan`'s `called.externD.*` tests check at the plan level -
// here through a guest call on every backend instead of `PlanCache`
// directly. `pragma(mangle)` pins a C-style linker name so the guest
// declaration below and this native definition agree on a symbol without
// depending on dmd's own name mangling of a guest-parsed module.
pragma(mangle, "snakebite_ut_extern_d_nine_words")
private extern(D) int snakebite_ut_nineWords(
    string a, string b, string c, string d, int e,
) {
    return cast(int) (a.length + b.length + c.length + d.length) + e;
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


// One INTEGER-class argument, chosen at prepare time as the leaner
// stub entry (`CallPlan._entry`'s own doc), but an SSE-class result -
// the integer entry still stores `%xmm0` into `frame.sseResult` even
// though it never loaded an SSE argument register for the call itself.
public extern(C) double snakebite_ut_double_of_long(long value) {
    return cast(double) value * 1.5;
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

    @("signatures.doubleOfLong." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.0.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_double_of_long")
                extern(C) double doubleOfLong(long value);

                double answer() {
                    return doubleOfLong(6);
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


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("signatures.externD.nineWordsTwoStringsSpill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // The declaration is a `static` struct member, not a free
        // function: dmd's own `Native` oracle here mixes `code` in
        // through a nested lambda (`shouldBeRetOf`), and a *free*
        // extern(D) forward declaration nested that deeply loses dmd's
        // reversed-parameter calling convention (it stops matching the
        // real, module-scope-compiled callee's own ABI). A `static`
        // struct member keeps it, at any nesting depth - this sidesteps
        // an oracle quirk, not a snakebite one; every backend under test
        // still receives an ordinary `extern(D)` free-function call.
        20.shouldBeRetOf!(
            backend,
            q{
                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_extern_d_nine_words")
                    extern(D) int nineWords(
                        string a, string b, string c, string d, int e,
                    );
                }

                int answer() {
                    return Ffi.nineWords("aa", "bbb", "cccc", "d", 10);
                }
            },
            "answer",
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
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
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


private string manyArgumentSignature(string linkage, size_t count) {
    auto code = text("pragma(mangle, \"snakebite_ut_many_", linkage,
        count, "\") extern(", linkage, ") long many", linkage, count, "(");
    foreach (i; 0 .. count)
        code ~= text(i ? ", " : "", "long a", i);
    return code ~ ")";
}


private string manyArgumentBody(size_t count) {
    auto code = "{ long result;";
    foreach (i; 0 .. count)
        code ~= text("result += ", i + 1, " * a", i, ";");
    return code ~ "return result; }";
}


private string manyArgumentCall(string linkage, size_t count) {
    auto code = text("long answer() { return Ffi.many", linkage, count, "(");
    foreach (i; 0 .. count)
        code ~= text(i ? ", " : "", i + 1);
    return code ~ "); }";
}


static foreach (linkage; AliasSeq!("C", "D")) {
    static foreach (count; AliasSeq!(17, 31, 257)) {
        mixin(manyArgumentSignature(linkage, count)
            ~ manyArgumentBody(count));

        static foreach (backend; Matrix!(
            Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
        )) {
            @("manyArguments." ~ linkage ~ count.stringof
                ~ "." ~ backend.stringof)
            @Tags(backend.stringof)
            unittest {
                enum code = "struct Ffi { static: "
                    ~ manyArgumentSignature(linkage, count) ~ "; }"
                    ~ manyArgumentCall(linkage, count);
                enum expected = long(count) * (count + 1)
                    * (2 * count + 1) / 6;
                expected.shouldBeRetOf!(backend, code, "answer");
            }
        }
    }
}


private extern(C) size_t snakebite_ut_many_strings(
    string a, string b, string c, string d, string e,
    string f, string g, string h, string i, string j,
) {
    return a.length + b.length * 2 + c.length * 3 + d.length * 4
        + e.length * 5 + f.length * 6 + g.length * 7 + h.length * 8
        + i.length * 9 + j.length * 10;
}


private alias ManyCallback = extern(D) bool function();


private extern(C) long snakebite_ut_many_callback(
    long a0, long a1, long a2, long a3,
    long a4, long a5, long a6, long a7,
    long a8, long a9, long a10, long a11,
    long a12, long a13, long a14, long a15,
    ManyCallback callback,
) {
    return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7
        + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15
        + (callback() ? 100 : 0);
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("manyArguments.strings." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(385).shouldBeRetOf!(backend, q{
            pragma(mangle, "snakebite_ut_many_strings")
            extern(C) size_t snakebite_ut_many_strings(
                string, string, string, string, string,
                string, string, string, string, string,
            );
            size_t answer() {
                return snakebite_ut_many_strings(
                    "a", "bb", "ccc", "dddd", "eeeee",
                    "ffffff", "ggggggg", "hhhhhhhh", "iiiiiiiii",
                    "jjjjjjjjjj",
                );
            }
        }, "answer");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("manyArguments.callback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(236).shouldBeRetOf!(backend, q{
            alias Callback = extern(D) bool function();
            pragma(mangle, "snakebite_ut_many_callback")
            extern(C) long snakebite_ut_many_callback(
                long, long, long, long, long, long, long, long,
                long, long, long, long, long, long, long, long,
                Callback,
            );
            static bool yes() { return true; }
            long answer() {
                return snakebite_ut_many_callback(
                    1, 2, 3, 4, 5, 6, 7, 8,
                    9, 10, 11, 12, 13, 14, 15, 16, &yes,
                );
            }
        }, "answer");
    }
}


private alias VoidCallback = void delegate();


private extern(C) int snakebite_ut_delegate_value(VoidCallback callback) {
    return 1;
}


private extern(C) int snakebite_ut_delegate_ref(ref VoidCallback callback) {
    return 1;
}


private extern(C) int snakebite_ut_delegate_out(out VoidCallback callback) {
    return 1;
}


private extern(C) int snakebite_ut_delegate_lazy(lazy int value) {
    return 1;
}


static foreach (form; AliasSeq!("value", "ref", "out", "lazy")) {
    static foreach (backend; Matrix!(
        Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
    )) {
        @("delegateArgument." ~ (form == "out" ? "output." : "refused.")
            ~ form ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            enum parameter = form == "lazy" ? "lazy int value"
                : (form == "value" ? "" : form ~ " ") ~ "Callback cb";
            enum argument = form == "lazy" ? "42" : "callback";
            enum code = "alias Callback = void delegate();"
                ~ "pragma(mangle, \"snakebite_ut_delegate_" ~ form ~ "\")"
                ~ "extern(C) int host(" ~ parameter ~ ");"
                ~ "int answer() { int value;"
                ~ "Callback callback = () { ++value; };"
                ~ "return host(" ~ argument ~ "); }";
            static if (is(backend == Native) || form == "out") {
                1.shouldBeRetOf!(backend, code, "answer");
            } else {
                auto module_ = parseSnippet(code);
                auto function_ = findFunction(module_, "answer");
                auto backend_ = new backend(Program([module_]));
                int result;
                backend_.call(function_, &result, [])
                    .shouldThrowWithMessage(
                        "ffi cannot call `host`: guest delegate callbacks "
                            ~ "are not supported");
            }
        }
    }
}


private int _nativeDelegateCalls;


private extern(C) VoidCallback snakebite_ut_native_delegate() {
    _nativeDelegateCalls = 0;
    return () { ++_nativeDelegateCalls; };
}


private extern(C) int snakebite_ut_invoke_delegate(VoidCallback callback) {
    if (callback !is null)
        callback();
    return _nativeDelegateCalls;
}


static foreach (useNull; AliasSeq!(false, true)) {
    static foreach (backend; Matrix!(
        Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
    )) {
        @("delegateArgument.native." ~ useNull.stringof ~ "."
            ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            enum code = q{
                alias Callback = void delegate();
                pragma(mangle, "snakebite_ut_native_delegate")
                extern(C) Callback make();
                pragma(mangle, "snakebite_ut_invoke_delegate")
                extern(C) int invoke(Callback);
            } ~ "int answer() { auto callback = make(); return invoke("
                ~ (useNull ? "null" : "callback") ~ "); }";
            (useNull ? 0 : 1).shouldBeRetOf!(backend, code, "answer");
        }
    }
}
