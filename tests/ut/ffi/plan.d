module ut.ffi.plan;


import ut;
import snakebite.ffi: PlanCache;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// `abs` declared the way druntime declares it: `extern(C)`, and with no
// body, so nothing but the already-loaded symbol can satisfy a call to it.
private enum declarations = q{
    extern(C) int abs(int);
    extern(C) void free(void*);
};


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

private extern(C) double snakebite_ut_scale(double value) {
    return value * 2.5;
}

private extern(C) int snakebite_ut_seven(
    int a, int b, int c, int d, int e, int f, int g,
) {
    return a + b + c + d + e + f + g;
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
