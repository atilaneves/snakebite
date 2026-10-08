module ut.runner;


static import ut.backends.run.main,
    ut.backends.run.addresses,
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
    ut.backends.run.finalizers,
    ut.backends.run.inlineasm,
    ut.backends.run.nativestack,
    ut.backends.run.operators,
    ut.backends.run.staticarrayfromslice,
    ut.backends.run.staticarrays,
    ut.backends.run.stringliterals,
    ut.backends.run.structcopy,
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
    ut.backends.call.intrinsics,
    ut.backends.call.arrayoperations,
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
    ut.backends.threadstate,
    ut.backends.flags,
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
    ut.bench.timing,
    ut.bench.report,
    ut.bench.oracle,
    ut.repl.cli,
    ut.repl.cell,
    ut.repl.session,
    ut.process,
    ut.frontend.functions,
    ut.frontend.memory,
    ut.frontend.checks;

// unit-threaded removes its default sandbox root when a process starts.
// A second test process must not remove this process's active sandboxes.
static this() {
    import unit_threaded.integration: Sandbox;

    Sandbox.setPath(sandboxPath);
}

private string sandboxPath() {
    import core.sys.posix.unistd: getpid;
    import std.conv: text;
    import std.path: buildPath;

    return buildPath("tmp", "snakebite-ut", text(getpid()));
}

import unit_threaded.runner.runner: disableDefaultRunner, runTests;
import unit_threaded.runner.factory: isWantedTest;
import unit_threaded.runner.options: Options;
import unit_threaded.runner.reflection: TestData, allTestData;
import std.algorithm.iteration: filter;
import std.algorithm.searching: canFind;
import std.array: array;
mixin disableDefaultRunner;

// `bin/ut`: prepare the frontend for the selected tests, then run them.
int run(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import ut.backends: prewarmFrontend;
    import std.stdio: writeln;
    import std.file: rmdirRecurse;
    import ut: selectFrontendMemoryFromArguments;

    scope(exit) rmdirRecurse(sandboxPath);
    args = selectFrontendMemoryFromArguments(args);
    const checkArena = args.canFind(checkArenaFlag);
    if (args.canFind("-h") || args.canFind("--help"))
        writeln("  ", checkArenaFlag, ": ", checkArenaHelp);
    args = args.filter!(arg => arg != checkArenaFlag).array;
    initialize(Snippets.yes);

    // Prepare the selected ASTs before any guest test executes. This does
    // not warm the first runtime calls made through forced finalization.
    auto options = Options(args.dup); // The forced pass copies and changes the worker count.
    prewarmFrontend(options.testsToRun);

    const status = runSelectedTests(options, allTestData!(
        "ut.backends.run.main",
        "ut.backends.run.addresses",
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
        "ut.backends.run.finalizers",
        "ut.backends.run.inlineasm",
        "ut.backends.run.nativestack",
        "ut.backends.run.operators",
        "ut.backends.run.staticarrayfromslice",
        "ut.backends.run.staticarrays",
        "ut.backends.run.stringliterals",
        "ut.backends.run.structcopy",
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
        "ut.backends.call.intrinsics",
        "ut.backends.call.arrayoperations",
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
        "ut.backends.threadstate",
        "ut.backends.flags",
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
        "ut.bench.timing",
        "ut.bench.report",
        "ut.bench.oracle",
        "ut.repl.cli",
        "ut.repl.cell",
        "ut.repl.session",
        "ut.process",
        "ut.frontend.functions",
        "ut.frontend.memory",
        "ut.frontend.checks",
    ));
    return checkArena ? status | arenaStatus : status;
}

// A module-local @Serial still shares the heap with other test modules.
// Run forced library-unload scans before starting any guest worker, not
// after a parallel pass whose guest threads could still be ending.
private int runSelectedTests(
    Options options,
    in TestData[] tests,
) {
    if (options.exit)
        return runTests(options, tests);

    const forced = tests.filter!(test =>
        test.tags.canFind("forced-finalizers")
        && isWantedTest(test, options.testsToRun)).array;
    if (forced.length == 0)
        return runTests(options, tests);

    auto serialOptions = options; // The forced pass needs a mutable worker count.
    serialOptions.numThreads = 1;
    const forcedStatus = runTests(serialOptions, forced);
    const remaining = tests.filter!(test =>
        !test.tags.canFind("forced-finalizers")
        && isWantedTest(test, options.testsToRun)).array;
    return remaining.length == 0 ? forcedStatus
        : forcedStatus | runTests(options, remaining);
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
