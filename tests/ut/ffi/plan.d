module ut.ffi.plan;


import ut;
import dmd.func: FuncDeclaration;
import dmd.mtype: Type;
import dmd.statement: ReturnStatement, Statement;
import dmd.typesem: nextOf;
import snakebite.ffi: CallAdapter, PlanCache;
import snakebite.ffi.abi: ArgumentPlan, needsHiddenReturnPointer;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions:
    findFunction, findStruct, typeFunctionOf;
import std.algorithm.searching: canFind;
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

private struct Fieldless {}

// dmd compiles this the same way for any fieldless struct: `mov rax,
// rdi; mov byte [rdi], 0; ret` - a write through whatever this process's
// calling convention left in the hidden-pointer register, never checked
// against the struct's own (nonexistent) fields.
private extern(C) Fieldless snakebite_ut_fieldless_return() {
    return Fieldless();
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

// Six plain `int`s fill the integer register file, so `value` spills
// (its INTEGER lane has no register left), consuming no register from
// either file. `g`, a `double` declared after `value`, proves the free
// SSE file was left untouched by that spill: a `buildMoves` that still
// bumped the SSE count for the aggregate's own free-fitting SSE lane
// would place `g` in the second SSE register instead of the first, and
// the real native callee below (built by dmd, following the true ABI)
// would then read the wrong value from it (issue #334 step 4).
private extern(C) long snakebite_ut_mixed_after_six_free_sse(
    int a, int b, int c, int d, int e, int f, MixedPair value, double g,
) {
    return a + b + c + d + e + f
        + value.integer * 1000 + cast(long) value.floating
        + cast(long) (g * 1_000_000.0);
}

// Eight `double`s fill the SSE register file, so `value` spills (its SSE
// lane has no register left), consuming no register from either file.
// `g`, an `int` declared after `value`, proves the free integer file was
// left untouched by that spill, the mirror image of
// `snakebite_ut_mixed_after_six_free_sse` above (issue #334 step 4).
private extern(C) long snakebite_ut_mixed_after_eight_free_integer(
    double a, double b, double c, double d,
    double e, double f, double g, double h,
    MixedPair value, int i,
) {
    return cast(long) (a + b + c + d + e + f + g + h)
        + value.integer * 1000 + cast(long) value.floating
        + i * 1_000_000L;
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

private long _mixedScalarSpillLeadingSeen;
private long _mixedScalarSpillIntegerSeen;
private double _mixedScalarSpillFloatingSeen;
private long _mixedScalarSpillTrailingSeen;

// dmd applies the C ABI to the fully reversed parameter list (see
// `_reversedArguments`'s own doc), so the six trailing `long`s below
// (`j0` .. `j5`) claim the six integer registers first, in reverse -
// `j5` in the first integer register, down to `j0` in the sixth and
// last. `value`'s INTEGER lane then has no register left (its SSE lane
// would still fit, but the SysV ABI never splits a multi-eightbyte
// argument across the register/stack boundary - psABI 3.2.3
// classification step 5c), so it spills whole, and `a`, declared before
// it but reached after it in the reversed order, spills too. Verified
// with `objdump --disassemble` on the compiled callee: `mov
// 0x20(%rsp),%ebx` reads `value.integer` from stack word 0, `movsd
// 0x28(%rsp),%xmm0` reads `value.floating` from word 1, and `mov
// 0x30(%rsp),%rax` reads `a` from word 2 - the descending-index spilled
// order `buildMoves` produces, not declaration order.
pragma(mangle, "snakebite_ut_extern_d_mixed_scalar_spill")
private extern(D) void snakebite_ut_externDMixedScalarSpill(
    long a, MixedPair value,
    long j0, long j1, long j2, long j3, long j4, long j5,
) {
    _mixedScalarSpillLeadingSeen = a;
    _mixedScalarSpillIntegerSeen = value.integer;
    _mixedScalarSpillFloatingSeen = value.floating;
    _mixedScalarSpillTrailingSeen = j0;
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

// Eight `double`s fill the SSE register file, and the integer register
// file is free - `value`'s SSE lane (`floating`, declared first) has no
// register left, so the whole aggregate spills, the mirror image of
// `snakebite_ut_mixed_reversed_after_six` above, where the *integer*
// file was the full one. This is the shape where a per-lane
// implementation would split the aggregate, since its INTEGER lane
// (`integer`) would still fit a free integer register.
private extern(C) long snakebite_ut_mixed_reversed_after_eight_doubles(
    double x0, double x1, double x2, double x3,
    double x4, double x5, double x6, double x7,
    MixedPairReversed value,
) {
    return cast(long) (x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7)
        + cast(long) value.floating * 100 + value.integer;
}

private extern(C) double snakebite_ut_scale(double value) {
    return value * 2.5;
}

private real _realArgumentSeen;

private extern(C) real snakebite_ut_real_identity(real value) {
    return value;
}

private extern(C) void snakebite_ut_real_argument(real value) {
    _realArgumentSeen = value;
}

private extern(C) real snakebite_ut_real_result() {
    return 1.0L + real.epsilon;
}

private extern(C) real snakebite_ut_real_after_odd_stack(
    long a, long b, long c, long d, long e, long f, long prefix, real value,
) {
    return value + prefix;
}

private extern(C) real snakebite_ut_real_mixed(
    long integer, double floating, real value,
) {
    return value + integer + floating;
}

pragma(mangle, "snakebite_ut_real_d")
private extern(D) real snakebite_ut_real_d(real value) {
    return value;
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


// dmd's own rule for a struct with no fields (`argtypes_sysv_x64.d`,
// `toArgTypes_sysv_x64`: "if (nfields == 0) return memory();") makes it
// MEMORY-class, the same as an oversized or unaligned aggregate - both
// host compilers return such a value through a hidden pointer, never in a
// register (verified with `objdump`: `struct E {} E f() { return E(); }`
// compiles to `mov rax, rdi; mov byte [rdi], 0; ret` on both dmd and ldc).
// `abi.classify` walks `aggregate.sym.fields` to build its eightbyte
// classes; an empty range leaves every class untouched instead of
// reaching this rule, so a fieldless struct's return used to need no
// hidden pointer at all - the bug this pins against a regression.
@("abi.fieldlessStructReturnNeedsHiddenPointer")
unittest {
    auto guestModule = parseSnippet(q{
        struct E {}
        extern(C) E snakebite_ut_fieldless_return();
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_fieldless_return");
    assert(function_ !is null,
        "No `snakebite_ut_fieldless_return` in the guest program");

    auto returnType = typeFunctionOf(function_).nextOf;
    needsHiddenReturnPointer(returnType).should == true;
}


// The same dmd rule applies to a fieldless struct passed by value, not
// only a returned one - `classify` is the shared walk both
// `ArgumentPlan.of`'s parameter path and `aggregatePlan`'s return path
// read.
@("abi.fieldlessStructParameterIsMemoryClass")
unittest {
    auto guestModule = parseSnippet(q{
        struct E {}
        extern(C) void snakebite_ut_fieldless_param(E value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_fieldless_param");
    assert(function_ !is null,
        "No `snakebite_ut_fieldless_param` in the guest program");

    auto parameterType = typeFunctionOf(function_).parameterList[0].type;
    const plan = ArgumentPlan.of(parameterType);

    plan.memory.should == true;
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


@("called.scalarReal.roundTrip")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) real snakebite_ut_real_identity(real value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_identity");
    assert(function_ !is null,
        "No `snakebite_ut_real_identity` in the guest program");

    PlanCache cache;
    real value = 1.0L + real.epsilon;
    real result;
    cache.of(function_).call(&result, [cast(const(void)*) &value]);

    result.should == value;
}


@("called.scalarReal.argumentOnly")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) void snakebite_ut_real_argument(real value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_argument");
    assert(function_ !is null,
        "No `snakebite_ut_real_argument` in the guest program");

    PlanCache cache;
    real value = 7.25L;
    cache.of(function_).call(null, [cast(const(void)*) &value]);

    _realArgumentSeen.should == value;
}


@("called.scalarReal.resultOnly")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) real snakebite_ut_real_result();
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_result");
    assert(function_ !is null,
        "No `snakebite_ut_real_result` in the guest program");

    PlanCache cache;
    real result;
    cache.of(function_).call(&result, []);

    result.should == 1.0L + real.epsilon;
}


@("called.scalarReal.afterOddStackWord")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) real snakebite_ut_real_after_odd_stack(
            long a, long b, long c, long d, long e, long f,
            long prefix, real value,
        );
    });
    auto function_ = findFunction(
        guestModule, "snakebite_ut_real_after_odd_stack",
    );
    assert(function_ !is null,
        "No `snakebite_ut_real_after_odd_stack` in the guest program");

    PlanCache cache;
    long[7] prefix = [1, 2, 3, 4, 5, 6, 7];
    real value = 10.5L;
    real result;
    cache.of(function_).call(&result, [
        cast(const(void)*) &prefix[0], cast(const(void)*) &prefix[1],
        cast(const(void)*) &prefix[2], cast(const(void)*) &prefix[3],
        cast(const(void)*) &prefix[4], cast(const(void)*) &prefix[5],
        cast(const(void)*) &prefix[6], cast(const(void)*) &value,
    ]);

    result.should == 17.5L;
}


@("called.scalarReal.mixedIntDouble")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) real snakebite_ut_real_mixed(
            long integer, double floating, real value,
        );
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_mixed");
    assert(function_ !is null,
        "No `snakebite_ut_real_mixed` in the guest program");

    PlanCache cache;
    long integer = 3;
    double floating = 2.5;
    real value = 4.0L;
    real result;
    cache.of(function_).call(&result, [
        cast(const(void)*) &integer, cast(const(void)*) &floating,
        cast(const(void)*) &value,
    ]);

    result.should == 9.5L;
}


