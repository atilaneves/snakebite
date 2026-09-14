module ut.ffi.plan;


import ut;
import dmd.func: FuncDeclaration;
import snakebite.ffi: CallAdapter, PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction, findStruct;
import std.array: replace;


// `abs` declared the way druntime declares it: `extern(C)`, and with no
// body, so nothing but the already-loaded symbol can satisfy a call to it.
private enum declarations = q{
    extern(C) int abs(int);
    extern(C) void free(void*);
};


@("druntime.sharedCtorAtomicPlan")
unittest {
    PlanCache cache;
    const plan = cache.of(atomicOperation!(int));
    shared int value = 41;
    int amount = 1;
    int result;
    void* valueAddress = cast(void*) &value;
    const(void*)[2] arguments = [
        cast(const void*) &valueAddress,
        cast(const void*) &amount,
    ];

    plan.call(&result, arguments[]);

    result.should == 42;
    value.should == 42;
}


private FuncDeclaration atomicOperation(T)() {
    auto guestModule = parseSnippet(q{
        import core.atomic: atomicOp;

        T increment(ref shared T value) {
            return atomicOp!"+="(value, 1);
        }
    }.replace("T", T.stringof));
    auto increment = findFunction(guestModule, "increment");
    assert(increment !is null, "No function `increment` in the guest program");

    auto statements = increment.fbody.isCompoundStatement.statements;
    assert(statements !is null && statements.length == 1,
        "Expected one statement in `increment`");
    auto return_ = (*statements)[0].isReturnStatement;
    assert(return_ !is null, "Expected `increment` to return the atomic call");
    auto call = return_.exp.isCallExp;
    assert(call !is null && call.f !is null,
        "Expected a resolved `atomicOp` call");
    return call.f;
}


@("prepared.once")
unittest {
    auto guestModule = parseSnippet(declarations);
    auto function_ = findFunction(guestModule, "abs");
    assert(function_ !is null, "No function `abs` in the guest program");

    PlanCache cache;
    foreach (i; 0 .. 100)
        cache.of(function_);

    // The count, not the plan's address: an associative array slot keeps
    // its address when its value is overwritten, so a cache that prepared
    // a fresh plan every time would still hand back the same address.
    // Preparing is what mangles the symbol, asks the dynamic linker for
    // its address and classifies the signature, so this is what the
    // barrier exists to do once.
    cache.preparations.should == 1;
}


@("prepared.perFunction")
unittest {
    auto guestModule = parseSnippet(declarations);
    auto abs_ = findFunction(guestModule, "abs");
    auto free_ = findFunction(guestModule, "free");
    assert(abs_ !is null && free_ !is null,
        "No `abs`/`free` in the guest program");

    PlanCache cache;
    foreach (i; 0 .. 10) {
        cache.of(abs_);
        cache.of(free_);
    }

    // Two functions are two plans - a cache that shared one between them
    // would call one function through the other's address - and still only
    // one preparation each.
    cache.preparations.should == 2;
}


// The native side of the `ref` tests below: compiled functions in this
// very test binary, reachable through the dynamic linker because the
// binary exports its own symbols.
private extern(C) void snakebite_ut_bump(ref int x) {
    x += 3;
}

private __gshared int _cell = 1234;

private extern(C) ref int snakebite_ut_cell() {
    return _cell;
}

private struct ThreeWords {
    size_t first;
    size_t second;
    size_t third;
}

private struct Pair {
    int first;
    int second;
}

private struct FloatingPair {
    double first;
    double second;
}

private struct MixedPair {
    int integer;
    double floating;
}

private extern(C) ThreeWords snakebite_ut_three_words() {
    return ThreeWords(17, 31, 47);
}

private extern(C) size_t snakebite_ut_memory_param(ThreeWords value) {
    return value.first * 100 + value.second * 10 + value.third;
}

private extern(C) Pair snakebite_ut_pair(Pair value) {
    return Pair(value.first + 1, value.second + 2);
}

private extern(C) FloatingPair snakebite_ut_floating_pair(
    FloatingPair value,
) {
    return FloatingPair(value.first * 2, value.second * 3);
}

private extern(C) MixedPair snakebite_ut_mixed_pair(MixedPair value) {
    return MixedPair(value.integer + 4, value.floating * 5);
}

private extern(C) MixedPair snakebite_ut_mixed_after_six(
    int a, int b, int c, int d, int e, int f, MixedPair value,
) {
    return MixedPair(
        a + b + c + d + e + f + value.integer,
        value.floating * 5,
    );
}

private extern(C) MixedPair snakebite_ut_mixed_after_eight(
    double a, double b, double c, double d,
    double e, double f, double g, double h,
    MixedPair value,
) {
    return MixedPair(
        cast(int) (a + b + c + d + e + f + g + h) + value.integer,
        value.floating * 5,
    );
}

// Six `long`s fill the integer register file and eight `double`s fill the
// SSE register file - `value`'s INTEGER lane has no integer register left
// and its SSE lane has no SSE register left, the shape the old code threw
// on (issue #334 step 4). Per the psABI's classification step 5c, when
// either file has no register left for one of `value`'s eightbytes, the
// whole argument goes to the stack, both eightbytes together, and no
// register is consumed from either file.
private extern(C) long snakebite_ut_mixed_both_files_full(
    long i0, long i1, long i2, long i3, long i4, long i5,
    double d0, double d1, double d2, double d3, double d4, double d5,
    double d6, double d7,
    MixedPair value,
) {
    return i0 + i1 + i2 + i3 + i4 + i5
        + cast(long) (d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7)
        + value.integer * 1000 + cast(long) value.floating;
}

