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
