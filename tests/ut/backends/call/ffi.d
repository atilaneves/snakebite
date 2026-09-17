module ut.backends.call.ffi;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


public extern(C) typeof(null) snakebite_ut_null_value(typeof(null) value) {
    assert(value is null);
    return value;
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call an external function without source"),
)) {
    @("ffi.nullValueArgumentAndReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            pragma(mangle, "snakebite_ut_null_value")
            extern(C) typeof(null) snakebite_ut_null_value(typeof(null));

            void main() {
                auto value = snakebite_ut_null_value(null);
                assert(value is null);
            }
        });
    }
}


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


// The MEMORY-class shapes below (issue #334 step 3) mirror
// `tests/ut/ffi/plan.d`'s own `called.memoryClassParameter*` tests at the
// plan level - here, through a guest call on every backend instead of
// `PlanCache` directly.
private struct MemoryTriple {
    size_t first;
    size_t second;
    size_t third;
}


public extern(C) size_t snakebite_ut_memory_triple(MemoryTriple value) {
    return value.first * 100 + value.second * 10 + value.third;
}


private struct MemoryQuad {
    size_t first;
    size_t second;
    size_t third;
    size_t fourth;
}


pragma(mangle, "snakebite_ut_memory_after_six_backend")
public extern(C) size_t snakebite_ut_memory_after_six_backend(
    int a, int b, int c, int d, int e, int f, MemoryQuad value, int g,
) {
    return a + b + c + d + e + f + value.first * 10_000
        + value.second * 1_000 + value.third * 100 + value.fourth * 10 + g;
}


private struct PackedPair {
    int a;
    align(1) long b;
}


pragma(mangle, "snakebite_ut_packed_pair_backend")
public extern(C) long snakebite_ut_packed_pair_backend(PackedPair value) {
    return value.a + value.b;
}


pragma(mangle, "snakebite_ut_extern_d_memory_two_spill_backend")
private extern(D) long snakebite_ut_externDMemoryTwoSpill(
    long a0, long a1, long a2, long a3, long a4, long a5,
    MemoryTriple value, long b0, long b1,
) {
    return a0 * 1_000_000 + a1 * 100_000 + b0 * 100 + b1
        + cast(long) (value.first * 1000 + value.second * 10
            + value.third);
}


pragma(mangle, "snakebite_ut_memory_with_sse_backend")
public extern(C) double snakebite_ut_memory_with_sse_backend(
    double x, double y, MemoryTriple value,
) {
    return x + y + value.first * 100 + value.second * 10 + value.third;
}


private struct TwentyBytes {
    int a;
    int b;
    int c;
    int d;
    int e;
}


pragma(mangle, "snakebite_ut_twenty_bytes_backend")
public extern(C) int snakebite_ut_twenty_bytes_backend(TwentyBytes value) {
    return value.a * 10_000 + value.b * 1_000 + value.c * 100
        + value.d * 10 + value.e;
}


pragma(mangle, "snakebite_ut_memory_triple_transform_backend")
public extern(C) MemoryTriple snakebite_ut_memoryTripleTransform_backend(
    MemoryTriple value,
) {
    return MemoryTriple(
        value.first + 1, value.second + 2, value.third + 3);
}


pragma(mangle, "snakebite_ut_extern_d_two_memory_backend")
public extern(D) long snakebite_ut_twoMemoryParams_backend(
    MemoryTriple first, MemoryQuad second,
) {
    return cast(long) (first.first * 1_000_000 + first.second * 100_000
        + first.third * 10_000 + second.first * 1_000 + second.second * 100
        + second.third * 10 + second.fourth);
}


private struct SixteenBytesAligned {
    int a;
    align(1) long b;
    int c;
}


pragma(mangle, "snakebite_ut_sixteen_bytes_aligned_backend")
public extern(C) long snakebite_ut_sixteen_bytes_aligned_backend(
    SixteenBytesAligned value,
) {
    return value.a * 10_000 + value.b * 100 + value.c;
}


// The mixed INTEGER/SSE shapes below (issue #334 step 4) mirror
// `tests/ut/ffi/plan.d`'s own `called.mixedStruct*`/`called.externD.
// mixedStruct*` tests at the plan level - here, through a guest call on
// every backend instead of `PlanCache` directly.
private struct MixedPair {
    int integer;
    double floating;
}


public extern(C) long snakebite_ut_mixed_registers(MixedPair value) {
    return value.integer * 1000 + cast(long) value.floating;
}


public extern(C) long snakebite_ut_mixed_after_six_then_scalar(
    int a, int b, int c, int d, int e, int f, MixedPair value, double g,
) {
    return a + b + c + d + e + f
        + value.integer * 1000 + cast(long) value.floating
        + cast(long) (g * 1_000_000.0);
}


// Kept under a new name from before `snakebite_ut_mixed_after_six_then_
// scalar` above became the `double g` free-SSE-register check: `g` here
// is still `int`, still spilled behind `value` for lack of any integer
// register left - a different scenario (a scalar spilled behind the
// aggregate, not a free register in the other file left untouched).
public extern(C) long snakebite_ut_mixed_after_six_then_int_scalar(
    int a, int b, int c, int d, int e, int f, MixedPair value, int g,
) {
    return a + b + c + d + e + f
        + value.integer * 1000 + cast(long) value.floating
        + g * 1_000_000L;
}


public extern(C) long snakebite_ut_mixed_after_eight_doubles(
    double a, double b, double c, double d,
    double e, double f, double g, double h,
    MixedPair value, int i,
) {
    return cast(long) (a + b + c + d + e + f + g + h)
        + value.integer * 1000 + cast(long) value.floating
        + i * 1_000_000L;
}


public extern(C) long snakebite_ut_mixed_both_files_full_backend(
    long i0, long i1, long i2, long i3, long i4, long i5,
    double d0, double d1, double d2, double d3, double d4, double d5,
    double d6, double d7,
    MixedPair value,
) {
    return i0 + i1 + i2 + i3 + i4 + i5
        + cast(long) (d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7)
        + value.integer * 1000 + cast(long) value.floating;
}


pragma(mangle, "snakebite_ut_extern_d_mixed_struct_scalar_spill")
private extern(D) long snakebite_ut_externDMixedStructScalarSpill(
    long a, MixedPair value,
    long j0, long j1, long j2, long j3, long j4, long j5,
) {
    return a * 1_000_000
        + value.integer * 1000 + cast(long) value.floating
        + j0;
}


private struct MixedPairReversed {
    double floating;
    int integer;
}


public extern(C) long snakebite_ut_mixed_reversed_after_six_backend(
    int a, int b, int c, int d, int e, int f, MixedPairReversed value,
) {
    return a + b + c + d + e + f
        + cast(long) value.floating * 100 + value.integer;
}


// Eight `double`s fill the SSE register file, and the integer register
// file is free - `value`'s SSE lane (`floating`, declared first in
// `MixedPairReversed`) has no register left, so the whole aggregate
// spills, the mirror image of `snakebite_ut_mixed_reversed_after_six_
// backend` above, where the *integer* file was the full one. This is the
// case where a per-lane implementation would split the aggregate: its
// INTEGER lane (`integer`) would still fit a free integer register.
public extern(C) long snakebite_ut_mixed_reversed_after_eight_doubles(
    double x0, double x1, double x2, double x3,
    double x4, double x5, double x6, double x7,
    MixedPairReversed value,
) {
    return cast(long) (x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7)
        + cast(long) value.floating * 100 + value.integer;
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


// A 24-byte struct (three `size_t` fields) by value, passed to a host
// `extern(C)` function that sums its fields - the ABI class MEMORY,
// larger than two eightbytes, used to be refused outright (issue #334
// step 3). The callee weights each field differently, the way
// `snakebite_ut_eightLongs` (`ut.ffi.plan`) does, so a permuted
// eightbyte order changes the answer instead of leaving a plain sum
// unchanged.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.threeWords." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2_057.shouldBeRetOf!(
            backend,
            q{
                struct MemoryTriple {
                    size_t first;
                    size_t second;
                    size_t third;
                }

                pragma(mangle, "snakebite_ut_memory_triple")
                extern(C) size_t nativeMemoryTriple(MemoryTriple value);

                int answer() {
                    MemoryTriple value;
                    value.first = 17;
                    value.second = 31;
                    value.third = 47;
                    return cast(int) nativeMemoryTriple(value);
                }
            },
            "answer",
        );
    }
}