@("called.scalarReal.discardedReturnsPopX87")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) real snakebite_ut_real_result();
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_result");
    assert(function_ !is null,
        "No `snakebite_ut_real_result` in the guest program");

    PlanCache cache;
    auto plan = cache.of(function_);
    foreach (i; 0 .. 256)
        plan.call(null, []);

    real result;
    plan.call(&result, []);
    result.should == 1.0L + real.epsilon;
}


@("called.scalarReal.modflOutParameter")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) real modfl(real value, out real integral);
    });
    auto function_ = findFunction(guestModule, "modfl");
    assert(function_ !is null,
        "No `modfl` in the guest program");

    PlanCache cache;
    real value = 3.75L;
    real integral;
    real* integralSlot = &integral;
    real result;
    cache.of(function_).call(&result, [
        cast(const(void)*) &value, cast(const(void)*) &integralSlot,
    ]);

    result.should == 0.75L;
    integral.should == 3.0L;
}


@("called.scalarReal.externD")
unittest {
    auto guestModule = parseSnippet(q{
        pragma(mangle, "snakebite_ut_real_d")
        extern(D) real snakebite_ut_real_d(real value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_d");
    assert(function_ !is null,
        "No `snakebite_ut_real_d` in the guest program");

    PlanCache cache;
    real value = 1.0L + real.epsilon;
    real result;
    cache.of(function_).call(&result, [cast(const(void)*) &value]);

    result.should == value;
}


@("called.scalarReal.aggregateReturnRejected")
unittest {
    auto guestModule = parseSnippet(q{
        struct RealPair { real value; }
        extern(C) RealPair snakebite_ut_real_pair();
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_real_pair");
    assert(function_ !is null,
        "No `snakebite_ut_real_pair` in the guest program");

    PlanCache cache;
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot return an aggregate containing `real`",
    );
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
    int[6] integers = [10, 20, 30, 40, 50, 60];
    MixedPair value = MixedPair(7, 1.5);
    MixedPair result;
    cache.of(function_).call(&result, [
        cast(const void*) &integers[0], cast(const void*) &integers[1],
        cast(const void*) &integers[2], cast(const void*) &integers[3],
        cast(const void*) &integers[4], cast(const void*) &integers[5],
        cast(const void*) &value,
    ]);

    result.should == MixedPair(217, 7.5);
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
    double[8] floating = [1, 2, 3, 4, 5, 6, 7, 8];
    MixedPair value = MixedPair(7, 1.5);
    MixedPair result;
    cache.of(function_).call(&result, [
        cast(const void*) &floating[0], cast(const void*) &floating[1],
        cast(const void*) &floating[2], cast(const void*) &floating[3],
        cast(const void*) &floating[4], cast(const void*) &floating[5],
        cast(const void*) &floating[6], cast(const void*) &floating[7],
        cast(const void*) &value,
    ]);

    result.should == MixedPair(43, 7.5);
}


@("called.mixedStructOnStackFreeSSENotConsumed")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) long snakebite_ut_mixed_after_six_free_sse(
            int a, int b, int c, int d, int e, int f, MixedPair value,
            double g,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_after_six_free_sse");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_after_six_free_sse` in the program");

    PlanCache cache;
    int[6] integers = [1, 2, 3, 4, 5, 6];
    MixedPair value = MixedPair(7, 1.5);
    double g = 9.0;
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &integers[0], cast(const void*) &integers[1],
        cast(const void*) &integers[2], cast(const void*) &integers[3],
        cast(const void*) &integers[4], cast(const void*) &integers[5],
        cast(const void*) &value, cast(const void*) &g,
    ]);

    result.should == 9_007_022;
}