private long _mixedScalarSpillIntegerSeen;
private double _mixedScalarSpillFloatingSeen;
private long _mixedScalarSpillTrailingSeen;

// Six `long`s fill the integer register file; `value` - a mixed
// INTEGER/SSE pair whose SSE lane still has room but whose INTEGER lane
// does not - spills whole, and `j`, declared after it, spills too for
// lack of any integer register left. dmd's reversed `extern(D)`
// convention (`_reversedArguments`'s own doc) places every spilled
// argument on the stack in descending declaration order, `value` before
// `j` in program order but after it on the reversed stack, exercising
// that reversal for a mixed aggregate, not just plain scalars.
pragma(mangle, "snakebite_ut_extern_d_mixed_scalar_spill")
private extern(D) void snakebite_ut_externDMixedScalarSpill(
    long i0, long i1, long i2, long i3, long i4, long i5,
    MixedPair value, long j,
) {
    _mixedScalarSpillIntegerSeen = i0;
    _mixedScalarSpillFloatingSeen = value.floating;
    _mixedScalarSpillTrailingSeen = j;
}

private struct MixedPairReversed {
    double floating;
    int integer;
}

// `floating` (SSE) comes first and `integer` (INTEGER) second - the
// opposite field order from `MixedPair` above. When this spills, the
// stack copy must keep that same eightbyte order: `classify` assigns
// `plan.registers[0]` to the SSE lane and `plan.registers[1]` to the
// INTEGER lane, and `buildMoves`'s spilled pass walks `registers` in
// that order, so the stack layout must match the struct's own layout,
// not `MixedPair`'s.
private extern(C) long snakebite_ut_mixed_reversed_after_six(
    int a, int b, int c, int d, int e, int f, MixedPairReversed value,
) {
    return a + b + c + d + e + f
        + cast(long) value.floating * 100 + value.integer;
}

private extern(C) double snakebite_ut_scale(double value) {
    return value * 2.5;
}

private extern(C) int snakebite_ut_seven(
    int a, int b, int c, int d, int e, int f, int g,
) {
    return a + b + c + d + e + f + g;
}

private struct TwoWords {
    size_t first;
    size_t second;
}

// Five plain `int` parameters leave one integer register free - not
// enough for `value`'s own two eightbytes. The SysV ABI never splits a
// multi-eightbyte argument across the register/stack boundary: `value`
// must travel entirely on the stack, leaving that one leftover register
// unused, rather than half in it and half on the stack.
private extern(C) TwoWords snakebite_ut_split_after_five(
    int a, int b, int c, int d, int e, TwoWords value,
) {
    return TwoWords(value.first + a + b + c + d + e, value.second);
}


@("called.refParameter")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) void snakebite_ut_bump(ref int x);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_bump");
    assert(function_ !is null, "No `snakebite_ut_bump` in the program");

    PlanCache cache;

    // A `ref` parameter travels as the address of the argument's own
    // storage, and the caller's slot for it already holds that address -
    // so a callee writing through the reference must change this very
    // variable.
    int value = 39;
    const int* slot = &value;
    cache.of(function_).call(null, [cast(const void*) &slot]);

    value.should == 42;
}


@("called.refReturn")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) ref int snakebite_ut_cell();
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_cell");
    assert(function_ !is null, "No `snakebite_ut_cell` in the program");

    PlanCache cache;

    // A `ref` return hands back the address of the result in the return
    // register, so what lands in the caller's return place is a pointer
    // to the callee's own variable, whatever that variable holds.
    int* address;
    cache.of(function_).call(&address, []);

    (*address).should == 1234;
}


@("called.refResult")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) ref int snakebite_ut_cell();
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_cell");
    assert(function_ !is null, "No `snakebite_ut_cell` in the program");

    PlanCache cache;
    void invoke(
        scope void* returnPlace,
        scope const(void*)[] arguments,
    ) {
        cache.of(function_).call(returnPlace, arguments);
    }

    int value;
    auto result = CallAdapter.of(function_).invoke(
        &value, [], &invoke,
    );

    value.should == 1234;
    result.address.should == cast(void*) &_cell;
}


@("called.hiddenPointerReturn")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        extern(C) ThreeWords snakebite_ut_three_words();
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_three_words");
    assert(function_ !is null,
        "No `snakebite_ut_three_words` in the program");

    PlanCache cache;
    ThreeWords result;
    cache.of(function_).call(&result, []);

    result.should == ThreeWords(17, 31, 47);
}


@("called.double")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) double snakebite_ut_scale(double value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_scale");
    assert(function_ !is null, "No `snakebite_ut_scale` in the program");

    PlanCache cache;
    double value = 1.5;
    double result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 3.75;
}


private extern(C) float snakebite_ut_scale_float(float value) {
    return value * 2.5f;
}


// A scalar `float` argument classifies as `Register(sse, 4)` - `loadOf`
// maps that to `Load.zero32` (a plain zero-extending load) rather than
// `Load.copy` (a `memcpy`), so this exercises the fast path directly, not
// just `Load.copy`'s generic one.
@("called.scalarFloat")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) float snakebite_ut_scale_float(float value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_scale_float");
    assert(function_ !is null,
        "No `snakebite_ut_scale_float` in the guest program");

    PlanCache cache;
    float value = 2.0f;
    float result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 5.0f;
}