// A 32-byte MEMORY-class struct declared after six plain `int`s, which
// already fill the integer register file, with one more `int` declared
// after it - the struct and the trailing `int` both spill, and must land
// on the stack in declaration order (issue #334 step 3). `g`'s weight
// (`1`) differs from `value.fourth`'s (`10`), the word next to it on the
// stack, so swapping either with the other changes the answer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.afterSixIntegersThenOneMore." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        123_428.shouldBeRetOf!(
            backend,
            q{
                struct MemoryQuad {
                    size_t first;
                    size_t second;
                    size_t third;
                    size_t fourth;
                }

                pragma(mangle, "snakebite_ut_memory_after_six_backend")
                extern(C) size_t nativeMemoryAfterSix(
                    int a, int b, int c, int d, int e, int f,
                    MemoryQuad value, int g,
                );

                int answer() {
                    MemoryQuad value;
                    value.first = 10;
                    value.second = 20;
                    value.third = 30;
                    value.fourth = 40;
                    return cast(int) nativeMemoryAfterSix(
                        1, 2, 3, 4, 5, 6, value, 7);
                }
            },
            "answer",
        );
    }
}


// `b`'s `align(1)` forces it to sit at offset 4, not the 8-byte boundary
// its own type (`long`) needs - the SysV ABI classifies an aggregate with
// an unaligned field as MEMORY regardless of its size, so this 12-byte
// struct, under the 16-byte threshold that alone would trigger MEMORY,
// still does (issue #334 step 3).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.unalignedField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct PackedPair {
                    int a;
                    align(1) long b;
                }

                pragma(mangle, "snakebite_ut_packed_pair_backend")
                extern(C) long nativePackedPair(PackedPair value);

                int answer() {
                    PackedPair value;
                    value.a = 3;
                    value.b = 39;
                    return cast(int) nativePackedPair(value);
                }
            },
            "answer",
        );
    }
}


// A MEMORY-class struct passed to a host `extern(D)` function on dmd,
// where two other `long` parameters also spill - dmd's reversed
// `extern(D)` convention places every spilled argument, `value` included,
// on the stack in descending declaration order (issue #334 step 3). The
// `Ffi` static struct member sidesteps a `shouldBeRetOf` oracle quirk - a
// free `extern(D)` forward declaration nested this deeply loses dmd's own
// reversed calling convention - the same trick
// `signatures.externD.nineWordsTwoStringsSpill` above uses.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.externD.twoScalarSpills." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_217_289.shouldBeRetOf!(
            backend,
            q{
                struct MemoryTriple {
                    size_t first;
                    size_t second;
                    size_t third;
                }

                struct Ffi {
                    static:
                    pragma(mangle,
                        "snakebite_ut_extern_d_memory_two_spill_backend")
                    extern(D) long externDMemoryTwoSpill(
                        long a0, long a1, long a2, long a3, long a4,
                        long a5, MemoryTriple value, long b0, long b1,
                    );
                }

                int answer() {
                    MemoryTriple value;
                    value.first = 7;
                    value.second = 8;
                    value.third = 9;
                    return cast(int) Ffi.externDMemoryTwoSpill(
                        1, 2, 3, 4, 5, 6, value, 100, 200);
                }
            },
            "answer",
        );
    }
}


// A MEMORY-class struct declared after two `double`s, which stay in
// `%xmm0`/`%xmm1` - room in the SSE register file does not change
// `value`'s own class, and its always-on-stack placement must not
// disturb the SSE arguments' own register assignment (issue #334 step 3).
// `value`'s three fields carry different weights, so a permuted
// eightbyte order changes the answer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.withSSEArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_234.0.shouldBeRetOf!(
            backend,
            q{
                struct MemoryTriple {
                    size_t first;
                    size_t second;
                    size_t third;
                }

                pragma(mangle, "snakebite_ut_memory_with_sse_backend")
                extern(C) double nativeMemoryWithSse(
                    double x, double y, MemoryTriple value,
                );

                double answer() {
                    MemoryTriple value;
                    value.first = 10;
                    value.second = 20;
                    value.third = 30;
                    return nativeMemoryWithSse(1.5, 2.5, value);
                }
            },
            "answer",
        );
    }
}


// Five plain `int` fields: 20 bytes, whose last eightbyte (`value`'s
// bytes 16-19, field `e` alone) is only half full. The move for that
// eightbyte must copy only those 4 remaining bytes, never reading past
// `value`'s own 20 bytes of storage (issue #334 step 3). Each field
// carries a different weight so a permuted word order changes the
// answer; the plan-level `called.memoryClassParameter.
// partialLastEightbyte` (`ut.ffi.plan`) additionally places `value` at
// the end of a guarded page, so an over-read faults instead of just
// reading harmless padding - an ordinary struct here is enough, since
// this test's own job is the matrix, not the over-read.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.partialLastEightbyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12_345.shouldBeRetOf!(
            backend,
            q{
                struct TwentyBytes {
                    int a;
                    int b;
                    int c;
                    int d;
                    int e;
                }

                pragma(mangle, "snakebite_ut_twenty_bytes_backend")
                extern(C) int nativeTwentyBytes(TwentyBytes value);

                int answer() {
                    TwentyBytes value;
                    value.a = 1;
                    value.b = 2;
                    value.c = 3;
                    value.d = 4;
                    value.e = 5;
                    return nativeTwentyBytes(value);
                }
            },
            "answer",
        );
    }
}


// A MEMORY-class struct both passed and returned in the same call - the
// plan-level `called.memoryClassParameter.returnedAndPassed`
// (`ut.ffi.plan`) checks the interaction with `_returnPointerOffset`
// directly; here through a guest call on every backend instead (issue
// #334 step 3).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.returnedAndPassed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2_180.shouldBeRetOf!(
            backend,
            q{
                struct MemoryTriple {
                    size_t first;
                    size_t second;
                    size_t third;
                }

                pragma(mangle, "snakebite_ut_memory_triple_transform_backend")
                extern(C) MemoryTriple nativeMemoryTripleTransform(
                    MemoryTriple value,
                );

                int answer() {
                    MemoryTriple value;
                    value.first = 17;
                    value.second = 31;
                    value.third = 47;
                    auto result = nativeMemoryTripleTransform(value);
                    return cast(int) (result.first * 100
                        + result.second * 10 + result.third);
                }
            },
            "answer",
        );
    }
}


// Two MEMORY-class parameters in one call - both always spill, and dmd's
// reversed `extern(D)` convention places every spilled argument on the
// stack in descending declaration order, so `second`'s four eightbytes
// land before `first`'s three. The plan-level `called.
// memoryClassParameter.twoParameters` (`ut.ffi.plan`) checks each field
// individually through globals; here the native callee folds both
// structs into one weighted result instead, since a guest call only has
// a return value to check. The `Ffi` static struct member sidesteps the
// same oracle quirk `memoryClassParameter.externD.twoScalarSpills`
// above does.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.twoParameters." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_242_340.shouldBeRetOf!(
            backend,
            q{
                struct MemoryTriple {
                    size_t first;
                    size_t second;
                    size_t third;
                }

                struct MemoryQuad {
                    size_t first;
                    size_t second;
                    size_t third;
                    size_t fourth;
                }

                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_extern_d_two_memory_backend")
                    extern(D) long twoMemoryParams(
                        MemoryTriple first, MemoryQuad second,
                    );
                }

                int answer() {
                    MemoryTriple first;
                    first.first = 1;
                    first.second = 2;
                    first.third = 3;
                    MemoryQuad second;
                    second.first = 10;
                    second.second = 20;
                    second.third = 30;
                    second.fourth = 40;
                    return cast(int) Ffi.twoMemoryParams(first, second);
                }
            },
            "answer",
        );
    }
}


// A 16-byte struct with an `align(1)` field - MEMORY purely by alignment
// (`abi.classify`'s field-offset check), not by size, unlike
// `memoryClassParameter.unalignedField`'s 12-byte `PackedPair`. Its own
// size is a whole number of eightbytes, so both of `value`'s moves are
// full `word64` loads - no partial-eightbyte `copy`, unlike
// `partialLastEightbyte` (issue #334 step 3).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("memoryClassParameter.sixteenBytesAlignedField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        33_905.shouldBeRetOf!(
            backend,
            q{
                struct SixteenBytesAligned {
                    int a;
                    align(1) long b;
                    int c;
                }

                pragma(mangle, "snakebite_ut_sixteen_bytes_aligned_backend")
                extern(C) long nativeSixteenBytesAligned(
                    SixteenBytesAligned value,
                );

                int answer() {
                    SixteenBytesAligned value;
                    value.a = 3;
                    value.b = 39;
                    value.c = 5;
                    return cast(int) nativeSixteenBytesAligned(value);
                }
            },
            "answer",
        );
    }
}


