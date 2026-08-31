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

private extern(C) ThreeWords snakebite_ut_three_words() {
    return ThreeWords(17, 31, 47);
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


@("refused.tooManyArguments")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) int seven(int a, int b, int c, int d, int e, int f, int g);
    });
    auto function_ = findFunction(guestModule, "seven");
    assert(function_ !is null, "No function `seven` in the guest program");

    PlanCache cache;

    // Refused when the plan is prepared. The interpreter sizes its slot
    // buffer by `maxArguments`, so a call that got past this would fill
    // one slot past the end of that buffer - which is why preparing the
    // plan has to happen before the buffer is filled, not alongside it.
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot call `seven`: it takes 7 arguments, and at most 6"
        ~ " are passed in registers");
}
