int main(string[] args) {
    import unit_threaded;
    import snakebite.frontend.compiler: Snippets, initialize;

    initialize(Snippets.yes);

    return args.runTests!(
        "ut.backends.run.main",
        "ut.backends.call.func",
        "ut.backends.call.locals",
        "ut.backends.call.scope_",
        "ut.backends.call.loop",
        "ut.backends.call.compare",
        "ut.backends.call.assign",
        "ut.backends.call.wrap",
        "ut.backends.call.ffi",
        "ut.backends.eval.expressions.arithmetic",
        "ut.ffi.plan",
        "ut.ffi.cost",
        "ut.framestack",
    );
}