private alias VoidCallback = void delegate();


private extern(C) int snakebite_ut_delegate_value(VoidCallback callback) {
    callback();
    return 1;
}


private extern(C) int snakebite_ut_delegate_ref(ref VoidCallback callback) {
    callback();
    return 1;
}


private extern(C) int snakebite_ut_delegate_out(out VoidCallback callback) {
    return 1;
}


private extern(C) int snakebite_ut_delegate_lazy(lazy int value) {
    return value + value;
}


// A guest delegate handed to host code by value, by `ref`, or as dmd's
// implicit `lazy` delegate is called by the host through its pool entry
// (ADR-0003), with its own context word: `++value` in the closure changes
// the guest's `value`, which `answer` adds to the host's result. An `out`
// delegate travels the other way, so the host only writes it.
static foreach (form; AliasSeq!("value", "ref", "out", "lazy")) {
    static foreach (backend; Matrix!(
        Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
    )) {
        @("delegateArgument." ~ (form == "out" ? "output." : "called.")
            ~ form ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            enum parameter = form == "lazy" ? "lazy int value"
                : (form == "value" ? "" : form ~ " ") ~ "Callback cb";
            enum argument = form == "lazy" ? "value + 21" : "callback";
            enum code = "alias Callback = void delegate();"
                ~ "pragma(mangle, \"snakebite_ut_delegate_" ~ form ~ "\")"
                ~ "extern(C) int host(" ~ parameter ~ ");"
                ~ "int answer() { int value;"
                ~ "Callback callback = () { ++value; };"
                ~ "return host(" ~ argument ~ ") + value; }";
            enum expected = form == "out" ? 1 : form == "lazy" ? 42 : 2;
            expected.shouldBeRetOf!(backend, code, "answer");
        }
    }
}


private extern(C) int snakebite_ut_delegate_throwCaughtAsException(
    VoidCallback callback,
) {
    try {
        callback();
        return 0;
    } catch (Exception exception) {
        return typeid(exception) is typeid(Exception) ? 1 : 2;
    }
}


// A guest `throw` inside a callback unwinds through the host frames
// untouched (ADR-0004): a host `catch (Exception e)` must see the real
// guest exception object, not this backend's own private wrapper for it.
// Before a callback's re-entry shared `runHostToGuest` with the program
// runner's top-level `call`, only `call` unwrapped that private wrapper;
// a callback re-entry did not, so `typeid(e)` here would have named the
// wrapper instead of the plain `Exception` the guest actually threw.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("callback.hostCatchesGuestException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum code = q{
            alias Callback = void delegate();
            pragma(mangle, "snakebite_ut_delegate_throwCaughtAsException")
            extern(C) int host(Callback);

            int answer() {
                Callback callback = () { throw new Exception("boom"); };
                return host(callback);
            }
        };
        1.shouldBeRetOf!(backend, code, "answer");
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


// A mixed INTEGER/SSE aggregate (one plain `int` eightbyte, one `double`
// eightbyte) with both register files free - the control for the shapes
// below: both eightbytes fit and travel in registers (issue #334 step 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.registers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        39_001L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPair {
                    int integer;
                    double floating;
                }

                pragma(mangle, "snakebite_ut_mixed_registers")
                extern(C) long nativeMixedRegisters(MixedPair value);

                long answer() {
                    MixedPair value;
                    value.integer = 39;
                    value.floating = 1.5;
                    return nativeMixedRegisters(value);
                }
            },
            "answer",
        );
    }
}


// Six plain `int`s already fill the integer register file, and the SSE
// register file is free - `value`'s INTEGER lane has no register left,
// so the whole aggregate goes to the stack, both eightbytes together
// (psABI 3.2.3 classification step 5c), consuming no register from
// either file. `g`, a `double` declared after `value`, proves the free
// SSE file was left untouched by that spill: a `buildMoves` that still
// bumped the SSE count for the aggregate's own free-fitting SSE lane
// would place `g` in `%xmm1`, but the real native callee below (built by
// dmd, following the true ABI) reads it from `%xmm0` (issue #334 step 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.onStackAfterSixIntegersThenScalar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9_007_211L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPair {
                    int integer;
                    double floating;
                }

                pragma(mangle, "snakebite_ut_mixed_after_six_then_scalar")
                extern(C) long nativeMixedAfterSixThenScalar(
                    int a, int b, int c, int d, int e, int f,
                    MixedPair value, double g,
                );

                long answer() {
                    MixedPair value;
                    value.integer = 7;
                    value.floating = 1.5;
                    return nativeMixedAfterSixThenScalar(
                        10, 20, 30, 40, 50, 60, value, 9.0);
                }
            },
            "answer",
        );
    }
}


// The same six plain `int`s as above, but the trailing scalar is `int`,
// not `double`: with the integer file already full, `g` has nowhere to
// go either, and spills behind `value` on the stack - a scalar spilled
// behind the aggregate, not a free register in the other file left
// untouched (the scenario the test above now covers). Kept under this
// new name so both scenarios stay tested (issue #334 step 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.onStackAfterSixIntegersThenIntScalar."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9_007_211L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPair {
                    int integer;
                    double floating;
                }

                pragma(mangle,
                    "snakebite_ut_mixed_after_six_then_int_scalar")
                extern(C) long nativeMixedAfterSixThenIntScalar(
                    int a, int b, int c, int d, int e, int f,
                    MixedPair value, int g,
                );

                long answer() {
                    MixedPair value;
                    value.integer = 7;
                    value.floating = 1.5;
                    return nativeMixedAfterSixThenIntScalar(
                        10, 20, 30, 40, 50, 60, value, 9);
                }
            },
            "answer",
        );
    }
}


// Eight `double`s already fill the SSE register file, and the integer
// register file is free - `value`'s SSE lane has no register left, so the
// whole aggregate goes to the stack, both eightbytes together, consuming
// no register from either file. `g`, an `int` declared after `value`,
// proves the free integer file was left untouched by that spill: a
// `buildMoves` that still bumped the integer count for the aggregate's
// own free-fitting INTEGER lane would place `g` in `%rsi`, but the real
// native callee below reads it from `%rdi` (issue #334 step 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.onStackAfterEightDoubles." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3_007_037L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPair {
                    int integer;
                    double floating;
                }

                pragma(mangle, "snakebite_ut_mixed_after_eight_doubles")
                extern(C) long nativeMixedAfterEightDoubles(
                    double a, double b, double c, double d,
                    double e, double f, double g, double h,
                    MixedPair value, int i,
                );

                long answer() {
                    MixedPair value;
                    value.integer = 7;
                    value.floating = 1.5;
                    return nativeMixedAfterEightDoubles(
                        1, 2, 3, 4, 5, 6, 7, 8, value, 3);
                }
            },
            "answer",
        );
    }
}


// Six `long`s fill the integer register file and eight `double`s fill the
// SSE register file - `value`'s INTEGER lane and its SSE lane both have
// no register left in their own file, the shape the old code refused
// with "ffi cannot place a mixed INTEGER/SSE aggregate when both register
// files need stack arguments". Per the psABI's classification step 5c,
// this still just spills: the whole argument goes to the stack, both
// eightbytes together (issue #334 step 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.bothFilesFull." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7_030L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPair {
                    int integer;
                    double floating;
                }

                pragma(mangle, "snakebite_ut_mixed_both_files_full_backend")
                extern(C) long nativeMixedBothFilesFull(
                    long i0, long i1, long i2, long i3, long i4, long i5,
                    double d0, double d1, double d2, double d3, double d4,
                    double d5, double d6, double d7,
                    MixedPair value,
                );

                long answer() {
                    MixedPair value;
                    value.integer = 7;
                    value.floating = 1.5;
                    return nativeMixedBothFilesFull(
                        1, 2, 3, 4, 5, 6,
                        1, 1, 1, 1, 1, 1, 1, 1,
                        value);
                }
            },
            "answer",
        );
    }
}