@("called.mixedStructAfterSSEFreeIntegerNotConsumed")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) long snakebite_ut_mixed_after_eight_free_integer(
            double a, double b, double c, double d,
            double e, double f, double g, double h,
            MixedPair value, int i,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_after_eight_free_integer");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_after_eight_free_integer` in the program");

    PlanCache cache;
    double[8] floating = [1, 1, 1, 1, 1, 1, 1, 1];
    MixedPair value = MixedPair(7, 1.5);
    int i = 3;
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &floating[0], cast(const void*) &floating[1],
        cast(const void*) &floating[2], cast(const void*) &floating[3],
        cast(const void*) &floating[4], cast(const void*) &floating[5],
        cast(const void*) &floating[6], cast(const void*) &floating[7],
        cast(const void*) &value, cast(const void*) &i,
    ]);

    result.should == 3_007_009;
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


// A fieldless struct's return still needs a hidden return pointer
// (`abi.fieldlessStructReturnNeedsHiddenPointer` pins the classification
// alone) - this pins the actual call: dmd's own codegen for any fieldless
// struct's return is `mov rax, rdi; mov byte [rdi], 0; ret`, so the call
// must hand the callee `returnPlace` in the hidden-pointer register for
// that one byte to land in `result` - a plan that never marks the return
// hidden never tells `fillFrame` to put `returnPlace` there, so the
// callee's write goes through whatever the assembly stub's generic frame
// left in that register/slot instead (a stack address elsewhere in this
// same process, not `result` - verified with `gdb`: the pre-fix write
// lands nowhere `result` can be read back from, not a crash), and
// `result`'s own byte - deliberately set to a sentinel no fieldless
// struct's own codegen would ever write - stays unchanged. This is the
// call-seam version of the same bug the guest program in `ut.backends.
// call.ffi`'s `tuple.fieldlessReturnDoesNotCorruptPrecedingArray` runs
// end to end: there, the corrupted memory is a real guest array's length
// word, chosen by whatever call happened to precede the fieldless return
// in the compiled image, not a sentinel this test controls directly.
@("called.fieldlessReturnWritesThroughHiddenPointer")
unittest {
    auto guestModule = parseSnippet(q{
        struct Fieldless {}

        extern(C) Fieldless snakebite_ut_fieldless_return();
    });
    auto getter =
        findFunction(guestModule, "snakebite_ut_fieldless_return");
    assert(getter !is null,
        "No `snakebite_ut_fieldless_return` in the guest program");

    PlanCache cache;
    Fieldless result;
    *cast(ubyte*) &result = 0xFF;
    cache.of(getter).call(&result, []);

    (*cast(ubyte*) &result).should == 0;
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
            // symbol name; it never inspects `fbody`. The body stays for
            // a different reason: with no `extern` linkage to a host
            // symbol, it is what gives this function code to emit and a
            // mangled symbol `PlanCache.of`'s own resolver can find -
            // `hasHiddenThis`'s `isThis()`/`isNested()` fallback
            // (`snakebite.frontend.dmd.delegates`) already reads a
            // body-less prototype as having a hidden `this` correctly,
            // the same as one with a body.
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


private struct ContextThenMixedSpill {
    pragma(mangle, "snakebite_ut_context_then_mixed_spill")
    long sumFiveLongsThenMixed(
        long a0, long a1, long a2, long a3, long a4, MixedPair value,
    ) {
        return a0 + a1 * 10 + a2 * 100 + a3 * 1000 + a4 * 10_000
            + value.integer * 100_000
            + cast(long) (value.floating * 1_000_000);
    }
}


// A method's hidden `this` claims one integer register before its
// explicit parameters (`called.contextPrecedesHiddenReturnPointer`
// above). Five plain `long`s then fill the remaining five integer
// registers, so `value`'s INTEGER lane has no register left and the
// whole aggregate spills - the free-function signature `abi.
// contextPrecedesHiddenReturnPointer` tests elsewhere (`this` plus five
// `long`s, six total) would still fit six integer registers and keep
// `value` in registers instead; only the method's hidden context tips it
// over. Backend level (a guest struct method actually executed through
// `shouldBeRetOf`) cannot exercise this: a guest declaration needs a
// body for `hasHiddenThis` to see its `vthis` (`called.
// contextPrecedesHiddenReturnPointer`'s own doc), but any guest
// declaration with a body always runs as guest code
// (`snakebite.backends.calls.CallSelection`'s own doc - "a guest
// function's body is the one being tested, so it runs as guest even when
// its linker name is also in this process"), never as an FFI call -
// verified by trying it: a bodyless guest method left `hasHiddenThis`
// false and both interpreting backends read garbage, and giving it a
// body made every backend, Native included, run `assert(0)` instead of
// calling the real native method. `PlanCache.of` sidesteps this by
// reading the declaration's dmd facts directly and never interpreting
// `fbody` at all, the same way `called.
// contextPrecedesHiddenReturnPointer` above does.
@("called.mixedStructAfterHiddenContext")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        struct ContextThenMixedSpill {
            pragma(mangle, "snakebite_ut_context_then_mixed_spill")
            extern(D) long sumFiveLongsThenMixed(
                long a0, long a1, long a2, long a3, long a4,
                MixedPair value,
            ) { assert(0); }
        }
    });
    auto struct_ = findStruct(guestModule, "ContextThenMixedSpill");
    assert(struct_ !is null,
        "No struct `ContextThenMixedSpill` in the guest program");
    auto function_ = findFunction(struct_, "sumFiveLongsThenMixed");
    assert(function_ !is null,
        "No `sumFiveLongsThenMixed` method in the guest program");

    PlanCache cache;
    ContextThenMixedSpill instance;
    ContextThenMixedSpill* receiver = &instance;
    long a0 = 1, a1 = 2, a2 = 3, a3 = 4, a4 = 5;
    MixedPair value = MixedPair(7, 1.5);
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &receiver,
        cast(const void*) &a0, cast(const void*) &a1,
        cast(const void*) &a2, cast(const void*) &a3,
        cast(const void*) &a4, cast(const void*) &value,
    ]);

    result.should == 2_254_321;
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


