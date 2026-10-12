// Tests belong in bin/ut and run in parallel by default.
// This binary checks ownership across the process-wide frontend arena.
// Its scans need stable contents and hold the frontend lock; their cost
// grows with allocations retained from earlier tests. Some checks also
// plant GC pointers or force collection. A separate serial process keeps
// these checks from blocking the parallel unit-test feedback loop.
// See docs/adr/0015-frontend-memory-uses-an-arena.md.

import snakebite.frontend.compiler: Snippets, arenaReport, initialize;
import std.file: exists, rmdirRecurse;
import std.getopt: defaultGetoptPrinter, getopt;
import std.stdio: stderr;
import unit_threaded.integration: Sandbox;
import unit_threaded.runner.options: Options;
import unit_threaded.runner.reflection: allTestData;
import unit_threaded.runner.runner: runTests;
import ut.backends: prewarmFrontend;
import ut.runner: runUnitTests = run;

int main(string[] args) {
    scope(exit) if (Sandbox.sandboxesPath.exists)
        rmdirRecurse(Sandbox.sandboxesPath);

    auto help = getopt(args); // The help printer requires mutable options.
    if (help.helpWanted) {
        defaultGetoptPrinter(
            "Usage: bin/arena\nRun memory tests, ordinary tests, and a final "
                ~ "arena check on one test worker.",
            help.options,
        );
        return 0;
    }
    if (args.length != 1) {
        stderr.writeln("bin/arena validates the complete test corpus; "
            ~ "it takes no test selectors.");
        return 1;
    }

    initialize(Snippets.yes);
    // Full scans of the memory fixtures need only their own prepared ASTs.
    prewarmFrontend(["arena.memory"]);
    const serialArgs = [args[0], "--single"];
    const memoryStatus = runTests(Options(serialArgs.dup),
        allTestData!("arena.memory"));

    // Reuse the ordinary cases so every frontend path they exercise also
    // contributes to the final ownership check, without copying the corpus.
    const status = memoryStatus | runUnitTests(serialArgs.dup);
    const report = arenaReport;
    if (report.length == 0) {
        stderr.writeln("Complete frontend arena check passed.");
        return status;
    }
    stderr.write(report);
    return status | 1;
}