// dmd applies the C ABI to the fully reversed parameter list (see
// `signatures.externD.nineWordsTwoStringsSpill`'s own comment, and the
// same real native `extern(D)` setup here for the same oracle-quirk
// reason), so the six trailing `long`s below (`j0` .. `j5`) claim the
// integer register file first, in reverse. `value` - a mixed
// INTEGER/SSE pair whose INTEGER lane then has no register left - spills
// whole, and `a`, declared before it but reached after it in the
// reversed order, spills too; both must land correctly under dmd's
// reversed spill order (issue #334 step 4). Verified with `objdump
// --disassemble` on the compiled callee: `mov 0x20(%rsp),%ebx` reads
// `value.integer` from stack word 0, `movsd 0x28(%rsp),%xmm0` reads
// `value.floating` from word 1, and `mov 0x30(%rsp),%rax` reads `a`
// from word 2.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.externD.scalarSpill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        99_007_011L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPair {
                    int integer;
                    double floating;
                }

                struct Ffi {
                    static:
                    pragma(mangle,
                        "snakebite_ut_extern_d_mixed_struct_scalar_spill")
                    extern(D) long externDMixedStructScalarSpill(
                        long a, MixedPair value,
                        long j0, long j1, long j2, long j3, long j4,
                        long j5,
                    );
                }

                long answer() {
                    MixedPair value;
                    value.integer = 7;
                    value.floating = 1.5;
                    return Ffi.externDMixedStructScalarSpill(
                        99, value, 10, 20, 30, 40, 50, 60);
                }
            },
            "answer",
        );
    }
}


// `MixedPairReversed` declares its SSE-class field (`floating`) before
// its INTEGER-class one (`integer`) - the opposite field order from
// `MixedPair` above. Six plain `int`s fill the integer register file, so
// `value` spills; the stack copy must keep `floating`'s eightbyte before
// `integer`'s, matching the struct's own declaration order (issue #334
// step 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.doubleFirstLayoutSpills." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        258L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPairReversed {
                    double floating;
                    int integer;
                }

                pragma(mangle,
                    "snakebite_ut_mixed_reversed_after_six_backend")
                extern(C) long nativeMixedReversedAfterSix(
                    int a, int b, int c, int d, int e, int f,
                    MixedPairReversed value,
                );

                long answer() {
                    MixedPairReversed value;
                    value.floating = 2.0;
                    value.integer = 37;
                    return nativeMixedReversedAfterSix(
                        1, 2, 3, 4, 5, 6, value);
                }
            },
            "answer",
        );
    }
}


// Eight `double`s fill the SSE register file, and the integer register
// file is free - `value`'s SSE lane (`floating`, `MixedPairReversed`'s
// first field) has no register left, so the whole aggregate spills, the
// mirror image of `mixedStruct.doubleFirstLayoutSpills` above, where the
// *integer* file was the full one. This is the shape where a per-lane
// implementation would split the aggregate, since its INTEGER lane
// (`integer`) would still fit a free integer register (issue #334 step
// 4).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("mixedStruct.reversedAfterEightDoubles." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        245L.shouldBeRetOf!(
            backend,
            q{
                struct MixedPairReversed {
                    double floating;
                    int integer;
                }

                pragma(mangle,
                    "snakebite_ut_mixed_reversed_after_eight_doubles")
                extern(C) long nativeMixedReversedAfterEightDoubles(
                    double x0, double x1, double x2, double x3,
                    double x4, double x5, double x6, double x7,
                    MixedPairReversed value,
                );

                long answer() {
                    MixedPairReversed value;
                    value.floating = 2.0;
                    value.integer = 37;
                    return nativeMixedReversedAfterEightDoubles(
                        1, 1, 1, 1, 1, 1, 1, 1, value);
                }
            },
            "answer",
        );
    }
}


// The variadic shapes below (issue #334 step 5) mirror `tests/ut/ffi/
// plan.d`'s own `called.variadic*` tests at the plan level - here,
// through a guest call on every backend instead of `PlanCache` directly.
// `_backend` distinguishes each native symbol's own linker name from its
// plan-level counterpart in `ut.ffi.plan`, since both are `extern(C)` and
// so share one flat, global symbol namespace in this test binary.

// Always reads exactly nine `int`s past `first` - paired with a guest
// call site that always passes exactly nine. Ten INTEGER-class words in
// total: six fill the integer register file, and the last four spill to
// the stack. Each extra is weighted by its own position (`i + 1`) before
// being added: a plain sum reads the same total back whether the extras
// arrive in order or two of them are swapped, so a plain sum cannot tell
// a correct call from a misordered one (issue #334 step 5 review finding
// 4) - `tests/ut/ffi/plan.d`'s own plan-level copy of this function has
// the same reason.
private extern(C) int snakebite_ut_variadic_sum_ints_backend(
    int first, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, first);
    int total = first;
    foreach (i; 0 .. 9)
        total += (i + 1) * va_arg!int(args);
    va_end(args);
    return total;
}


// Reads its own count of extra arguments, so two call sites can pass it
// a different number safely. Weighted by position, the same reason as
// `snakebite_ut_variadic_sum_ints_backend`.
private extern(C) int snakebite_ut_variadic_count_sum_backend(
    int count, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, count);
    int total;
    foreach (i; 0 .. count)
        total += (i + 1) * va_arg!int(args);
    va_end(args);
    return total;
}


// Always reads exactly eight `double`s past `first` - nine SSE-class
// words in total: eight fill the SSE register file (`%al` reports 8),
// and the last one spills to the stack. Weighted by position, the same
// reason as `snakebite_ut_variadic_sum_ints_backend`.
private extern(C) double snakebite_ut_variadic_sum_doubles_backend(
    double first, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, first);
    double total = first;
    foreach (i; 0 .. 8)
        total += (i + 1) * va_arg!double(args);
    va_end(args);
    return total;
}


private struct VariadicMixedPairBackend {
    int integer;
    double floating;
}


// Reads one `VariadicMixedPairBackend` - one INTEGER lane and one SSE
// lane in the same eightbyte pair - as its one extra, variadic argument.
private extern(C) long snakebite_ut_variadic_mixed_pair_backend(
    int tag, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, tag);
    auto pair = va_arg!VariadicMixedPairBackend(args);
    va_end(args);
    return tag * 1_000_000L + pair.integer * 1000 + cast(long) pair.floating;
}


private struct VariadicBig24Backend {
    long a;
    long b;
    long c;
}


// A 24-byte MEMORY-class extra - three eightbytes, past any register
// pair the classifier ever tries - followed by a plain `int` extra:
// the MEMORY extra spills to the stack whole, and the `int` after it
// spills too, since nothing about a MEMORY-class extra changes either
// register file's own count.
private extern(C) long snakebite_ut_variadic_memory_then_int_backend(
    int tag, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, tag);
    auto big = va_arg!VariadicBig24Backend(args);
    int following = va_arg!int(args);
    va_end(args);
    return tag + big.a + big.b + big.c + following;
}


private struct VariadicSixExhaustPairBackend {
    int a;
    int b;
}


private struct VariadicSixExhaustTripleBackend {
    long a;
    long b;
    long c;
}


// Six named `int`s already fill the whole integer register file before
// any extra is classified: a `double` extra still has SSE register
// room, but the pair (one INTEGER-class eightbyte), the plain `int`,
// and the MEMORY-class triple all find the integer file exhausted and
// spill to the stack, in program order alongside the double.
private extern(C) long
    snakebite_ut_variadic_six_ints_then_extras_backend(
        int n0, int n1, int n2, int n3, int n4, int n5, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, n5);
    double d = va_arg!double(args);
    auto pair = va_arg!VariadicSixExhaustPairBackend(args);
    int extraInt = va_arg!int(args);
    auto triple = va_arg!VariadicSixExhaustTripleBackend(args);
    va_end(args);
    return n0 + n1 + n2 + n3 + n4 + n5
        + cast(long) d + pair.a + pair.b + extraInt
        + triple.a + triple.b + triple.c;
}


// Zero extras through the leaner, integer-only stub entry (chosen at
// prepare time when there is no SSE argument register and no stack
// word - `CallPlan._entry`'s own doc): the declared parameter is the
// only word this call ever sends.
private extern(C) int snakebite_ut_variadic_zero_extras_int_backend(
    int a, ...
) {
    return a;
}


