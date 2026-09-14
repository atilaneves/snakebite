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
// unaligned aggregate the ABI classifies as MEMORY regardless of size) is
// refused as an explicit argument until stack memory values have a
// separate call path (`abi.ArgumentPlan.of`'s own doc). `prepare` walks
// every parameter before it ever resolves a symbol (see `prepare`'s own
// body), so this throws before native resolution, and no native
// implementation of `snakebite_ut_memory_param` needs to exist for this
// test.
@("prepare.refusesMemoryClassParameter")
unittest {
    auto guestModule = parseSnippet(q{
        struct ThreeWordStruct {
            size_t first;
            size_t second;
            size_t third;
        }

        extern(C) void snakebite_ut_memory_param(ThreeWordStruct value);
    });
    auto function_ =
        findFunction(guestModule, "snakebite_ut_memory_param");
    assert(function_ !is null,
        "No `snakebite_ut_memory_param` in the guest program");

    PlanCache cache;
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot pass a value of type `ThreeWordStruct`: " ~
            "its ABI class is MEMORY");
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
