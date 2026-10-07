module at.runner;


// `bin/at`: run the acceptance tests.
int run(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import unit_threaded;
    import ut: selectFrontendMemoryFromArguments;

    args = selectFrontendMemoryFromArguments(args);
    initialize(Snippets.yes);

    return args.runTests!(
        "at.ffi.dvariadic", "at.ffi.dabi", "at.ffi.image",
        "at.bench.timing",
        "at.runtime.arraycopy", "at.runtime.messaging",
        "at.cli", "at.runtime.startup", "at.dub",
        "at.runtime.threads", "at.runtime.registration",
        "at.backends.interpreter.nativestack",
        "ut.process", "ut.backends.call.intrinsics", "at.process",
        "at.stackrelease",
        "at.runtime.faultregistration",
    );
}