// Zero extras through the general stub entry: the one SSE-class
// declared argument is why the general entry is chosen, even with no
// extras at all.
private extern(C) double
    snakebite_ut_variadic_zero_extras_double_backend(double a, ...) {
    return a;
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.tenIntsFourSpillToTheStack." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // 1 (`first`, unweighted) + sum((i + 1) * (i + 2)) for i in
        // 0 .. 9, the values 2 .. 10 at positions 0 .. 8 of the weighted
        // sum `snakebite_ut_variadic_sum_ints_backend` computes.
        331.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_sum_ints_backend")
                extern(C) int nativeSum(int first, ...);

                int answer() {
                    return nativeSum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
                }
            },
            "answer",
        );
    }

    @("variadic.nineDoublesOneSpills." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Same weighted total as `ut.ffi.plan`'s own `called.variadic.
        // nineDoublesOneSpills`.
        241.0.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_sum_doubles_backend")
                extern(C) double nativeSum(double first, ...);

                double answer() {
                    return nativeSum(
                        1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
                }
            },
            "answer",
        );
    }

    // A `float` local widens to `double` before it ever reaches the
    // plan (dmd's own C default argument promotion) - `ut.ffi.plan`'s
    // own `called.variadic.floatLiteralPromotedToDouble` checks the
    // promoted `Type` directly; this checks the promoted call still
    // answers correctly through a guest call on every backend.
    @("variadic.floatLiteralPromotedToDouble." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Same weighted total: the promoted `float` carries the same
        // value, at the same position.
        241.0.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_sum_doubles_backend")
                extern(C) double nativeSum(double first, ...);

                double answer() {
                    float second = 2.0f;
                    return nativeSum(
                        1.0, second, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
                }
            },
            "answer",
        );
    }

    // One extra argument classifies to a mixed INTEGER/SSE eightbyte
    // pair (issue #334 step 4's own shape), reached through a variadic
    // call site instead of a named parameter.
    @("variadic.mixedIntegerSSEStructArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3_007_002L.shouldBeRetOf!(
            backend,
            q{
                struct VariadicMixedPair {
                    int integer;
                    double floating;
                }

                pragma(mangle, "snakebite_ut_variadic_mixed_pair_backend")
                extern(C) long nativeMixedPair(int tag, ...);

                long answer() {
                    VariadicMixedPair value;
                    value.integer = 7;
                    value.floating = 2.5;
                    return nativeMixedPair(3, value);
                }
            },
            "answer",
        );
    }

    // The same callee at two call sites in one guest function, passing a
    // different number of extra arguments - one plan per call site
    // (`ut.ffi.plan`'s own `called.variadic.
    // sameCalleeTwoCallSitesDifferentArgumentCounts` checks this at the
    // plan level; this exercises each backend's own call-site handling:
    // the interpreter's call-site plan cache, and the bytecode
    // compiler's own one-time-per-`CallExp` compilation).
    @("variadic.sameCalleeTwoCallSitesDifferentArgumentCounts."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // 41 (unweighted, one extra) + (1 * 1 + 2 * 2 + 3 * 3) (weighted,
        // three extras).
        55.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_count_sum_backend")
                extern(C) int nativeCountSum(int count, ...);

                int answer() {
                    return nativeCountSum(1, 41) + nativeCountSum(3, 1, 2, 3);
                }
            },
            "answer",
        );
    }

}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    // A 24-byte MEMORY-class extra followed by a plain `int` extra.
    @("variadic.memoryClassExtraThenInt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        643L.shouldBeRetOf!(
            backend,
            q{
                struct Big24 {
                    long a;
                    long b;
                    long c;
                }

                pragma(mangle,
                    "snakebite_ut_variadic_memory_then_int_backend")
                extern(C) long nativeMemoryThenInt(int tag, ...);

                long answer() {
                    Big24 value;
                    value.a = 100;
                    value.b = 200;
                    value.c = 300;
                    return nativeMemoryThenInt(1, value, 42);
                }
            },
            "answer",
        );
    }

    // Six named `int`s exhaust the integer register file before a
    // `double`, a pair, a plain `int`, and a MEMORY-class extra - all
    // four spill to the stack (the double for lack of extras still
    // reading from the SSE file, the other three for lack of integer
    // registers), in program order.
    @("variadic.sixIntsExhaustIntegerFileThenExtras." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        91L.shouldBeRetOf!(
            backend,
            q{
                struct SixExhaustPair {
                    int a;
                    int b;
                }

                struct SixExhaustTriple {
                    long a;
                    long b;
                    long c;
                }

                pragma(mangle,
                    "snakebite_ut_variadic_six_ints_then_extras_backend")
                extern(C) long nativeSixIntsThenExtras(
                    int n0, int n1, int n2, int n3, int n4, int n5, ...);

                long answer() {
                    SixExhaustPair pair;
                    pair.a = 8;
                    pair.b = 9;
                    SixExhaustTriple triple;
                    triple.a = 11;
                    triple.b = 12;
                    triple.c = 13;
                    return nativeSixIntsThenExtras(
                        1, 2, 3, 4, 5, 6, 7.0, pair, 10, triple);
                }
            },
            "answer",
        );
    }

    // Zero extras through the integer-only stub entry.
    @("variadic.zeroExtrasIntegerEntry." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle,
                    "snakebite_ut_variadic_zero_extras_int_backend")
                extern(C) int nativeZeroExtrasInt(int a, ...);

                int answer() {
                    return nativeZeroExtrasInt(42);
                }
            },
            "answer",
        );
    }

    // Zero extras through the general stub entry.
    @("variadic.zeroExtrasGeneralEntry." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.5.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle,
                    "snakebite_ut_variadic_zero_extras_double_backend")
                extern(C) double nativeZeroExtrasDouble(double a, ...);

                double answer() {
                    return nativeZeroExtrasDouble(3.5);
                }
            },
            "answer",
        );
    }

    // A `long` extra past a `%ld` and an `int` extra past a `%d`: a
    // value too large for 32 bits (`4_000_000_000L`) only prints back
    // correctly if the plan wrote all eight bytes of the `long`'s own
    // slot, not just the four an `int` extra would need.
    @("variadic.longVersusIntWidths." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                import core.stdc.stdio: snprintf;
                import core.stdc.string: memcmp;

                bool answer() {
                    char[32] buffer;
                    char[8] format = "%ld %d\0";
                    char[13] expected = "4000000000 7\0";
                    long bigValue = 4_000_000_000L;
                    int smallValue = 7;
                    const length = snprintf(
                        buffer.ptr, buffer.length, format.ptr,
                        bigValue, smallValue);
                    return length == 12
                        && memcmp(buffer.ptr, expected.ptr, 12) == 0;
                }
            },
            "answer",
        );
    }

    // `byte`/`short`/`float` extras all promote before they ever reach
    // the plan (dmd's own C default argument promotion): a `printf`-
    // style callee only ever reads `int`/`double` off `va_arg`, so the
    // classification this plan uses never even sees the narrower types.
    @("variadic.byteShortFloatPromotion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                import core.stdc.stdio: snprintf;
                import core.stdc.string: memcmp;

                bool answer() {
                    char[32] buffer;
                    char[9] format = "%d %d %f\0";
                    char[13] expected = "5 9 2.500000\0";
                    byte smallByte = cast(byte) 5;
                    short smallShort = cast(short) 9;
                    float smallFloat = cast(float) 2.5;
                    const length = snprintf(
                        buffer.ptr, buffer.length, format.ptr,
                        smallByte, smallShort, smallFloat);
                    return length == 12
                        && memcmp(buffer.ptr, expected.ptr, 12) == 0;
                }
            },
            "answer",
        );
    }
}


// `snprintf` into a guest buffer with `%d %s %f` and mixed integer,
// pointer and `double` arguments - the comparison runs inside the guest
// function itself and only the boolean answer crosses back, so this
// needs no dynamic-array-return support from any backend to assert the
// resulting string. `"42 hi 3.500000"` is exactly fourteen bytes, so the
// comparison reads the full output with `memcmp` against a local copy of
// the expected text, instead of slicing `buffer` (a fixed-size array) by
// `snprintf`'s own runtime-returned `length`: that slice is a rejection
// the bytecode compiler already gives for a plain slice-and-compare with
// no FFI or variadic argument involved, and even a compile-time-constant
// bound still hits it, since `compiler.d`'s own `visit(SliceExp)` falls
// through to its generic rejection for *any* bounded slice of a static
// array (issue #348) - `memcmp`, an ordinary native call, does not. A
// local array literal's own `.ptr`, not a string literal's own `.ptr`
// (`format`/`text` below show the same pattern already), since a string
// literal's `.ptr` segfaults when passed to a native call on both
// backends today, unrelated to this step.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.snprintf." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                import core.stdc.stdio: snprintf;
                import core.stdc.string: memcmp;

                bool answer() {
                    char[64] buffer;
                    char[9] format = "%d %s %f\0";
                    char[3] text = "hi\0";
                    char[15] expected = "42 hi 3.500000\0";
                    const length = snprintf(
                        buffer.ptr, buffer.length, format.ptr,
                        42, text.ptr, 3.5);
                    return length == 14
                        && memcmp(buffer.ptr, expected.ptr, 14) == 0;
                }
            },
            "answer",
        );
    }
}