private long _alignedMemoryResult;


private extern(C) void snakebite_ut_aligned_memory(AlignedMemory value) {
    _alignedMemoryResult = cast(long) value.r + value.padding;
}


private extern(C) void snakebite_ut_aligned_memory_after_odd_stack_word(
    long a, long b, long c, long d, long e, long f, long prefix,
    AlignedMemory value,
) {
    _alignedMemoryResult = cast(long) value.r + value.padding + prefix
        + a + b + c + d + e + f;
}


// A MEMORY-class argument whose own ABI alignment is 16. `real`'s SysV
// alignment is 16, and the trailing `long` pushes the struct past two
// eightbytes, so `aggregatePlan` classifies it MEMORY by size alone (the
// `count > 2` check), without needing `classify` to understand a `real`
// field itself.
@("called.memoryClassParameter.alignedArgument")
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
    AlignedMemory value = AlignedMemory(17, 31);
    cache.of(function_).call(null, [cast(const(void*)) &value]);

    _alignedMemoryResult.should == 48;
}


// The preceding `prefix` is the first stack word after six integer
// registers. The 16-byte-aligned argument then needs one padding word
// before its own stack words.
@("called.memoryClassParameter.alignedArgumentAfterOddStackWord")
unittest {
    auto guestModule = parseSnippet(q{
        struct AlignedMemory {
            real r;
            long padding;
        }

        extern(C) void snakebite_ut_aligned_memory_after_odd_stack_word(
            long a, long b, long c, long d, long e, long f, long prefix,
            AlignedMemory value,
        );
    });
    auto function_ = findFunction(
        guestModule, "snakebite_ut_aligned_memory_after_odd_stack_word",
    );
    assert(function_ !is null,
        "No `snakebite_ut_aligned_memory_after_odd_stack_word` in the " ~
            "guest program");

    PlanCache cache;
    AlignedMemory value = AlignedMemory(17, 31);
    long[7] prefix = [1, 2, 3, 4, 5, 6, 7];
    cache.of(function_).call(null, [
        cast(const(void*)) &prefix[0], cast(const(void*)) &prefix[1],
        cast(const(void*)) &prefix[2], cast(const(void*)) &prefix[3],
        cast(const(void*)) &prefix[4], cast(const(void*)) &prefix[5],
        cast(const(void*)) &prefix[6], cast(const(void*)) &value,
    ]);

    _alignedMemoryResult.should == 76;
}


// The assembly stub guarantees a 16-byte stack base. A greater alignment
// needs a different stub, so the planner must reject it before resolution.
@("called.memoryClassParameter.refusedOverAlignment")
unittest {
    auto guestModule = parseSnippet(q{
        struct OverAligned {
            align(32) long word;
            long[3] words;
        }

        extern(C) void snakebite_ut_over_aligned(OverAligned value);
    });
    auto function_ = findFunction(guestModule, "snakebite_ut_over_aligned");
    assert(function_ !is null,
        "No `snakebite_ut_over_aligned` in the guest program");

    PlanCache cache;
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot pass a value of type `OverAligned`: its ABI alignment " ~
            "is 32 bytes, and only 16-byte-aligned MEMORY-class arguments " ~
            "are supported");
}


private struct LargeMemory {
    size_t[65] words;
}


private extern(C) size_t snakebite_ut_large_memory(LargeMemory value) {
    size_t result;
    foreach (i, word; value.words)
        result += (i + 1) * word;
    return result;
}


