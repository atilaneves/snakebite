module ut;

public import unit_threaded;
public import snakebite;


// `--lowmem` for a test runner. unit-threaded's own parser rejects a
// flag it does not know, so the runner takes this one out first, selects
// the frontend memory, and adds the flag to unit-threaded's help.
string[] selectFrontendMemoryFromArguments(string[] args) {
    import snakebite.gc: lowmemHelp, selectFrontendMemory;
    import std.algorithm.iteration: filter;
    import std.algorithm.searching: canFind;
    import std.array: array;
    import std.stdio: writeln;

    selectFrontendMemory(args.canFind("--lowmem"));
    if (args.canFind("-h") || args.canFind("--help"))
        writeln("  --lowmem: ", lowmemHelp);
    return args.filter!(arg => arg != "--lowmem").array;
}


// `--no-jit` and `--eager-jit` for a test runner, taken out before
// unit-threaded parses the rest. By default the JIT is on and a function gets
// JIT code after `jitThreshold` events. `--no-jit` makes no JIT code, and
// `--eager-jit` makes JIT code at the first event of every function, so that
// the tests run mostly on JIT code.
string[] selectJitFromArguments(string[] args) {
    import snakebite.backends.bytecode.vm: jitCompileOnFirstEvent, selectJit;
    import std.algorithm.iteration: filter;
    import std.algorithm.searching: canFind;
    import std.array: array;
    import std.stdio: writeln;

    selectJit(!args.canFind("--no-jit"));
    jitCompileOnFirstEvent(args.canFind("--eager-jit"));
    if (args.canFind("-h") || args.canFind("--help")) {
        writeln("  --no-jit: Make no JIT code.");
        writeln("  --eager-jit: Make JIT code at the first event of a function.");
    }
    return args.filter!(arg => arg != "--no-jit" && arg != "--eager-jit").array;
}


// A native library that the build of `bin/ut` made from tests/fixtures/native.
// It lies next to the executable, so no test needs a compiler to have it.
string nativeFixture(in string name) {
    import std.file: exists, thisExePath;
    import std.path: buildPath, dirName;

    const path = buildPath(thisExePath.dirName, "fixtures", name);
    assert(path.exists, "missing " ~ path ~ ": build bin/ut with ninja");
    return path;
}
