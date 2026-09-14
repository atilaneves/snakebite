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