// D's own untyped variadic kind (issue #334 step 6): `extern(D)`
// linkage, `...`. The frontend inserts the call's own `_arguments` - a
// `TypeInfo_Tuple` reference - as a leading argument ahead of every
// declared parameter (`dmd.mtype.TypeFunction.isDstyleVariadic`'s own
// doc; ADR-0010's D variadic paragraph). Every callee below uses
// `core.vararg` - `public import core.stdc.stdarg;` plus one `TypeInfo`-
// driven `va_arg` overload (verified in druntime's own source) - the
// same mechanism `ut.ffi.plan`'s own `called.variadic.externD.*` use
// through `core.stdc.stdarg` directly; only the mixed-type callee here
// actually needs the `TypeInfo`-driven half, to read `_arguments[i]`
// itself rather than a single, compile-time-known type. `_backend`
// distinguishes each native symbol's own linker name from its plan-level
// counterpart in `ut.ffi.plan`, since both are `extern(D)` and so share
// one flat, global symbol namespace in this test binary.

// Sums every extra argument, `int` or `double` alike, reading each
// one's real type from `_arguments[i]` rather than assuming one - the
// same `_arguments`-driven dispatch a real `extern(D)` variadic function
// needs when it cannot know its caller's argument types ahead of time.
pragma(mangle, "snakebite_ut_dvariadic_mixed_sum_backend")
private extern(D) double snakebite_ut_dvariadic_mixed_sum_backend(...) {
    import core.vararg;

    double total = 0;
    foreach (i; 0 .. _arguments.length) {
        if (_arguments[i] == typeid(int))
            total += va_arg!int(_argptr);
        else if (_arguments[i] == typeid(double))
            total += va_arg!double(_argptr);
    }
    return total;
}


// Copies its one extra argument's raw bytes into `dest`, using the
// `TypeInfo`-driven `va_arg` overload since this callee cannot know the
// argument's real type at compile time - a guest-declared struct's own
// type, in the test below - and returns that type's own `tsize`, read
// off `_arguments[0]` the same way the real `_argptr`/register-save-area
// machinery would (`object.TypeInfo_Struct.tsize`'s own druntime
// implementation returns its `m_init.length`, which `snakebite.backends.
// runtimetypes.RuntimeTypes.structInfo` already sets to the guest
// struct's own real init bytes - so this test also checks that
// fabricated `TypeInfo_Struct` is the right size, not merely present).
pragma(mangle, "snakebite_ut_dvariadic_struct_backend")
private extern(D) size_t snakebite_ut_dvariadic_struct_backend(
    ubyte* dest, ...
) {
    import core.vararg;

    auto info = _arguments[0];
    const size = info.tsize;
    va_arg(_argptr, info, dest);
    return size;
}


// Reads its one extra argument as a `string` - a two-word slice, not a
// single register - through the ordinary, compile-time-typed `va_arg`.
pragma(mangle, "snakebite_ut_dvariadic_string_backend")
private extern(D) size_t snakebite_ut_dvariadic_string_backend(...) {
    import core.vararg;

    return va_arg!string(_argptr).length;
}


// D's typesafe variadic kind (`T t...`, `VarArg.typesafe`): the frontend
// packs a call site's trailing arguments into one array-typed argument
// before any backend ever sees them, so it is a plain slice parameter,
// never refused, and needs no `_arguments` of its own.
pragma(mangle, "snakebite_ut_dvariadic_typesafe_backend")
private extern(D) int snakebite_ut_dvariadic_typesafe_backend(
    int[] a...
) {
    int total;
    foreach (value; a)
        total += value;
    return total;
}


// Guest-to-guest, no FFI at all: dmd's own typesafe variadic packing
// slices a fresh, variable-less `ArrayLiteralExp` (`[3, 4, 5]`) at the
// call site (`Evaluator.addressOf`'s own `isArrayLiteralExp` case, issue
// #334 step 6's own doc there). `helper`'s own `int[8]` local is a
// second, later reservation from the same frame stack `addressOf` used
// for that slice's own storage - a probe for a dangling address: if
// `addressOf` handed back a reservation its own RAII already popped, a
// nested call's own frame would land on those exact same, "already
// free" bytes and clobber `[3, 4, 5]` out from under `a` before
// `typesafeSum`'s `foreach` ever reads it.
static foreach (backend; Matrix!()) {
    @("variadic.typesafe.addressSurvivesNestedCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        22.shouldBeRetOf!(
            backend,
            q{
                int helper(int x) {
                    int[8] pad = [9, 9, 9, 9, 9, 9, 9, 9];
                    return x + pad[7];
                }

                int typesafeSum(int[] a...) {
                    int t = helper(1);
                    foreach (v; a)
                        t += v;
                    return t;
                }

                int answer() {
                    return typesafeSum(3, 4, 5);
                }
            },
            "answer",
        );
    }
}


private struct VariadicPointBackend {
    int x;
    int y;
}


// One declared parameter, then an `int` extra and a `struct` extra,
// checked through `_arguments` itself - `_arguments.length` and
// `_arguments[0]`'s own identity, not merely inferred from the sum this
// callee returns - alongside `mixed_sum_backend`'s split int/double sum
// and `struct_backend`'s tsize-driven copy above. This is a `static`
// struct member below (the workaround `signatures.externD.
// nineWordsTwoStringsSpill` already documents), so it can run through
// `Matrix!`/`shouldBeRetOf` like an ordinary variadic test, unlike the
// six that follow. `acceptance/at/ffi/dvariadic.d`'s own callee checks
// this exact shape again, built by ldc2 instead of dmd - the one host
// whose own `_arguments` ABI differs (`snakebite.ffi.abi.
// dVariadicArgumentsIsSlice`'s own doc).
pragma(mangle, "snakebite_ut_dvariadic_length_type_sum_backend")
private extern(D) int snakebite_ut_dvariadic_length_type_sum_backend(
    VariadicPointBackend point, ...
) {
    import core.vararg;

    assert(_arguments.length == 3, "wrong _arguments.length");
    assert(_arguments[0] is typeid(int), "wrong _arguments[0]");

    int total = point.x + point.y;
    foreach (i; 0 .. _arguments.length) {
        if (_arguments[i] is typeid(int))
            total += va_arg!int(_argptr);
        else {
            VariadicPointBackend extra;
            va_arg(_argptr, _arguments[i], &extra);
            total += extra.x + extra.y;
        }
    }
    return total;
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.lengthFirstTypeAndSums." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        21.shouldBeRetOf!(
            backend,
            q{
                struct GuestPoint {
                    int x;
                    int y;
                }

                struct Ffi {
                    static:
                    pragma(mangle,
                        "snakebite_ut_dvariadic_length_type_sum_backend")
                    extern(D) int probe(GuestPoint point, ...);
                }

                int answer() {
                    GuestPoint point;
                    point.x = 3;
                    point.y = 4;
                    GuestPoint extra;
                    extra.x = 5;
                    extra.y = 6;
                    return Ffi.probe(point, 1, 2, extra);
                }
            },
            "answer",
        );
    }
}


