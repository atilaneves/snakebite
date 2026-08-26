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


@("refused.refReturn")
unittest {
    auto guestModule = parseSnippet(q{
        extern(C) ref int refReturner();
    });
    auto function_ = findFunction(guestModule, "refReturner");
    assert(function_ !is null, "No function `refReturner` in the program");

    PlanCache cache;

    // A `ref` return hands back the address of the result, not the
    // result. `nextOf` is the referred-to type either way, so classifying
    // it describes a value that never travels, and writing the return
    // register through that description stores the low bytes of an
    // address as if they were the value - a wrong answer that looks
    // right. Refused when the plan is prepared, before anything runs.
    cache.of(function_).shouldThrowWithMessage(
        "ffi cannot call `refReturner`: it returns by `ref`");
}
