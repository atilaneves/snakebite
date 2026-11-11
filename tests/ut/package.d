module ut;

public import unit_threaded;
public import snakebite;
public import snakebite.backends.bytecode.vm: JitSetting;

import core.runtime: Runtime;
import snakebite.backends.bytecode: Bytecode;
import snakebite.memory.gc: lowmemHelp, selectFrontendMemory;
import std.algorithm.iteration: filter;
import std.algorithm.searching: canFind;
import std.array: array;
import std.file: exists, thisExePath;
import std.path: buildPath, dirName;
import std.stdio: writeln;


// `--lowmem` for a test runner. unit-threaded's own parser rejects a
// flag it does not know, so the runner takes this one out first, selects
// the frontend memory, and adds the flag to unit-threaded's help.
string[] selectFrontendMemoryFromArguments(string[] args) {
    selectFrontendMemory(args.canFind("--lowmem"));
    if (args.canFind("-h") || args.canFind("--help"))
        writeln("  --lowmem: ", lowmemHelp);
    return args.filter!(arg => arg != "--lowmem").array;
}


// The JIT setting that this run of `bin/ut` gives to every `Bytecode` backend
// that a test makes. It is fixed before any test runs.
public immutable JitSetting testJit;

shared static this() {
    const args = Runtime.args;
    testJit = JitSetting(!args.canFind("--no-jit"), args.canFind("--eager-jit"));
}

// Declares `planStore` and `cache`, a `PlanCache` over a `CallPlanStore` with
// no dependency image, in the scope that mixes it in.
public mixin template planCache() {
    import snakebite.ffi.callplanstore: CallPlanStore;
    import snakebite.ffi: PlanCache;

    CallPlanStore planStore = CallPlanStore(null);
    PlanCache cache = PlanCache(&planStore);
}

// A handle on a new backend of type `B` for `program`. A `Bytecode` backend
// gets the JIT setting of this run of `bin/ut`.
public Owned!B ownedBackend(B)(const Program program) {
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
    if (args.canFind("-h") || args.canFind("--help")) {
        writeln("  --no-jit: Make no JIT code.");
        writeln("  --eager-jit: Make JIT code at the first event of a function.");
    }
    return args.filter!(arg => arg != "--no-jit" && arg != "--eager-jit").array;
}


// A native library that the build of `bin/ut` made from tests/fixtures/native.
// It lies next to the executable, so no test needs a compiler to have it.
string nativeFixture(in string name) {
    const path = buildPath(thisExePath.dirName, "fixtures", name);
    assert(path.exists, "missing " ~ path ~ ": build bin/ut with ninja");
    return path;
}


// Bytes of read-execute mappings this process holds that have no file, or
// that are the callback pool's memory file: what the chunks of callback
// entries occupy, and whatever else maps executable memory without a file.
// It reads the whole process, so another thread that maps executable memory
// changes it: use it only where no such thread runs (`bin/at` runs its tests
// one at a time).
size_t executableChunkBytes() {
    import std.algorithm: canFind;
    import std.conv: to;
    import std.file: readText;
    import std.string: lineSplitter, split;

    size_t total;
    foreach (line; readText("/proc/self/maps").lineSplitter) {
        const fields = line.split;
        if (fields[1][0 .. 3] != "r-x" || (fields.length > 5
                && !fields[5].canFind("snakebite-callbacks")))
            continue;
        const range = fields[0].split("-");
        total += range[1].to!size_t(16) - range[0].to!size_t(16);
    }
    return total;
}