@("called.smallStruct")
unittest {
    auto guestModule = parseSnippet(q{
        struct Pair {
            int first;
            int second;
        }

        extern(C) Pair snakebite_ut_pair(Pair value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_pair");
    assert(function_ !is null, "No `snakebite_ut_pair` in the program");

    PlanCache cache;
    Pair value = Pair(39, 58);
    Pair result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == Pair(40, 60);
}


@("called.smallFloatingStruct")
unittest {
    auto guestModule = parseSnippet(q{
        struct FloatingPair {
            double first;
            double second;
        }

        extern(C) FloatingPair snakebite_ut_floating_pair(
            FloatingPair value,
        );
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_floating_pair");
    assert(function_ !is null,
        "No `snakebite_ut_floating_pair` in the guest program");

    PlanCache cache;
    FloatingPair value = FloatingPair(1.25, 2.5);
    FloatingPair result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == FloatingPair(2.5, 7.5);
}


@("called.mixedSmallStruct")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) MixedPair snakebite_ut_mixed_pair(MixedPair value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_mixed_pair");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_pair` in the guest program");

    PlanCache cache;
    MixedPair value = MixedPair(39, 1.5);
    MixedPair result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == MixedPair(43, 7.5);
}


@("called.mixedStructOnStack")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) MixedPair snakebite_ut_mixed_after_six(
            int a, int b, int c, int d, int e, int f, MixedPair value,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_after_six");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_after_six` in the program");

    PlanCache cache;
    int[6] integers = [1, 2, 3, 4, 5, 6];
    MixedPair value = MixedPair(7, 1.5);
    MixedPair result;
    cache.of(function_).call(&result, [
        cast(const void*) &integers[0], cast(const void*) &integers[1],
        cast(const void*) &integers[2], cast(const void*) &integers[3],
        cast(const void*) &integers[4], cast(const void*) &integers[5],
        cast(const void*) &value,
    ]);

    result.should == MixedPair(28, 7.5);
}


@("called.mixedStructAfterSSE")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) MixedPair snakebite_ut_mixed_after_eight(
            double a, double b, double c, double d,
            double e, double f, double g, double h,
            MixedPair value,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_after_eight");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_after_eight` in the program");

    PlanCache cache;
    double[8] floating = [1, 1, 1, 1, 1, 1, 1, 1];
    MixedPair value = MixedPair(7, 1.5);
    MixedPair result;
    cache.of(function_).call(&result, [
        cast(const void*) &floating[0], cast(const void*) &floating[1],
        cast(const void*) &floating[2], cast(const void*) &floating[3],
        cast(const void*) &floating[4], cast(const void*) &floating[5],
        cast(const void*) &floating[6], cast(const void*) &floating[7],
        cast(const void*) &value,
    ]);

    result.should == MixedPair(15, 7.5);
}


@("called.stackArgument")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) int snakebite_ut_seven(
            int a, int b, int c, int d, int e, int f, int g,
        );
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_seven");
    assert(function_ !is null,
        "No `snakebite_ut_seven` in the guest program");

    PlanCache cache;
    int[7] values = [1, 2, 3, 4, 5, 6, 7];
    int result;
    cache.of(function_).call(&result, [
        cast(const void*) &values[0], cast(const void*) &values[1],
        cast(const void*) &values[2], cast(const void*) &values[3],
        cast(const void*) &values[4], cast(const void*) &values[5],
        cast(const void*) &values[6],
    ]);

    result.should == 28;
}