// The first whole eightbyte past the former 512-byte limit must reach
// the native callee, with every word in its original position.
@("called.memoryClassParameter.largeArgument")
unittest {
    auto guestModule = parseSnippet(q{
        struct LargeMemory {
            size_t[65] words;
        }

        extern(C) size_t snakebite_ut_large_memory(LargeMemory value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_large_memory");
    assert(function_ !is null,
        "No `snakebite_ut_large_memory` in the guest program");

    PlanCache cache;
    LargeMemory value;
    foreach (i, ref word; value.words)
        word = i + 1;
    size_t result;
    cache.of(function_).call(&result, [cast(const void*) &value]);

    result.should == 65 * 66 * 131 / 6;
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
            // on why the body stays anyway.
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


// The six trailing `long`s (`j0` .. `j5`) claim the integer register
// file first, in dmd's fully reversed `extern(D)` order (see
// `snakebite_ut_externDMixedScalarSpill`'s own doc above): `j5` claims
// the first integer register, down to `j0` claiming the sixth and last.
// `value` - a mixed INTEGER/SSE pair - then spills whole because its
// INTEGER lane has no register left, even though its SSE lane still
// would fit, and `a`, declared before it but reached after it in the
// reversed order, spills too. dmd's reversed `extern(D)` convention
// places every spilled argument on the stack in descending declaration
// order, so this exercises that reversal for a mixed aggregate spilled
// under six *trailing* register-claiming scalars, the opposite
// declaration order from `called.externD.mixedSpillsOneLongOneDouble`
// above.
@("called.externD.mixedStructWithScalarSpill")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPair {
            int integer;
            double floating;
        }

        pragma(mangle, "snakebite_ut_extern_d_mixed_scalar_spill")
        extern(D) void snakebite_ut_externDMixedScalarSpill(
            long a, MixedPair value,
            long j0, long j1, long j2, long j3, long j4, long j5,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_externDMixedScalarSpill");
    assert(function_ !is null,
        "No `snakebite_ut_externDMixedScalarSpill` in the guest program");

    PlanCache cache;
    long a = 1;
    MixedPair value = MixedPair(7, 1.5);
    long j0 = 10, j1 = 20, j2 = 30, j3 = 40, j4 = 50, j5 = 60;
    cache.of(function_).call(null, [
        cast(const void*) &a, cast(const void*) &value,
        cast(const void*) &j0, cast(const void*) &j1,
        cast(const void*) &j2, cast(const void*) &j3,
        cast(const void*) &j4, cast(const void*) &j5,
    ]);

    _mixedScalarSpillLeadingSeen.should == 1;
    _mixedScalarSpillIntegerSeen.should == 7;
    _mixedScalarSpillFloatingSeen.should == 1.5;
    _mixedScalarSpillTrailingSeen.should == 10;
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


// Eight `double`s fill the SSE register file, and the integer register
// file is free - `value`'s SSE lane (`floating`, `MixedPairReversed`'s
// first field) has no register left, so the whole aggregate spills, the
// mirror image of `called.mixedStructDoubleFirstSpills` above, where the
// *integer* file was the full one. This is the shape where a per-lane
// implementation would split the aggregate, since its INTEGER lane
// (`integer`) would still fit a free integer register.
@("called.mixedStructReversedAfterEightDoubles")
unittest {
    auto guestModule = parseSnippet(q{
        struct MixedPairReversed {
            double floating;
            int integer;
        }

        extern(C) long snakebite_ut_mixed_reversed_after_eight_doubles(
            double x0, double x1, double x2, double x3,
            double x4, double x5, double x6, double x7,
            MixedPairReversed value,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_mixed_reversed_after_eight_doubles");
    assert(function_ !is null,
        "No `snakebite_ut_mixed_reversed_after_eight_doubles` in the " ~
            "guest program");

    PlanCache cache;
    double[8] x = [1, 1, 1, 1, 1, 1, 1, 1];
    MixedPairReversed value = MixedPairReversed(2.0, 37);
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &x[0], cast(const void*) &x[1],
        cast(const void*) &x[2], cast(const void*) &x[3],
        cast(const void*) &x[4], cast(const void*) &x[5],
        cast(const void*) &x[6], cast(const void*) &x[7],
        cast(const void*) &value,
    ]);

    result.should == 245;
}


private struct MemoryTriple {
    size_t first;
    size_t second;
    size_t third;
}

// Six plain `int`s fill the integer register file. `m` - a MEMORY-class
// argument - always spills, whatever room is left (`abi.ArgumentPlan`'s
// own doc), and `value` - a mixed INTEGER/SSE pair whose INTEGER lane
// has no register left either - spills too. Step 3 (MEMORY) and step 4
// (mixed) both route through the same `addSpilled`/`spilled[]`
// machinery, ordered by parameter index: `m`'s three eightbytes land at
// stack words 0-2, then `value`'s two eightbytes at words 3-4. This is
// the only test that puts both on the same stack.
private extern(C) long snakebite_ut_memory_and_mixed(
    int a, int b, int c, int d, int e, int f,
    MemoryTriple m, MixedPair value,
) {
    return a + b + c + d + e + f
        + cast(long) (m.first * 10 + m.second * 100 + m.third * 1000)
        + value.integer * 10_000
        + cast(long) (value.floating * 100_000);
}

@("called.mixedStructAfterMemoryOnStack")
unittest {
    auto guestModule = parseSnippet(q{
        struct MemoryTriple {
            size_t first;
            size_t second;
            size_t third;
        }

        struct MixedPair {
            int integer;
            double floating;
        }

        extern(C) long snakebite_ut_memory_and_mixed(
            int a, int b, int c, int d, int e, int f,
            MemoryTriple m, MixedPair value,
        );
    });
    auto function_ = findFunction(guestModule,
        "snakebite_ut_memory_and_mixed");
    assert(function_ !is null,
        "No `snakebite_ut_memory_and_mixed` in the guest program");

    PlanCache cache;
    int[6] integers = [1, 2, 3, 4, 5, 6];
    MemoryTriple m = MemoryTriple(1, 2, 3);
    MixedPair value = MixedPair(7, 1.5);
    long result;
    cache.of(function_).call(&result, [
        cast(const void*) &integers[0], cast(const void*) &integers[1],
        cast(const void*) &integers[2], cast(const void*) &integers[3],
        cast(const void*) &integers[4], cast(const void*) &integers[5],
        cast(const void*) &m, cast(const void*) &value,
    ]);

    result.should == 223_231;
}


// The variadic shapes below (issue #334 step 5) exercise `CallPlan.
// prepareVariadic`/`PlanCache.variadicOf`: an `extern(C)` C-style
// variadic callee's plan depends on one call site's own extra
// arguments, not on the callee's declaration alone (ADR-0010's
// C-variadics paragraph). Each host function is real, compiled code in
// this test binary - the same shape as `snakebite_ut_bump` above -
// written against `core.stdc.stdarg` so its own `va_arg` reads prove the
// ABI classification these tests exercise, not just that the bytes
// arrived somewhere.

// Always reads exactly nine `int`s past `first` - paired with a guest
// call site that always passes exactly nine, for `called.variadic.
// tenIntsFourSpillToTheStack` below. Ten INTEGER-class words in total:
// six fill the integer register file, and the last four spill to the
// stack. Each extra is weighted by its own position (`i + 1`) before
// being added: a plain sum reads the same total back whether the
// extras arrive in order or two of them are swapped - a reversed
// stack spill or two swapped registers - so a plain sum cannot tell a
// correct call from a misordered one (issue #334 step 5 review
// finding 4). A weighted sum can, since swapping two extras' values
// then changes which weight each one is multiplied by.
private extern(C) int snakebite_ut_variadic_sum_ints(int first, ...) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, first);
    int total = first;
    foreach (i; 0 .. 9)
        total += (i + 1) * va_arg!int(args);
    va_end(args);
    return total;
}


// As `snakebite_ut_variadic_sum_ints`, but reads its own count of extra
// arguments instead of a fixed nine, so two call sites can pass it a
// different number of extra arguments safely (`called.variadic.
// sameCalleeTwoCallSitesDifferentArgumentCounts` below). Weighted by
// position, the same reason as `snakebite_ut_variadic_sum_ints`.
private extern(C) int snakebite_ut_variadic_count_sum(int count, ...) {
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
// reason as `snakebite_ut_variadic_sum_ints`.
private extern(C) double snakebite_ut_variadic_sum_doubles(
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


private struct VariadicMixedPair {
    int integer;
    double floating;
}


// Reads one `VariadicMixedPair` - one INTEGER lane and one SSE lane in
// the same eightbyte pair - as its one extra, variadic argument.
private extern(C) long snakebite_ut_variadic_mixed_pair(int tag, ...) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, tag);
    auto pair = va_arg!VariadicMixedPair(args);
    va_end(args);
    return tag * 1_000_000L + pair.integer * 1000 + cast(long) pair.floating;
}


// One call site's own callee and extra, variadic argument types - the
// same information a backend reads off the very same `CallExp`
// (`Evaluator.callVariadicNative`, the bytecode compiler's
// `compileNativeCall`) to build its own plan through `PlanCache.
// variadicOf`.
private struct VariadicCallSite {
    FuncDeclaration function_;
    Type[] extraArgumentTypes;
}


// The one `return` statement anywhere in `statement`'s own tree - dmd
// nests a multi-statement function body in `CompoundStatement`s of its
// own (a local declaration followed by other statements becomes one
// more nesting level, unlike `atomicOperation`'s single-statement
// callee above, whose body is already flat), so finding the `return`
// that answers a variadic call site needs a walk, not a fixed index.
private ReturnStatement returnStatementIn(
    Statement statement,
) {
    if (auto compound = statement.isCompoundStatement) {
        foreach (inner; *compound.statements)
            if (auto found = returnStatementIn(inner))
                return found;
        return null;
    }
    return statement.isReturnStatement;
}


// `wrapper`'s body may set up its arguments in whatever statements it
// needs, as long as exactly one of them, anywhere in its own nesting, is
// `return <call>;` (`returnStatementIn`'s own doc) - unlike
// `atomicOperation` above, whose one-statement callee never needs a
// local to build a struct or `float` argument first.
private VariadicCallSite variadicCallSiteOf(FuncDeclaration wrapper) {
    auto return_ = returnStatementIn(wrapper.fbody);
    assert(return_ !is null,
        "Expected `" ~ wrapper.toString ~ "` to return the call");
    auto call = return_.exp.isCallExp;
    assert(call !is null && call.f !is null,
        "Expected a resolved call in `" ~ wrapper.toString ~ "`");

    // An `extern(D)` untyped variadic call site (issue #334 step 6) has
    // one more leading argument than its declaration's own parameter
    // count: the frontend's own `_arguments` (`isDstyleVariadic`'s own
    // doc), ahead of every declared parameter. The extra, variadic
    // arguments this call site's own plan needs start past that, not
    // past the declared parameter count alone.
    auto calleeType = call.f.type.isTypeFunction;
    const declaredOffset = calleeType.isDstyleVariadic ? 1 : 0;
    const declaredCount = declaredOffset + calleeType.parameterList.length;
    Type[] extraTypes;
    foreach (i; declaredCount .. call.arguments.length)
        extraTypes ~= (*call.arguments)[i].type;

    return VariadicCallSite(call.f, extraTypes);
}


private VariadicCallSite variadicCallSite(string source, string wrapperName) {
    auto guestModule = parseSnippet(source);
    auto wrapper = findFunction(guestModule, wrapperName);
    assert(wrapper !is null,
        "No function `" ~ wrapperName ~ "` in the guest program");
    return variadicCallSiteOf(wrapper);
}


@("called.variadic.tenIntsFourSpillToTheStack")
unittest {
    auto site = variadicCallSite(q{
        pragma(mangle, "snakebite_ut_variadic_sum_ints")
        extern(C) int nativeSum(int first, ...);

        int answer() {
            return nativeSum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        }
    }, "answer");

    PlanCache cache;
    int[10] values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    void*[10] arguments;
    foreach (i, ref value; values)
        arguments[i] = &value;

    int result;
    cache.variadicOf(site.function_, site.extraArgumentTypes)
        .call(&result, arguments[]);

    // 1 (`first`, unweighted) + sum((i + 1) * (i + 2)) for i in 0 .. 9,
    // the values 2 .. 10 at positions 0 .. 8 of the weighted sum
    // `snakebite_ut_variadic_sum_ints` computes.
    result.should == 331;
}


@("called.variadic.nineDoublesOneSpills")
unittest {
    auto site = variadicCallSite(q{
        pragma(mangle, "snakebite_ut_variadic_sum_doubles")
        extern(C) double nativeSum(double first, ...);

        double answer() {
            return nativeSum(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
        }
    }, "answer");

    PlanCache cache;
    double[9] values = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0];
    void*[9] arguments;
    foreach (i, ref value; values)
        arguments[i] = &value;

    double result;
    cache.variadicOf(site.function_, site.extraArgumentTypes)
        .call(&result, arguments[]);

    // 1.0 (`first`, unweighted) + sum((i + 1) * (i + 2)) for i in 0 .. 8,
    // the values 2.0 .. 9.0 at positions 0 .. 7 of the weighted sum
    // `snakebite_ut_variadic_sum_doubles` computes.
    result.should == 241.0;
}


// A `float` local widens to `double` before it ever reaches this plan -
// dmd's own C default argument promotion, applied during semantic
// analysis of the call, wraps it in an implicit `cast(double)` (verified
// against dmd directly: `-vcg-ast` on this exact shape shows `cast
// (double)x` in the lowered call). `site.extraArgumentTypes` already
// reads `double`, not `float`, so the classification this plan uses
// (`ArgumentPlan.of`) never even sees the narrower type.
@("called.variadic.floatLiteralPromotedToDouble")
unittest {
    auto site = variadicCallSite(q{
        pragma(mangle, "snakebite_ut_variadic_sum_doubles")
        extern(C) double nativeSum(double first, ...);

        double answer() {
            float second = 2.0f;
            return nativeSum(1.0, second, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
        }
    }, "answer");

    site.extraArgumentTypes[0].toString.should == "double";

    PlanCache cache;
    double[9] values = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0];
    void*[9] arguments;
    foreach (i, ref value; values)
        arguments[i] = &value;

    double result;
    cache.variadicOf(site.function_, site.extraArgumentTypes)
        .call(&result, arguments[]);

    // Same weighted total as `called.variadic.nineDoublesOneSpills`: the
    // promoted `float` carries the same value, at the same position.
    result.should == 241.0;
}


// One extra argument classifies to a mixed INTEGER/SSE eightbyte pair
// (issue #334 step 4's own shape), here reached through a variadic call
// site instead of a named parameter.
@("called.variadic.mixedIntegerSSEStructArgument")
unittest {
    auto site = variadicCallSite(q{
        struct VariadicMixedPair {
            int integer;
            double floating;
        }

        pragma(mangle, "snakebite_ut_variadic_mixed_pair")
        extern(C) long nativeMixedPair(int tag, ...);

        long answer() {
            VariadicMixedPair value;
            value.integer = 7;
            value.floating = 2.5;
            return nativeMixedPair(3, value);
        }
    }, "answer");

    PlanCache cache;
    int tag = 3;
    VariadicMixedPair value = VariadicMixedPair(7, 2.5);
    long result;
    cache.variadicOf(site.function_, site.extraArgumentTypes).call(&result, [
        cast(const void*) &tag, cast(const void*) &value,
    ]);

    result.should == 3_007_002;
}


// The same callee, `snakebite_ut_variadic_count_sum`, at two call
// sites that pass a different number of extra arguments - one plan per
// call site (`VariadicCallSite`'s own doc), never one plan shared by
// declaration the way `PlanCache._plans` shares an ordinary plan.
// `cache.preparations` only counts calls to `variadicOf` - `PlanCache`
// itself never caches a variadic call site's plan (that is a backend's
// own call-site cache, exercised by `ut.backends.call.ffi`'s matrix
// test of the same name), so `== 2` is true simply because this test
// calls `variadicOf` twice, not proof the two plans differ. What
// actually proves each call site got its own, correctly shaped plan is
// `resultOne`/`resultThree` below: a plan built for the wrong extra
// argument count would misclassify `valuesThree`'s three extras against
// the other site's one-extra shape and read back the wrong weighted
// sum.
@("called.variadic.sameCalleeTwoCallSitesDifferentArgumentCounts")
unittest {
    auto guestModule = parseSnippet(q{
        pragma(mangle, "snakebite_ut_variadic_count_sum")
        extern(C) int nativeCountSum(int count, ...);

        int callWithOne() {
            return nativeCountSum(1, 41);
        }

        int callWithThree() {
            return nativeCountSum(3, 1, 2, 3);
        }
    });

    auto oneWrapper = findFunction(guestModule, "callWithOne");
    auto threeWrapper = findFunction(guestModule, "callWithThree");
    assert(oneWrapper !is null && threeWrapper !is null,
        "No `callWithOne`/`callWithThree` in the guest program");

    auto siteOne = variadicCallSiteOf(oneWrapper);
    auto siteThree = variadicCallSiteOf(threeWrapper);

    PlanCache cache;

    int countOne = 1;
    int valueOne = 41;
    int resultOne;
    cache.variadicOf(siteOne.function_, siteOne.extraArgumentTypes).call(
        &resultOne,
        [cast(const void*) &countOne, cast(const void*) &valueOne],
    );

    int countThree = 3;
    int[3] valuesThree = [1, 2, 3];
    int resultThree;
    cache.variadicOf(siteThree.function_, siteThree.extraArgumentTypes).call(
        &resultThree,
        [
            cast(const void*) &countThree,
            cast(const void*) &valuesThree[0],
            cast(const void*) &valuesThree[1],
            cast(const void*) &valuesThree[2],
        ],
    );

    resultOne.should == 41;
    // 1 * 1 + 2 * 2 + 3 * 3, the weighted sum `snakebite_ut_variadic_
    // count_sum` computes.
    resultThree.should == 14;
    cache.preparations.should == 2;
}


// `snprintf` is the real, druntime-declared host function - the same
// callee `ut.ffi.sysv`'s stub-level `variadicCallee.snprintf` drives
// directly, here reached through a full plan instead.
@("called.variadic.snprintf")
unittest {
    auto site = variadicCallSite(q{
        import core.stdc.stdio: snprintf;

        int format(char* buffer, size_t n, int value, double scale) {
            return snprintf(buffer, n, "%d %.1f", value, scale);
        }
    }, "format");

    PlanCache cache;
    char[32] buffer;
    char* bufferPtr = buffer.ptr;
    size_t n = buffer.length;
    immutable(char)[9] format = "%d %.1f\0";
    const(char)* formatPtr = format.ptr;
    int value = 7;
    double scale = 3.5;
    int result;
    cache.variadicOf(site.function_, site.extraArgumentTypes).call(&result, [
        cast(const void*) &bufferPtr,
        cast(const void*) &n,
        cast(const void*) &formatPtr,
        cast(const void*) &value,
        cast(const void*) &scale,
    ]);

    import std.string: fromStringz;

    buffer.ptr.fromStringz.should == "7 3.5";
}


// D's own untyped variadic kind (issue #334 step 6): `extern(D)`
// linkage, `...`. The frontend inserts the call's own `_arguments` - a
// `TypeInfo_Tuple` reference - as a leading argument ahead of every
// declared parameter (`dmd.mtype.TypeFunction.isDstyleVariadic`'s own
// doc; ADR-0010's D variadic paragraph). Every host `extern(D)` variadic
// function's own prologue reads `v_arguments.elements` at entry
// regardless of whether its body ever names `_arguments` (dmd's
// `semantic3.d` declares and initialises both hidden locals whenever
// `f.parameterList.varargs == VarArg.variadic && f.linkage == LINK.d`,
// unconditionally) - so even this plan-level test, which never inspects
// `_arguments` itself, still has to hand the callee a real `TypeInfo_
// Tuple`, never a dummy or null pointer, or the callee's own prologue
// would dereference garbage. `snakebite_ut_dvariadic_count_sum` reads
// its extra arguments through `core.stdc.stdarg` directly, the same way
// the `extern(C)` variadic callees above do - `core.vararg` is the same
// mechanism, re-exported (verified: `core.vararg` is `public import
// core.stdc.stdarg;` plus one `TypeInfo`-driven overload this callee
// does not need) - since only the leading `_arguments` argument and its
// register-assignment position differ from a C-style variadic call, not
// how `_argptr`/`va_arg` work on this ABI.
pragma(mangle, "snakebite_ut_dvariadic_count_sum")
private extern(D) int snakebite_ut_dvariadic_count_sum(int count, ...) {
    import core.stdc.stdarg;

    va_list args;
    va_start(args, count);
    int total;
    foreach (i; 0 .. count)
        total += va_arg!int(args);
    va_end(args);
    return total;
}


// A real `TypeInfo_Tuple` naming `elements` - the shape `v_arguments.
// elements` reads at every `extern(D)` variadic callee's own entry
// (`snakebite_ut_dvariadic_count_sum`'s own doc above).
private TypeInfo_Tuple typeInfoTupleOf(TypeInfo[] elements) {
    auto info = new TypeInfo_Tuple;
    info.elements = elements;
    return info;
}


// Seven `int`s past `count`: six fill the integer register file and the
// seventh spills - but `_arguments` and `count` themselves compete for
// those same six registers too, so this is also the first test to
// exercise `_arguments` actually sharing `CallPlan.buildMoves`'s
// register-assignment loop with the declared parameters and the extra
// arguments - a wrong `hasVArguments` position in `CallPlan.
// prepareCommon` would either crash the real, compiled callee below or
// return the wrong sum, not silently pass.
@("called.variadic.externD.sevenIntsSpillTheIntegerFile")
unittest {
    auto site = variadicCallSite(q{
        pragma(mangle, "snakebite_ut_dvariadic_count_sum")
        extern(D) int nativeCountSum(int count, ...);

        int answer() {
            return nativeCountSum(7, 1, 2, 3, 4, 5, 6, 7);
        }
    }, "answer");

    PlanCache cache;
    TypeInfo[7] elementTypes = [
        typeid(int), typeid(int), typeid(int), typeid(int),
        typeid(int), typeid(int), typeid(int),
    ];
    auto vArguments = typeInfoTupleOf(elementTypes[]);

    int count = 7;
    int[7] values = [1, 2, 3, 4, 5, 6, 7];
    void*[9] arguments;
    arguments[0] = &vArguments;
    arguments[1] = &count;
    foreach (i, ref value; values)
        arguments[2 + i] = &value;

    int result;
    cache.variadicOf(site.function_, site.extraArgumentTypes)
        .call(&result, arguments[]);

    result.should == 28;
}


// The same `extern(D)` untyped variadic callee at two call sites that
// pass a different number of extra arguments - as `called.variadic.
// sameCalleeTwoCallSitesDifferentArgumentCounts` above, but for the D
// kind: one plan per call site, never one plan shared by declaration.
@("called.variadic.externD.sameCalleeTwoCallSitesDifferentArgumentCounts")
unittest {
    auto guestModule = parseSnippet(q{
        pragma(mangle, "snakebite_ut_dvariadic_count_sum")
        extern(D) int nativeCountSum(int count, ...);

        int callWithOne() {
            return nativeCountSum(1, 41);
        }

        int callWithThree() {
            return nativeCountSum(3, 1, 2, 3);
        }
    });

    auto oneWrapper = findFunction(guestModule, "callWithOne");
    auto threeWrapper = findFunction(guestModule, "callWithThree");
    assert(oneWrapper !is null && threeWrapper !is null,
        "No `callWithOne`/`callWithThree` in the guest program");

    auto siteOne = variadicCallSiteOf(oneWrapper);
    auto siteThree = variadicCallSiteOf(threeWrapper);

    PlanCache cache;

    TypeInfo[1] oneElementTypes = [typeid(int)];
    auto vArgumentsOne = typeInfoTupleOf(oneElementTypes[]);
    int countOne = 1;
    int valueOne = 41;
    int resultOne;
    cache.variadicOf(siteOne.function_, siteOne.extraArgumentTypes).call(
        &resultOne,
        [
            cast(const void*) &vArgumentsOne,
            cast(const void*) &countOne,
            cast(const void*) &valueOne,
        ],
    );

    TypeInfo[3] threeElementTypes = [typeid(int), typeid(int), typeid(int)];
    auto vArgumentsThree = typeInfoTupleOf(threeElementTypes[]);
    int countThree = 3;
    int[3] valuesThree = [1, 2, 3];
    int resultThree;
    cache.variadicOf(siteThree.function_, siteThree.extraArgumentTypes).call(
        &resultThree,
        [
            cast(const void*) &vArgumentsThree,
            cast(const void*) &countThree,
            cast(const void*) &valuesThree[0],
            cast(const void*) &valuesThree[1],
            cast(const void*) &valuesThree[2],
        ],
    );

    resultOne.should == 41;
    resultThree.should == 6;
    cache.preparations.should == 2;
}


// D's typesafe variadic kind (`T t...`, `VarArg.typesafe`): the frontend
// packs a call site's trailing arguments into one array-typed argument
// before this plan ever sees them (`snakebite.backends.calls.
// arityMismatches`'s own doc), so it needs no per-call-site plan and no
// `_arguments` - it classifies like any other declared parameter,
// through the ordinary `PlanCache.of`, and is no longer refused
// (`CallPlan.prepareCommon`'s own refusal now names only `VarArg.
// variadic`).
pragma(mangle, "snakebite_ut_dvariadic_typesafe_sum")
private extern(D) int snakebite_ut_dvariadic_typesafe_sum(int[] a...) {
    int total;
    foreach (value; a)
        total += value;
    return total;
}


@("called.variadic.externD.typesafeSlice")
unittest {
    auto guestModule = parseSnippet(q{
        pragma(mangle, "snakebite_ut_dvariadic_typesafe_sum")
        extern(D) int nativeSum(int[] a...);

        int answer() {
            return nativeSum(3, 4, 5);
        }
    });
    auto function_ = findFunction(guestModule, "answer");
    assert(function_ !is null, "No `answer` in the guest program");
    auto call = returnStatementIn(function_.fbody).exp.isCallExp;
    assert(call !is null && call.f !is null,
        "Expected a resolved call in `answer`");

    PlanCache cache;
    int[3] values = [3, 4, 5];
    int[] slice = values[];
    int result;
    cache.of(call.f).call(&result, [cast(const void*) &slice]);

    result.should == 12;
}


// A struct extra argument, alongside a declared pointer parameter: the
// SysV eightbyte classification for both has to agree with what the
// real, compiled callee's own `_argptr`/register-save-area machinery
// expects. `elementTypes` below is `typeid(PlanPoint)` - a real, host-
// compiled `TypeInfo_Struct`, not the fabricated one `snakebite.
// backends.runtimetypes.RuntimeTypes.structInfo`'s own `setSysVArgTypes`
// builds for a *guest*-declared struct - so this plan-level test checks
// only the ABI placement `CallPlan` itself computes, never that
// fabrication; `ut.backends.call.ffi`'s own `variadic.externD.
// guestStructTsizeAndBytes` is what exercises `setSysVArgTypes`, through
// a guest-declared struct, end to end.
pragma(mangle, "snakebite_ut_dvariadic_struct_sum")
private extern(D) int snakebite_ut_dvariadic_struct_sum(
    ubyte* dest, ...
) {
    import core.vararg;

    auto info = _arguments[0];
    va_arg(_argptr, info, dest);
    return 0;
}


private struct PlanPoint {
    int x;
    int y;
}


@("called.variadic.externD.structArgumentPlacement")
unittest {
    auto site = variadicCallSite(q{
        struct GuestPoint {
            int x;
            int y;
        }

        pragma(mangle, "snakebite_ut_dvariadic_struct_sum")
        extern(D) int copyStruct(ubyte* dest, ...);

        int answer() {
            ubyte[8] buffer;
            GuestPoint point;
            point.x = 3;
            point.y = 4;
            return copyStruct(buffer.ptr, point);
        }
    }, "answer");

    PlanCache cache;
    TypeInfo[1] elementTypes = [typeid(PlanPoint)];
    auto vArguments = typeInfoTupleOf(elementTypes[]);

    ubyte[8] destBuffer;
    ubyte* destPtr = destBuffer.ptr;
    PlanPoint point = PlanPoint(3, 4);

    int result;
    cache.variadicOf(site.function_, site.extraArgumentTypes).call(&result, [
        cast(const void*) &vArguments,
        cast(const void*) &destPtr,
        cast(const void*) &point,
    ]);

    (cast(int[]) destBuffer[]).should == [3, 4];
}
