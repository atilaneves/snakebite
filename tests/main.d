int main(string[] args) {
    import unit_threaded;
    import snakebite.frontend.compiler: Snippets, initialize;

    initialize(Snippets.yes);

    return args.runTests!(
        "ut.backends.run.main",
        "ut.backends.call.func",
        "ut.backends.call.ffi",
        "ut.backends.eval.expressions.arithmetic",
    );
}
