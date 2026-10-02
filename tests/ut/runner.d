module ut.runner;


static import ut.backends.run.main,
    ut.backends.run.arrays,
    ut.backends.run.associative,
    ut.backends.run.classes,
    ut.backends.run.cpp_classes,
    ut.backends.run.constructor_variadic,
    ut.backends.run.control,
    ut.backends.run.declarations,
    ut.backends.run.delegates,
    ut.backends.run.enums,
    ut.backends.run.exceptions,
    ut.backends.run.inlineasm,
    ut.backends.run.nativestack,
    ut.backends.run.operators,
    ut.backends.run.staticarrays,
    ut.backends.run.structs,
    ut.backends.run.templates,
    ut.backends.run.virtual_variadic,
    ut.backends.call.func,
    ut.backends.call.locals,
    ut.backends.call.scope_,
    ut.backends.call.loop,
    ut.backends.call.compare,
    ut.backends.call.arithmetic,
    ut.backends.call.shifts,
    ut.backends.call.compoundconversion,
    ut.backends.call.floatingtointegral,
    ut.backends.call.assign,
    ut.backends.call.cast_,
    ut.backends.call.discard,
    ut.backends.call.pointers,
    ut.backends.call.ref_,
    ut.backends.call.wrap,
    ut.backends.call.ffi,
    ut.backends.call.routing,
    ut.backends.call.arrays,
    ut.backends.call.rtPerf,
    ut.backends.call.aa,
    ut.backends.call.nested,
    ut.backends.call.control_flow,
    ut.backends.call.exceptions,
    ut.backends.call.invariant_,
    ut.backends.eval.expressions.arithmetic,
    ut.backends.interpreter.cost,
    ut.backends.interpreter.classes,
    ut.backends.interpreter.nativestack,
    ut.backends.interpreter.concurrency,
    ut.backends.bytecode.concurrency,
    ut.backends.concurrency,
    ut.backends.bytecode.vm,
    ut.backends.aggregateinit,
    ut.backends.casts,
    ut.backends.staticchain,
    ut.backends.layout,
    ut.backends.program,
    ut.backends.guestfault,
    ut.faultsignal,
    ut.ffi.call,
    ut.ffi.callback,
    ut.ffi.aggregates,
    ut.ffi.concurrency,
    ut.ffi.cpp,
    ut.ffi.plan,
    ut.ffi.symbol,
    ut.ffi.sysv,
    ut.framestack,
    ut.cli,
    ut.project,
    ut.dub,
    ut.importc,
    ut.bench.timing,
    ut.bench.report,
    ut.bench.oracle,
    ut.repl.cli,
    ut.repl.cell,
    ut.repl.session,
    ut.process,
    ut.frontend.memory;

// `bin/ut`: prepare the frontend for the selected tests, then run them.
int run(string[] args) {
    import unit_threaded;
    import snakebite.frontend.compiler: Snippets, initialize;
    import ut.backends: prewarmFrontend;
    import unit_threaded.runner.options: Options;
    import std.algorithm.iteration: filter;
    import std.algorithm.searching: canFind;
    import std.array: array;
    import std.stdio: writeln;
    import ut: selectFrontendMemoryFromArguments;

    args = selectFrontendMemoryFromArguments(args);
    const checkArena = args.canFind(checkArenaFlag);
    if (args.canFind("-h") || args.canFind("--help"))
        writeln("  ", checkArenaFlag, ": ", checkArenaHelp);
    args = args.filter!(arg => arg != checkArenaFlag).array;
    initialize(Snippets.yes);

    // Parse every snippet/program the selected tests need in one serial
    // pass, before unit-threaded's own worker threads start. `args.dup`
    // keeps `args` itself untouched: `Options`'s constructor strips
    // recognised flags in place (getopt), and `runTests!(...)` below
    // still needs the full, unstripped `args`.
    prewarmFrontend(Options(args.dup).testsToRun);

    const status = args.runTests!(
        "ut.backends.run.main",
        "ut.backends.run.arrays",
        "ut.backends.run.associative",
        "ut.backends.run.classes",
        "ut.backends.run.cpp_classes",
        "ut.backends.run.constructor_variadic",
        "ut.backends.run.control",
        "ut.backends.run.declarations",
        "ut.backends.run.delegates",
        "ut.backends.run.enums",
        "ut.backends.run.exceptions",
        "ut.backends.run.inlineasm",
        "ut.backends.run.nativestack",
        "ut.backends.run.operators",
        "ut.backends.run.staticarrays",
        "ut.backends.run.structs",
        "ut.backends.run.templates",
        "ut.backends.run.virtual_variadic",
        "ut.backends.call.func",
        "ut.backends.call.locals",
        "ut.backends.call.scope_",
        "ut.backends.call.loop",
        "ut.backends.call.compare",
        "ut.backends.call.arithmetic",
        "ut.backends.call.shifts",
        "ut.backends.call.compoundconversion",
        "ut.backends.call.floatingtointegral",
        "ut.backends.call.assign",
        "ut.backends.call.cast_",
        "ut.backends.call.discard",
        "ut.backends.call.pointers",
        "ut.backends.call.ref_",
        "ut.backends.call.wrap",
        "ut.backends.call.ffi",
        "ut.backends.call.routing",
        "ut.backends.call.arrays",
        "ut.backends.call.rtPerf",
        "ut.backends.call.aa",
        "ut.backends.call.nested",
        "ut.backends.call.control_flow",
        "ut.backends.call.exceptions",
        "ut.backends.call.invariant_",
        "ut.backends.eval.expressions.arithmetic",
        "ut.backends.interpreter.cost",
        "ut.backends.interpreter.classes",
        "ut.backends.interpreter.nativestack",
        "ut.backends.interpreter.concurrency",
        "ut.backends.bytecode.concurrency",
        "ut.backends.concurrency",
        "ut.backends.bytecode.vm",
        "ut.backends.aggregateinit",
        "ut.backends.casts",
        "ut.backends.staticchain",
        "ut.backends.layout",
        "ut.backends.program",
        "ut.backends.guestfault",
        "ut.faultsignal",
        "ut.ffi.call",
        "ut.ffi.callback",
        "ut.ffi.aggregates",
        "ut.ffi.concurrency",
        "ut.ffi.cpp",
        "ut.ffi.plan",
        "ut.ffi.symbol",
        "ut.ffi.sysv",
        "ut.framestack",
        "ut.cli",
        "ut.project",
        "ut.dub",
        "ut.importc",
        "ut.bench.timing",
        "ut.bench.report",
        "ut.bench.oracle",
        "ut.repl.cli",
        "ut.repl.cell",
        "ut.repl.session",
        "ut.process",
        "ut.frontend.memory",
    );
    return checkArena ? status | arenaStatus : status;
}

private enum checkArenaFlag = "--check-arena";
private enum checkArenaHelp =
    "After the tests, fail if an arena word points into the GC heap "
    ~ "(debug builds; run with --DRT-gcopt=disable:1 so no block it points "
    ~ "to is freed first).";

// Every test has run, so the arena holds everything they made the
// frontend keep: no word of it may point into the GC heap.
private int arenaStatus() {
    import snakebite.frontend.compiler: arenaReport;
    import std.stdio: stderr;

    const report = arenaReport;
    if (report.length == 0)
        return 0;
    stderr.write(report);
    return 1;
}