// A nested `extern(D)` variadic *declaration* - untyped or typesafe
// alike - is what crashes dmd's own code generator, not anything about
// `shouldBeRetOf` or this backend: `shouldBeRetOf`'s `Native` branch
// mixes a test's whole guest snippet into a nested delegate (`ut.
// backends.shouldBeRetOf`'s own `mixin(code); return mixin(call);`,
// itself inside `() { ... }()`), and a *free* `extern(D)` variadic
// prototype declared that deeply is a nested function (`dmd.func.
// FuncDeclaration.isNested` requires `LINK.d`), so it carries a hidden
// context pointer the real, module-scope-compiled callee does not
// expect (verified: a from-scratch repro, `pragma(mangle, "x") extern
// (D) int f(...);` declared inside a nested delegate and called from
// there, segfaults `dmd -run` outright; ldc2 rejects the identical file
// at compile time instead, with an IR type mismatch naming the same
// extra parameter). `signatures.externD.nineWordsTwoStringsSpill`
// above already works around the identical dmd quirk, for a
// non-variadic reversed-parameter callee, by declaring the prototype as
// a `static` struct member instead of a free function - a struct
// member's own calling convention never gains that hidden context,
// whatever its own lexical nesting depth - and the same workaround
// applies here (verified against a variadic prototype too, untyped and
// typesafe alike).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    // The same callee at two call sites in one guest function, one
    // passing seven `int`s (more than `abi.maxIntegerArguments` once
    // `_arguments` itself claims a register too, so the integer file
    // spills) and the other nine `double`s (more than `abi.
    // maxFloatingArguments`, so the SSE file spills) - `ut.ffi.plan`'s
    // own `called.variadic.externD.sevenIntsSpillTheIntegerFile` checks
    // the first shape at the plan level; this exercises the bytecode
    // compiler's own one-time-per-`CallExp` compilation on both spills
    // together, the same way `variadic.
    // sameCalleeTwoCallSitesDifferentArgumentCounts` does for the
    // `extern(C)` kind above.
    @("variadic.externD.twoCallSitesIntsAndDoublesSpill." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        73.0.shouldBeRetOf!(
            backend,
            q{
                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_dvariadic_mixed_sum_backend")
                    extern(D) double nativeSum(...);
                }

                double answer() {
                    return Ffi.nativeSum(1, 2, 3, 4, 5, 6, 7)
                        + Ffi.nativeSum(
                            1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
                }
            },
            "answer",
        );
    }
}


// A guest-declared struct as the sole extra argument: the callee reads
// its `tsize` and its raw bytes back through `_arguments[0]` alone,
// never a compile-time-known guest type - `object.TypeInfo_Struct.
// tsize`'s own druntime implementation returns its `m_init.length`,
// which `snakebite.backends.runtimetypes.RuntimeTypes.structInfo`
// already sets to the guest struct's own real init bytes, so this also
// checks that fabricated `TypeInfo_Struct` is the right size, not merely
// present.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.guestStructTsizeAndBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(8_003_004).shouldBeRetOf!(
            backend,
            q{
                struct GuestPoint {
                    int x;
                    int y;
                }

                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_dvariadic_struct_backend")
                    extern(D) size_t copyStruct(ubyte* dest, ...);
                }

                size_t answer() {
                    ubyte[16] buffer;
                    GuestPoint point;
                    point.x = 3;
                    point.y = 4;
                    const size = Ffi.copyStruct(buffer.ptr, point);
                    int* asInts = cast(int*) buffer.ptr;
                    return size * 1_000_000 + asInts[0] * 1000 + asInts[1];
                }
            },
            "answer",
        );
    }
}


// An odd-sized (3-byte) INTEGER eightbyte extra: `runtimetypes.
// eightbyteRepresentative` used to always stand in with `typeid(long)`
// (8 bytes), so `va_arg` copied 8 bytes into `dest` for a struct only 3
// bytes wide - `answer` fills the rest of its own 8-byte buffer with a
// `0xAA` sentinel first and checks it survives untouched past the one
// byte of over-copy `typeid(int)` (dmd's own `argtypes_sysv_x64` table
// for this size) still allows.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.threeByteStructExtra." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                struct ThreeBytes {
                    ubyte a;
                    ubyte b;
                    ubyte c;
                }

                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_dvariadic_struct_backend")
                    extern(D) size_t copyStruct(ubyte* dest, ...);
                }

                int answer() {
                    ubyte[8] buffer = 0xAA;
                    ThreeBytes value;
                    value.a = 1;
                    value.b = 2;
                    value.c = 4;
                    const size = Ffi.copyStruct(buffer.ptr, value);
                    if (size != 3)
                        return 0;
                    if (buffer[0] != 1 || buffer[1] != 2 || buffer[2] != 4)
                        return 0;
                    // Index 3 is the one byte `typeid(int)`'s own
                    // over-copy may still touch - only 4..8 prove no
                    // wider, `typeid(long)`-sized over-copy happened.
                    foreach (i; 4 .. 8)
                        if (buffer[i] != 0xAA)
                            return 0;
                    return 7;
                }
            },
            "answer",
        );
    }
}


// A MEMORY-class (24-byte, three-eightbyte) struct extra: `abi.classify`
// classifies anything over two eightbytes as MEMORY before this backend
// ever fabricates `m_arg1`/`m_arg2` for it (`setSysVArgTypes`'s own
// early `if (plan.memory) return;`), so druntime's own `va_arg` takes
// its "always passed in memory" path instead of reading a register-save-
// area eightbyte - the same struct extra shape `ut.ffi.plan`'s own
// `called.memoryClassParameter*` tests check for a declared parameter,
// here for a variadic extra argument instead.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.memoryClassStructExtra." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        24_000_060L.shouldBeRetOf!(
            backend,
            q{
                struct MemoryStruct {
                    long a;
                    long b;
                    long c;
                }

                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_dvariadic_struct_backend")
                    extern(D) size_t copyStruct(ubyte* dest, ...);
                }

                long answer() {
                    ubyte[24] buffer;
                    MemoryStruct value;
                    value.a = 10;
                    value.b = 20;
                    value.c = 30;
                    const size = Ffi.copyStruct(buffer.ptr, value);
                    long* asLongs = cast(long*) buffer.ptr;
                    return cast(long) size * 1_000_000
                        + asLongs[0] + asLongs[1] + asLongs[2];
                }
            },
            "answer",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.stringArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_dvariadic_string_backend")
                    extern(D) size_t stringLength(...);
                }

                size_t answer() {
                    return Ffi.stringLength("hello");
                }
            },
            "answer",
        );
    }
}


// A method (hidden `this`) that is also variadic: `this`, `_arguments`
// and the extra arguments all have to order correctly. A struct
// member's own hidden `this` is ordinary aggregate calling convention,
// not the nested-function shape the comment above documents, so
// `DVariadicMethodHost` needs no further `static` wrapping of its own -
// unlike every other callee in this file, `sum` keeps its own body
// (`shouldBeRetOf`'s `Native` branch never runs it: dispatch to native
// never asks whether a `VarArg.variadic` callee has a body, only
// whether its `TypeFunction` is variadic - `compileNativeCall`'s and
// `callVariadicNative`'s own doc), with its own, otherwise-unused
// mangled name: a bodyless prototype here left the interpreter
// mishandling a bodyless variadic method's own hidden `this` (verified:
// stack-overflow recursion, not a bad answer - a separate bug worth its
// own issue, out of this step's own scope).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.method." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(
            backend,
            q{
                import core.stdc.stdarg;

                struct DVariadicMethodHost {
                    pragma(mangle, "snakebite_ut_dvariadic_method2_backend")
                    extern(D) int sum(int first, ...) {
                        import core.vararg;

                        int total = first;
                        foreach (i; 0 .. _arguments.length)
                            if (_arguments[i] == typeid(int))
                                total += va_arg!int(_argptr);
                        return total;
                    }
                }

                int answer() {
                    DVariadicMethodHost instance;
                    return instance.sum(1, 2, 3);
                }
            },
            "answer",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("variadic.externD.typesafeSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(
            backend,
            q{
                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_ut_dvariadic_typesafe_backend")
                    extern(D) int nativeSum(int[] a...);
                }

                int answer() {
                    return Ffi.nativeSum(3, 4, 5);
                }
            },
            "answer",
        );
    }
}


// Reads one `int function(int)` past `first` and calls it with `first`.
private extern(C) int snakebite_ut_variadic_call_function_backend(
    int first, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, first);
    auto callback = va_arg!(int function(int))(args);
    va_end(args);
    return callback(first);
}


// As above, for an `int delegate(int)`.
private extern(C) int snakebite_ut_variadic_call_delegate_backend(
    int first, ...
) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, first);
    auto callback = va_arg!(int delegate(int))(args);
    va_end(args);
    return callback(first);
}


// A function pointer or delegate extra argument gets its pool entry
// (ADR-0003) at the variadic call site the same way a declared parameter
// of that shape does: the site's own extra argument types name it. The
// host reads the callback back with `va_arg` and calls it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("variadic.callbackExtraArgument.functionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_call_function_backend")
                extern(C) int nativeCall(int first, ...);

                static int twice(int x) {
                    return x * 2;
                }

                int answer() {
                    int function(int) callback = &twice;
                    return nativeCall(21, callback);
                }
            },
            "answer",
        );
    }

    @("variadic.callbackExtraArgument.delegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        45.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_call_delegate_backend")
                extern(C) int nativeCall(int first, ...);

                int answer() {
                    int offset = 3;
                    int delegate(int) callback = (int x) => x * 2 + offset;
                    return nativeCall(21, callback);
                }
            },
            "answer",
        );
    }
}