// Regression for the guest exception's `msg` reading garbage when a
// native constructor's arguments needed more than six integer ABI words
// (issue #272): five plain `int`s leave one integer register free, one
// short of `value`'s own two - so `value` must travel entirely on the
// stack. A caller that instead let `value`'s first eightbyte claim that
// one leftover register, spilling only the second, hands the callee a
// length/pointer pair built from two unrelated words.
@("called.splitEightbyteSpillsWhole")
unittest {
    auto guestModule = parseSnippet(q{
        struct TwoWords {
            size_t first;
            size_t second;
        }

        extern(C) TwoWords snakebite_ut_split_after_five(
            int a, int b, int c, int d, int e, TwoWords value,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_split_after_five");
    assert(function_ !is null,
        "No `snakebite_ut_split_after_five` in the guest program");

    PlanCache cache;
    int a = 1;
    int b = 2;
    int c = 3;
    int d = 4;
    int e = 5;
    TwoWords value = TwoWords(100, 200);
    TwoWords result;
    cache.of(function_).call(&result, [
        cast(const void*) &a, cast(const void*) &b, cast(const void*) &c,
        cast(const void*) &d, cast(const void*) &e,
        cast(const void*) &value,
    ]);

    result.should == TwoWords(115, 200);
}


// dmd compiles `extern(D)` on x86-64 as the C convention applied to the
// fully reversed parameter list, stack words included (see
// `_reversedArguments`'s own doc) - not merely reversed register
// assignment with declaration-order stack words. `bin/ut` is itself built
// with dmd (reggaefile.d), so a real `extern(D)` function defined in this
// module is compiled with that reversed convention, and calling it
// through a plan exercises the real ABI, not a simulated one.
// `pragma(mangle)` pins a C-style linker name on an otherwise ordinary
// `extern(D)` function so the guest declaration below and this native
// definition agree on a symbol without depending on dmd's own name
// mangling of a `parseSnippet`-parsed module.
pragma(mangle, "snakebite_ut_extern_d_eight_longs")
private extern(D) long snakebite_ut_eightLongs(
    long a, long b, long c, long d, long e, long f, long g, long h,
) {
    return a * 10_000_000 + b * 1_000_000 + c * 100_000 + d * 10_000
        + e * 1_000 + f * 100 + g * 10 + h;
}


// Six of the eight `long`s fill the integer register file; the other two
// (`a`, `b` - the first two declared, since dmd assigns registers in
// reversed declaration order) spill to the stack. A plan that spilled
// them in ascending parameter index, as `master` did, hands the callee
// `a`'s bits where it expects `b`'s and vice versa.
@("called.externD.eightLongsTwoSpill")
unittest {
    auto guestModule = parseSnippet(q{
        pragma(mangle, "snakebite_ut_extern_d_eight_longs")
        extern(D) long snakebite_ut_eightLongs(
            long a, long b, long c, long d, long e, long f, long g, long h,
        );
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_eightLongs");
    assert(function_ !is null,
        "No `snakebite_ut_eightLongs` in the guest program");

    PlanCache cache;
    long a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8;
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &a, cast(const void*) &b, cast(const void*) &c,
        cast(const void*) &d, cast(const void*) &e, cast(const void*) &f,
        cast(const void*) &g, cast(const void*) &h,
    ]);

    result.should == 12_345_678;
}


private long _mixedSpillLongSeen;
private double _mixedSpillDoubleSeen;


pragma(mangle, "snakebite_ut_extern_d_mixed_spill")
private extern(D) void snakebite_ut_mixedSpill(
    long i0, long i1, long i2, long i3, long i4, long i5, long i6,
    double d0, double d1, double d2, double d3, double d4, double d5,
    double d6, double d7, double d8,
) {
    _mixedSpillLongSeen = i0;
    _mixedSpillDoubleSeen = d0;
}


// Seven `long`s fill six integer registers and spill the seventh (`i0`,
// the first declared); nine `double`s fill eight SSE registers and spill
// the ninth (`d0`, the first declared) - one spilled eightbyte from each
// register file, landing next to each other on the stack in descending
// declaration order (`d0` at word 0, `i0` at word 1) regardless of which
// register file each came from.
@("called.externD.mixedSpillsOneLongOneDouble")
unittest {
    auto guestModule = parseSnippet(q{
        pragma(mangle, "snakebite_ut_extern_d_mixed_spill")
        extern(D) void snakebite_ut_mixedSpill(
            long i0, long i1, long i2, long i3, long i4, long i5, long i6,
            double d0, double d1, double d2, double d3, double d4,
            double d5, double d6, double d7, double d8,
        );
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_mixedSpill");
    assert(function_ !is null,
        "No `snakebite_ut_mixedSpill` in the guest program");

    PlanCache cache;
    long[7] integers = [10, 20, 30, 40, 50, 60, 70];
    double[9] floatings = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5];
    void*[16] arguments;
    foreach (i, ref value; integers)
        arguments[i] = &value;
    foreach (i, ref value; floatings)
        arguments[7 + i] = &value;

    cache.of(function_).call(null, arguments[]);

    _mixedSpillLongSeen.should == 10;
    _mixedSpillDoubleSeen.should == 1.5;
}


// A parameter whose ABI class is MEMORY (more than two eightbytes, or an
// unaligned aggregate the ABI classifies as MEMORY regardless of size)
// travels entirely on the stack, in declaration position, as whole
// eightbytes (issue #334 step 3) - `ThreeWords` is exactly the 24-byte,
// three-`size_t` shape `called.hiddenPointerReturn` above already uses for
// a MEMORY-class *return*; this is the same shape as an explicit
// *parameter*, the case `abi.ArgumentPlan.of` used to refuse outright.
// `snakebite_ut_memory_param` weights each field differently - a plain
// sum would return the same answer for any permutation of `value`'s own
// three eightbytes, so it could not catch a wrong move order.
@("called.memoryClassParameter")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        extern(C) size_t snakebite_ut_memory_param(ThreeWords value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_memory_param");
    assert(function_ !is null,
        "No `snakebite_ut_memory_param` in the guest program");

    PlanCache cache;
    ThreeWords value = ThreeWords(17, 31, 47);
    size_t result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 2_057;
}


private extern(C) double snakebite_ut_double_of_long(long value) {
    return cast(double) value * 1.5;
}


// `long -> double`: the plan's argument is INTEGER class (so it still
// picks the integer-only stub entry - see `_entry`'s own doc), but its
// *result* is SSE class. Only the raw-stub test
// `ut.ffi.sysv`'s `integerEntry.doubleReturn.xmm0` covered this shape
// before; this is the same shape one level up, through a plan.
@("called.doubleOfLong")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) double snakebite_ut_double_of_long(long value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_double_of_long");
    assert(function_ !is null,
        "No `snakebite_ut_double_of_long` in the guest program");

    PlanCache cache;
    long value = 6;
    double result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 9.0;
}


private struct ContextHiddenPointer {
    pragma(mangle, "snakebite_ut_context_hidden_pointer")
    ThreeWords getThreeWords() {
        return ThreeWords(17, 31, 47);
    }
}


// A method returning a MEMORY-class struct: the hidden context (`this`)
// and the hidden return pointer travel together, in whichever order
// `abi.contextPrecedesHiddenReturnPointer` says this host compiler uses
// (dmd puts `this` first). No existing test named both hidden arguments
// together - `called.refResult`/`called.refReturn` cover a hidden
// context alone (through `CallAdapter`, not a plan directly) and
// `called.hiddenPointerReturn` covers a hidden return pointer alone,
// but not the two combined.
@("called.contextPrecedesHiddenReturnPointer")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        struct ContextHiddenPointer {
            // A body, never walked - `PlanCache.of` builds a plan from
            // this declaration's dmd facts alone (its parameter/return
            // types and its `vthis`) and resolves the call by mangled
            // symbol name; it never inspects `fbody`. dmd's own
            // semantic3 pass only populates `vthis` for a function that
            // has a body (or a `requires`/`ensure` contract) - see
            // `hasHiddenThis`'s own doc - so a body-less prototype here,
            // unlike a free function such as `abs`, would never read as
            // having a hidden `this` at all.
            pragma(mangle, "snakebite_ut_context_hidden_pointer")
            extern(D) ThreeWords getThreeWords() { assert(0); }
        }
    });
    auto struct_ = findStruct(guestModule, "ContextHiddenPointer");
    assert(struct_ !is null,
        "No struct `ContextHiddenPointer` in the guest program");
    auto function_ = findFunction(struct_, "getThreeWords");
    assert(function_ !is null,
        "No `getThreeWords` method in the guest program");

    PlanCache cache;
    ContextHiddenPointer instance;
    ContextHiddenPointer* receiver = &instance;
    ThreeWords result;
    cache.of(function_).call(&result, [cast(const void*) &receiver]);

    result.should == ThreeWords(17, 31, 47);
}


