int main(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import unit_threaded;

    initialize(Snippets.yes);

    return args.runTests!(
        "at.ffi.cost", "at.ffi.dvariadic", "at.bench.timing",
        "at.runtime.arraycopy", "at.ffi.aggregates", "at.runtime.messaging",
        "ut.ffi.symbol", "at.cli", "at.runtime.startup", "at.dub",
        "at.runtime.threads", "at.backends.interpreter.nativestack",
    );
}
