module ut;

public import unit_threaded;
public import snakebite;
public import snakebite.backends.bytecode.vm: JitSetting;


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


// The JIT setting that this run of `bin/ut` gives to every `Bytecode` backend
// that a test makes. It is fixed before any test runs.
public immutable JitSetting testJit;

shared static this() {
    import core.runtime: Runtime;
    import std.algorithm.searching: canFind;

    const args = Runtime.args;
    testJit = JitSetting(!args.canFind("--no-jit"), args.canFind("--eager-jit"));
}

// A handle on a new backend of type `B` for `program`. A `Bytecode` backend
// gets the JIT setting of this run of `bin/ut`.
public imported!"snakebite.backends.backend".Owned!B ownedBackend(B)(
    const imported!"snakebite.backends.backend".Program program,
) {
    import snakebite.backends.backend: Owned;
    import snakebite.backends.bytecode: Bytecode;

    static if (is(B == Bytecode))
        return Owned!B(new Bytecode(program, testJit));
    else
        return Owned!B(program);
}

// `--no-jit` and `--eager-jit` for a test runner, which set `testJit`, taken
// out before unit-threaded parses the rest. By default the JIT is on and a function gets
// JIT code after `jitThreshold` events. `--no-jit` makes no JIT code, and
// `--eager-jit` makes JIT code at the first event of every function, so that
// the tests run mostly on JIT code.
string[] selectJitFromArguments(string[] args) {
    import std.algorithm.iteration: filter;
    import std.algorithm.searching: canFind;
    import std.array: array;
    import std.stdio: writeln;

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