// Twenty-one argument words (one declared plus twenty extras) - more
// than `CallPlan.Frame`'s own sixteen-word inline stack area - reaches
// the heap fallback instead of any fixed-word refusal: master dropped
// the argument-count limit this step used to hit here (`CallPlan.
// _arguments`/`_moves` are dynamic arrays, `Frame`'s stack area falls
// back to the heap past its own sixteen inline words), so a call this
// wide just works, on every backend that reaches a plan.
static foreach (Backend; AliasSeq!(Interpreter, Bytecode)) {
    @("variadic.moreThanSixteenArgumentWords." ~ Backend.stringof)
    @Tags(Backend.stringof)
    unittest {
        // sum((i + 1) * (i + 1)) for i in 0 .. 20, the weighted sum
        // `snakebite_ut_variadic_count_sum_backend` computes over the
        // values 1 .. 20 at positions 0 .. 19.
        2870.shouldBeRetOf!(Backend, q{
            pragma(mangle, "snakebite_ut_variadic_count_sum_backend")
            extern(C) int nativeCountSum(int count, ...);

            int answer() {
                return nativeCountSum(
                    20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                    16, 17, 18, 19, 20);
            }
        }, "answer");
    }
}


// A variadic callee reached through a function pointer parameter, not a
// name: the interpreter resolves it dynamically (`calleeOf`), exactly as
// it would a direct call, so this reuses the same weighted-sum callee
// and expected total as `variadic.tenIntsFourSpillToTheStack` above.
// `compileIndirectCall` never opts `arityMismatches` into `allowExtra`
// the way `compileNativeCall` does for a statically resolved callee
// (`snakebite.backends.calls`'s own doc - only the two variadic-aware
// call sites opt in, and an indirect call cannot know at compile time
// whether its own runtime target will turn out to be one): a call
// through a function pointer with more arguments than the pointer
// type's own declared parameter list is refused there as an ordinary
// arity mismatch, the same as any other indirect call with too many
// arguments (issue #334 step 5 review, function-pointer scenario).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Bytecode, Because.unconfirmed,
        "compileIndirectCall's own arityMismatches check never opts "
            ~ "into allowExtra, so a call through a function pointer "
            ~ "with more arguments than the pointer type's own declared "
            ~ "parameter list is refused there as an ordinary arity "
            ~ "mismatch, not routed to a native plan"),
)) {
    @("variadic.calledThroughFunctionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        331.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_variadic_sum_ints_backend")
                extern(C) int nativeSum(int first, ...);

                alias VariadicFp = extern(C) int function(int, ...);

                int callThrough(VariadicFp fp) {
                    return fp(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
                }

                int answer() {
                    return callThrough(&nativeSum);
                }
            },
            "answer",
        );
    }
}


// `RuntimeTypes.get`'s own top-level cache (keyed by `Type` identity) is
// generic - it already covers the `TypeTuple`/qualified-wrapper branches
// `build` below fabricates for an `extern(D)` untyped variadic call
// site's own hidden `_arguments`, not only a struct's own `TypeInfo`
// (`RuntimeTypes.get`'s own doc): dmd's frontend builds one `TypeTuple`
// per call site, the same `Type` object on every execution of that
// site, so `get` only ever allocates a fresh `TypeInfo_Tuple` (and, for
// a `string` extra here, a fresh qualified element wrapper) on the
// first call. `Bytecode` never reaches `RuntimeTypes.get` for this at
// all - `variadicOf` folds `_arguments` into a compile-time constant
// once, when the call site itself compiles.
@("variadic.externD.noAllocationOnRepeatedCall.Interpreter")
@Tags("Interpreter")
unittest {
    import core.memory: GC;
    import snakebite.backends.backend: Program;
    import snakebite.backends.interpreter: Interpreter;

    auto module_ = parseSnippet(q{
        pragma(mangle, "snakebite_ut_dvariadic_string_backend")
        extern(D) size_t stringLength(...);

        size_t answer() {
            return stringLength("hello");
        }
    });
    auto function_ = findFunction(module_, "answer");
    assert(function_ !is null, "No `answer` in the guest program");

    auto interpreter_ = new Interpreter(Program([module_]));
    size_t result;
    // Warms the plan cache (`PlanCache.of`) and the type cache
    // (`RuntimeTypes.get`) alike - only the steady state after this is
    // the claim under test.
    interpreter_.call(function_, &result, []);

    const before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. 100)
        interpreter_.call(function_, &result, []);
    const after = GC.allocatedInCurrentThread;

    after.should == before;
}


@("variadic.externD.noAllocationOnRepeatedCall.Bytecode")
@Tags("Bytecode")
unittest {
    import core.memory: GC;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode: Bytecode;

    auto module_ = parseSnippet(q{
        pragma(mangle, "snakebite_ut_dvariadic_string_backend")
        extern(D) size_t stringLength(...);

        size_t answer() {
            return stringLength("hello");
        }
    });
    auto function_ = findFunction(module_, "answer");
    assert(function_ !is null, "No `answer` in the guest program");

    auto bytecode = new Bytecode(Program([module_]));
    size_t result;
    bytecode.call(function_, &result, []);

    const before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. 100)
        bytecode.call(function_, &result, []);
    const after = GC.allocatedInCurrentThread;

    after.should == before;
}


// A root-owned `extern(D)` untyped variadic function *with a body*
// (`guestLen`, ADR-0009's own "interpreted" criteria) - not the
// prototype-only shape every other variadic test in this file uses.
// Native (real compiled D) runs it directly, no `pragma(mangle)` or
// static-struct workaround needed: `guestLen` and its caller `answer`
// are both nested together inside `shouldBeRetOf`'s own delegate, so
// unlike `signatures.externD.nineWordsTwoStringsSpill`'s own workaround
// (a *free* `extern(D)` declaration crossing an ABI boundary a
// *separately compiled*, non-nested definition expects), there is no
// mismatched convention here to trip over - both sides agree, whatever
// dmd's own nested-function calling convention happens to be.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's own CTFE interpreter refuses a variadic function's " ~
        "body outright (\"C-style variadic functions are not yet " ~
        "implemented in CTFE\"), independent of this backend"),
)) {
    @("variadic.externD.guestBodied." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        102.shouldBeRetOf!(
            backend,
            q{
                import core.stdc.stdarg;

                int guestLen(int a, ...) {
                    return a * 100 + cast(int) _arguments.length;
                }

                int answer() {
                    return guestLen(1, 2, 3);
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot execute C-style variadic function bodies"),
)) {
    @("variadic.externD.guestReadsValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdarg;
            struct Mixed { double fraction; long whole; }
            struct Large { long[4] values; }
            struct Extended { real value; }
            void check(int first, ...) {
                assert(first == 7);
                assert(_arguments.length == 6);
                assert(_arguments[0] is typeid(int));
                assert(va_arg!int(_argptr) == 42);
                assert(va_arg!double(_argptr) == 2.5);
                assert(va_arg!string(_argptr) == "hello");
                auto mixed = va_arg!Mixed(_argptr);
                assert(mixed.fraction == 3.5 && mixed.whole == 9);
                auto large = va_arg!Large(_argptr);
                assert(large.values == [1, 2, 3, 4]);
                assert(va_arg!Extended(_argptr).value == 1.25L);
            }
            void main() {
                check(7, 42, 2.5, "hello", Mixed(3.5, 9),
                    Large([1, 2, 3, 4]), Extended(1.25L));
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot execute C-style variadic function bodies"),
)) {
    @("variadic.externD.guestIndirectAndRecursive." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdarg;
            int sum(int depth, ...) {
                if (!depth)
                    return cast(int) _arguments.length;
                auto value = va_arg!int(_argptr);
                auto next = sum(depth - 1, value + 1);
                return value + next;
            }
            struct Reader {
                int base;
                int read(int first, ...) {
                    return base + first + va_arg!int(_argptr);
                }
            }
            void main() {
                auto fp = &sum;
                assert(fp(3, 10) == 34);
                assert(fp(0) == 0);
                Reader reader = Reader(30);
                auto dg = &reader.read;
                assert(dg(5, 7) == 42);
            }
        });
    }
}