private struct FourWords {
    size_t first;
    size_t second;
    size_t third;
    size_t fourth;
}


private extern(C) size_t snakebite_ut_memory_after_six(
    int a, int b, int c, int d, int e, int f, FourWords value, int g,
) {
    return a + b + c + d + e + f + value.first * 10_000
        + value.second * 1_000 + value.third * 100 + value.fourth * 10 + g;
}


// A 32-byte MEMORY-class argument declared after six plain `int`s, which
// already fill the integer register file, with one more `int` declared
// after it. `value` always spills - a MEMORY-class value never reaches a
// register (`abi.ArgumentPlan`'s own doc) - and `g` spills too, since no
// integer register is left for it either; both land on the stack in
// declaration order, `value`'s four eightbytes first and then `g`, the
// same order a native `extern(C)` call would use. `g`'s weight (`1`)
// differs from `value.fourth`'s (`10`), the word next to it on the
// stack, so a plan that puts `g` where `value.fourth` belongs (or the
// reverse) changes the answer instead of leaving the sum unchanged.
@("called.memoryClassParameter.afterSixIntegersThenOneMore")
unittest {
    auto guestModule = parseSnippet(q{
        struct FourWords {
            size_t first;
            size_t second;
            size_t third;
            size_t fourth;
        }

        extern(C) size_t snakebite_ut_memory_after_six(
            int a, int b, int c, int d, int e, int f, FourWords value,
            int g,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_memory_after_six");
    assert(function_ !is null,
        "No `snakebite_ut_memory_after_six` in the guest program");

    PlanCache cache;
    int[6] integers = [1, 2, 3, 4, 5, 6];
    FourWords value = FourWords(10, 20, 30, 40);
    int g = 7;
    size_t result;
    cache.of(function_).call(&result, [
        cast(const void*) &integers[0], cast(const void*) &integers[1],
        cast(const void*) &integers[2], cast(const void*) &integers[3],
        cast(const void*) &integers[4], cast(const void*) &integers[5],
        cast(const void*) &value, cast(const void*) &g,
    ]);

    result.should == 123_428;
}


private struct PackedPair {
    int a;
    align(1) long b;
}


private extern(C) long snakebite_ut_packed_pair(PackedPair value) {
    return value.a + value.b;
}


// `b`'s `align(1)` forces it to sit at offset 4, not the 8-byte boundary
// its own type (`long`) needs - the SysV ABI classifies an aggregate with
// an unaligned field as MEMORY regardless of its size
// (`abi.classify`'s own doc), so this 12-byte struct, under the 16-byte
// threshold that alone would trigger MEMORY, still does.
@("called.memoryClassParameter.unalignedField")
unittest {
    auto guestModule = parseSnippet(q{
        struct PackedPair {
            int a;
            align(1) long b;
        }

        extern(C) long snakebite_ut_packed_pair(PackedPair value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_packed_pair");
    assert(function_ !is null,
        "No `snakebite_ut_packed_pair` in the guest program");

    PlanCache cache;
    PackedPair value = PackedPair(3, 39);
    long result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 42;
}


private long _memoryTwoSpillA0;
private long _memoryTwoSpillA1;
private long _memoryTwoSpillB0;
private long _memoryTwoSpillB1;
private ThreeWords _memoryTwoSpillValue;


pragma(mangle, "snakebite_ut_extern_d_memory_two_spill")
private extern(D) void snakebite_ut_memoryTwoSpill(
    long a0, long a1, long a2, long a3, long a4, long a5,
    ThreeWords value, long b0, long b1,
) {
    _memoryTwoSpillA0 = a0;
    _memoryTwoSpillA1 = a1;
    _memoryTwoSpillB0 = b0;
    _memoryTwoSpillB1 = b1;
    _memoryTwoSpillValue = value;
}


// `value` - a MEMORY-class argument - never reaches an integer register,
// whatever room is left (`abi.ArgumentPlan`'s own doc), so dmd's reversed
// `extern(D)` convention (`_reversedArguments`'s own doc) assigns the six
// integer registers to the eight scalars alone, in reversed declaration
// order: `b1`, `b0`, `a5`, `a4`, `a3`, `a2` take them, leaving `a1` and
// `a0` - the last two reached - with no register free. `b0` does not
// spill on dmd; only `a1` and `a0` do. Spilled arguments land on the
// stack in descending declaration order, so the stack is `value`, `a1`,
// `a0` - not merely declaration order among the scalars, and not the
// order `spilled[]` first collects them in.
@("called.externD.memoryClassParameterTwoScalarSpills")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        pragma(mangle, "snakebite_ut_extern_d_memory_two_spill")
        extern(D) void snakebite_ut_memoryTwoSpill(
            long a0, long a1, long a2, long a3, long a4, long a5,
            ThreeWords value, long b0, long b1,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_memoryTwoSpill");
    assert(function_ !is null,
        "No `snakebite_ut_memoryTwoSpill` in the guest program");

    PlanCache cache;
    long a0 = 1, a1 = 2, a2 = 3, a3 = 4, a4 = 5, a5 = 6;
    ThreeWords value = ThreeWords(70, 80, 90);
    long b0 = 100, b1 = 200;
    cache.of(function_).call(null, [
        cast(const void*) &a0, cast(const void*) &a1,
        cast(const void*) &a2, cast(const void*) &a3,
        cast(const void*) &a4, cast(const void*) &a5,
        cast(const void*) &value,
        cast(const void*) &b0, cast(const void*) &b1,
    ]);

    _memoryTwoSpillA0.should == 1;
    _memoryTwoSpillA1.should == 2;
    _memoryTwoSpillB0.should == 100;
    _memoryTwoSpillB1.should == 200;
    _memoryTwoSpillValue.should == ThreeWords(70, 80, 90);
}


private extern(C) double snakebite_ut_memory_with_sse(
    double x, double y, ThreeWords value,
) {
    return x + y + value.first * 100 + value.second * 10 + value.third;
}


// A MEMORY-class argument declared after two `double`s, which stay in
// `%xmm0`/`%xmm1` - room in the SSE register file does not change
// `value`'s own class, and its always-on-stack placement must not
// disturb the SSE arguments' own register assignment. This also picks
// the general stub entry, not the integer-only one
// (`CallPlan._entry`'s own doc), since `value` fills a stack word.
// `value`'s three fields carry different weights, the way
// `snakebite_ut_eightLongs` above does, so a permuted eightbyte order
// changes the answer.
@("called.memoryClassParameter.withSSEArguments")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        extern(C) double snakebite_ut_memory_with_sse(
            double x, double y, ThreeWords value,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_memory_with_sse");
    assert(function_ !is null,
        "No `snakebite_ut_memory_with_sse` in the guest program");

    PlanCache cache;
    double x = 1.5;
    double y = 2.5;
    ThreeWords value = ThreeWords(10, 20, 30);
    double result;
    cache.of(function_).call(&result, [
        cast(const void*) &x, cast(const void*) &y,
        cast(const void*) &value,
    ]);

    result.should == 1_234.0;
}


private struct TwentyBytes {
    int a;
    int b;
    int c;
    int d;
    int e;
}


private extern(C) int snakebite_ut_twenty_bytes(TwentyBytes value) {
    return value.a * 10_000 + value.b * 1_000 + value.c * 100
        + value.d * 10 + value.e;
}


// Five plain `int` fields: 20 bytes, whose last eightbyte (`value`'s
// bytes 16-19, field `e` alone) is only half full. The move for that
// eightbyte must copy only those 4 remaining bytes, never reading past
// `value`'s own 20 bytes of storage. A guest call cannot observe a
// 4-byte over-read by its result alone - the extra bytes are stack
// padding the callee never looks at - so `value` is placed instead in
// the last 20 bytes of an `mmap`ed page, immediately followed by a
// second page with no access at all (the same guarded-page trick
// `bitfieldCompoundAssignStoresStorageWidth`,
// `tests/ut/backends/run/structs.d`, uses): a full 8-byte load at
// `value`'s offset 16 reads 4 bytes into the unmapped page and faults,
// where the correct 4-byte `copy` load never crosses the page boundary.
// Confirmed by hand: changing `loadOf`'s `case integer` to always
// return `Load.word64` (a full-word load, never `Load.copy`) crashes
// this test with `SIGSEGV`; reverting that one-line change passes it
// again.
@("called.memoryClassParameter.partialLastEightbyte")
unittest {
    import core.sys.posix.sys.mman:
        MAP_ANON, MAP_PRIVATE, PROT_NONE, PROT_READ, PROT_WRITE,
        mmap, mprotect, munmap;

    auto guestModule = parseSnippet(q{
        struct TwentyBytes {
            int a;
            int b;
            int c;
            int d;
            int e;
        }

        extern(C) int snakebite_ut_twenty_bytes(TwentyBytes value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_twenty_bytes");
    assert(function_ !is null,
        "No `snakebite_ut_twenty_bytes` in the guest program");

    enum pageSize = 4096;
    auto base = cast(ubyte*) mmap(
        null, 2 * pageSize, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(base !is null, "mmap failed");
    assert(mprotect(base + pageSize, pageSize, PROT_NONE) == 0);
    auto value =
        cast(TwentyBytes*) (base + pageSize - TwentyBytes.sizeof);
    *value = TwentyBytes(1, 2, 3, 4, 5);

    PlanCache cache;
    int result;
    cache.of(function_).call(&result, [cast(const void*) value]);

    munmap(base, 2 * pageSize);

    result.should == 12_345;
}


private struct AlignedMemory {
    real r;
    long padding;
}


// A MEMORY-class argument whose own ABI alignment is 16, not 8 - the
// stack area `buildMoves` writes into is only 8-byte aligned
// (`abi.validateMemoryParameter`'s own comment), so this is refused with
// a clear message instead of silently misaligning it (issue #334 step
// 3). `real`'s SysV alignment is 16, and the trailing `long` pushes the
// struct past two eightbytes, so `aggregatePlan` classifies it MEMORY
// by size alone (the `count > 2` check), without ever needing `classify`
// to understand a `real` field itself. `prepare` validates every
// parameter before it resolves a symbol (see `prepare`'s own body), so
// no native implementation of `snakebite_ut_aligned_memory` needs to
// exist for this test.
@("called.memoryClassParameter.refusedAlignment")
unittest {
    auto guestModule = parseSnippet(q{
        struct AlignedMemory {
            real r;
            long padding;
        }

        extern(C) void snakebite_ut_aligned_memory(AlignedMemory value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_aligned_memory");
    assert(function_ !is null,
        "No `snakebite_ut_aligned_memory` in the guest program");

    PlanCache cache;
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot pass a value of type `AlignedMemory`: its ABI " ~
            "alignment is 16 bytes, and only 8-byte-aligned MEMORY-class " ~
            "arguments are supported");
}


private struct TooBigMemory {
    size_t[65] words;
}


// A MEMORY-class argument whose size (520 bytes) exceeds `abi.
// ArgumentPlan.maxMemoryBytes` (512 bytes, `maxStackWords` whole
// eightbytes, issue #334 step 3) - refused with a clear message rather
// than only failing later, and more vaguely, against `prepare`'s own
// generic `words > maxStackWords` check. As with the alignment refusal
// above, nothing needs to resolve `snakebite_ut_too_big_memory`
// natively: this throws before symbol resolution.
@("called.memoryClassParameter.refusedSize")
unittest {
    auto guestModule = parseSnippet(q{
        struct TooBigMemory {
            size_t[65] words;
        }

        extern(C) void snakebite_ut_too_big_memory(TooBigMemory value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_too_big_memory");
    assert(function_ !is null,
        "No `snakebite_ut_too_big_memory` in the guest program");

    PlanCache cache;
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot pass a value of type `TooBigMemory`: its 520 bytes " ~
            "exceed the 512-byte limit for a MEMORY-class argument");
}


private extern(C) ThreeWords snakebite_ut_three_words_transform(
    ThreeWords value,
) {
    return ThreeWords(value.first + 1, value.second + 2, value.third + 3);
}


// A MEMORY-class struct both passed and returned in the same call - the
// one interaction of the new parameter path with `_returnPointerOffset`
// (issue #334 step 3): the hidden return pointer travels in the one
// integer register a scalar argument would otherwise use, exactly as
// `called.hiddenPointerReturn` already exercises for a MEMORY-class
// *return* alone, while `value` travels entirely on the stack,
// unaffected by that register being spoken for.
@("called.memoryClassParameter.returnedAndPassed")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        extern(C) ThreeWords snakebite_ut_three_words_transform(
            ThreeWords value,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_three_words_transform");
    assert(function_ !is null,
        "No `snakebite_ut_three_words_transform` in the guest program");

    PlanCache cache;
    ThreeWords value = ThreeWords(17, 31, 47);
    ThreeWords result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == ThreeWords(18, 33, 50);
}


private struct ContextMemoryParam {
    size_t offset;

    pragma(mangle, "snakebite_ut_context_memory_param")
    ThreeWords addOffset(ThreeWords value) {
        return ThreeWords(
            value.first + offset, value.second + offset,
            value.third + offset);
    }
}


// A method with a MEMORY-class parameter: the hidden context (`this`)
// and the hidden return pointer - this method returns a MEMORY-class
// `ThreeWords` too - travel together, in dmd's order (`this` first,
// `abi.contextPrecedesHiddenReturnPointer`'s own doc;
// `called.contextPrecedesHiddenReturnPointer` above checks the pair
// alone). `value` spills to the stack after both, the only spilled
// parameter here.
@("called.memoryClassParameter.methodParameter")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        struct ContextMemoryParam {
            size_t offset;

            // A body, never walked - see
            // `called.contextPrecedesHiddenReturnPointer`'s own comment
            // on why a body-less prototype would not have a hidden
            // `this` at all.
            pragma(mangle, "snakebite_ut_context_memory_param")
            extern(D) ThreeWords addOffset(ThreeWords value) { assert(0); }
        }
    });
    auto struct_ = findStruct(guestModule, "ContextMemoryParam");
    assert(struct_ !is null,
        "No struct `ContextMemoryParam` in the guest program");
    auto function_ = findFunction(struct_, "addOffset");
    assert(function_ !is null,
        "No `addOffset` method in the guest program");

    PlanCache cache;
    ContextMemoryParam instance;
    instance.offset = 100;
    ContextMemoryParam* receiver = &instance;
    ThreeWords value = ThreeWords(17, 31, 47);
    ThreeWords result;
    cache.of(function_).call(&result, [
        cast(const void*) &receiver, cast(const void*) &value,
    ]);

    result.should == ThreeWords(117, 131, 147);
}


private ThreeWords _twoMemoryFirst;
private FourWords _twoMemorySecond;


pragma(mangle, "snakebite_ut_extern_d_two_memory")
private extern(D) void snakebite_ut_twoMemoryParams(
    ThreeWords first, FourWords second,
) {
    _twoMemoryFirst = first;
    _twoMemorySecond = second;
}


// Two MEMORY-class parameters in one call - both always spill (`abi.
// ArgumentPlan`'s own doc), and dmd's reversed `extern(D)` convention
// places every spilled argument on the stack in descending declaration
// order (`_reversedArguments`'s own doc), so `second`'s four eightbytes
// land before `first`'s three - reversed from declaration order. The
// same rule `called.externD.memoryClassParameterTwoScalarSpills` checks
// for a mix of MEMORY and scalar spills, exercised here for two MEMORY
// parameters alone.
@("called.memoryClassParameter.twoParameters")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWords {
            size_t first;
            size_t second;
            size_t third;
        }

        struct FourWords {
            size_t first;
            size_t second;
            size_t third;
            size_t fourth;
        }

        pragma(mangle, "snakebite_ut_extern_d_two_memory")
        extern(D) void snakebite_ut_twoMemoryParams(
            ThreeWords first, FourWords second,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_twoMemoryParams");
    assert(function_ !is null,
        "No `snakebite_ut_twoMemoryParams` in the guest program");

    PlanCache cache;
    ThreeWords first = ThreeWords(1, 2, 3);
    FourWords second = FourWords(10, 20, 30, 40);
    cache.of(function_).call(null, [
        cast(const void*) &first, cast(const void*) &second,
    ]);

    _twoMemoryFirst.should == ThreeWords(1, 2, 3);
    _twoMemorySecond.should == FourWords(10, 20, 30, 40);
}


private struct SixteenBytesAligned {
    int a;
    align(1) long b;
    int c;
}


private extern(C) long snakebite_ut_sixteen_bytes_aligned(
    SixteenBytesAligned value,
) {
    return value.a * 10_000 + value.b * 100 + value.c;
}


// A 16-byte struct with an `align(1)` field - MEMORY purely by
// alignment (`abi.classify`'s field-offset check), not by size: its
// byte count alone (16) classifies as two ordinary eightbytes (the
// `count > 2` check in `aggregatePlan` never fires), unlike
// `memoryClassParameter.unalignedField`'s 12-byte `PackedPair`. Its own
// size is a whole number of eightbytes, so both of `value`'s moves are
// full `word64` loads - no partial-eightbyte `copy`, unlike
// `partialLastEightbyte`.
@("called.memoryClassParameter.sixteenBytesAlignedField")
unittest {
    auto guestModule = parseSnippet(q{
        struct SixteenBytesAligned {
            int a;
            align(1) long b;
            int c;
        }

        extern(C) long snakebite_ut_sixteen_bytes_aligned(
            SixteenBytesAligned value,
        );
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_sixteen_bytes_aligned");
    assert(function_ !is null,
        "No `snakebite_ut_sixteen_bytes_aligned` in the guest program");

    PlanCache cache;
    SixteenBytesAligned value = SixteenBytesAligned(3, 39, 5);
    long result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 33_905;
}


// A mixed INTEGER/SSE pair whose INTEGER lane and SSE lane both have no
// register left in their own file - the shape the old code threw on with
// "ffi cannot place a mixed INTEGER/SSE aggregate when both register
// files need stack arguments" (issue #334 step 4). Per the psABI's
// classification step 5c, this still just spills: the whole argument
// goes to the stack, both eightbytes together, leaving the (already
// full) registers alone.
@("called.mixedStructBothFilesFull")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) long snakebite_ut_mixed_both_files_full(
            long i0, long i1, long i2, long i3, long i4, long i5,
            double d0, double d1, double d2, double d3, double d4,
            double d5, double d6, double d7,
            MixedPair value,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_both_files_full");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_both_files_full` in the guest program");

    PlanCache cache;
    long[6] integers = [1, 2, 3, 4, 5, 6];
    double[8] floatings = [1, 1, 1, 1, 1, 1, 1, 1];
    MixedPair value = MixedPair(7, 1.5);
    long result;
    void*[15] arguments;
    foreach (i, ref v; integers)
        arguments[i] = &v;
    foreach (i, ref v; floatings)
        arguments[6 + i] = &v;
    arguments[14] = &value;

    cache.of(function_).call(&result, arguments[]);

    result.should == 7030;
}


// Six `long`s fill the integer register file; `value` - a mixed
// INTEGER/SSE pair - spills whole because its INTEGER lane has no
// register left, even though its SSE lane still would fit, and `j`,
// declared after it, spills too. dmd's reversed `extern(D)` convention
// places every spilled argument on the stack in descending declaration
// order, so this exercises that reversal for a mixed aggregate spill
// alongside a scalar spill, not just plain scalars
// (`called.externD.mixedSpillsOneLongOneDouble` above).
@("called.externD.mixedStructWithScalarSpill")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        pragma(mangle, "snakebite_ut_extern_d_mixed_scalar_spill")
        extern(D) void snakebite_ut_externDMixedScalarSpill(
            long i0, long i1, long i2, long i3, long i4, long i5,
            MixedPair value, long j,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_externDMixedScalarSpill");
    assert(function_ !is null,
        "No `snakebite_ut_externDMixedScalarSpill` in the guest program");

    PlanCache cache;
    long i0 = 10, i1 = 20, i2 = 30, i3 = 40, i4 = 50, i5 = 60;
    MixedPair value = MixedPair(7, 1.5);
    long j = 99;
    cache.of(function_).call(null, [
        cast(const void*) &i0, cast(const void*) &i1,
        cast(const void*) &i2, cast(const void*) &i3,
        cast(const void*) &i4, cast(const void*) &i5,
        cast(const void*) &value, cast(const void*) &j,
    ]);

    _mixedScalarSpillIntegerSeen.should == 10;
    _mixedScalarSpillFloatingSeen.should == 1.5;
    _mixedScalarSpillTrailingSeen.should == 99;
}


// `MixedPairReversed` declares its SSE-class field (`floating`) before
// its INTEGER-class one (`integer`) - the opposite field order from
// `MixedPair`. Six plain `int`s fill the integer register file, so
// `value` spills; the stack copy must still place `floating`'s eightbyte
// before `integer`'s, matching the struct's own declaration order, not
// swap them to some fixed INTEGER-then-SSE order.
@("called.mixedStructDoubleFirstSpills")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPairReversed {
            double floating;
            int integer;
        }

        extern(C) long snakebite_ut_mixed_reversed_after_six(
            int a, int b, int c, int d, int e, int f,
            MixedPairReversed value,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_reversed_after_six");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_reversed_after_six` in the guest program");

    PlanCache cache;
    int[6] integers = [1, 2, 3, 4, 5, 6];
    MixedPairReversed value = MixedPairReversed(2.0, 37);
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &integers[0], cast(const void*) &integers[1],
        cast(const void*) &integers[2], cast(const void*) &integers[3],
        cast(const void*) &integers[4], cast(const void*) &integers[5],
        cast(const void*) &value,
    ]);

    result.should == 258;
}
