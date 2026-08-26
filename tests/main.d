int main(string[] args) {
    import unit_threaded;
    import snakebite.frontend.compiler: Snippets, initialize;

    initialize(Snippets.yes);

    return args.runTests!(
        "ut.backends.call.func",
        "ut.backends.eval.expressions.arithmetic",
        "ut.backends.run.main",
    );
}
