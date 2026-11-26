module at.runner;


// `bin/at`: run the acceptance tests.
int run(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import unit_threaded;
    import ut: selectFrontendMemoryFromArguments;

    args = selectFrontendMemoryFromArguments(args);
    initialize(Snippets.yes);

    return args.runTests!(
        "at.ffi.dvariadic",
        "at.ffi.dabi",
        "at.ffi.image",
        "at.dub",
        "ut.process",
        "ut.backends.call.intrinsics",
        "ut.backends.call.windowtierup",
        "ut.backends.call.arrayoperations",
        "ut.backends.run.hostfrontend",
        "ut.backends.run.inlineasm",
        "at.process",
        "at.stackrelease",
    );
}
