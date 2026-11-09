module snakebite.projectoptions;


private:


// What `--no-jit` does, for the help of every tool that takes it.
public enum noJitHelp =
    "Run the bytecode backend's handlers only; make no JIT code.";

// The options that `bin/sb` and `bin/bench` both take to describe the
// project to run.
public struct ProjectOptions {
    public string[] importPaths;       // bare directories only; dub knows its own
    public string[] stringImportPaths; // ditto
    public string[] versions;
    public bool lowmem;
    public bool noJit;
    // What follows `--` on the command line: the arguments of the program.
    public string[] programArguments;
}


// Splits `args` at the first `--` and parses the project options from what
// precedes it. `own` are the `getopt` arguments of the calling tool, parsed
// in the same pass so that `--help` lists every option together. On return
// `args` holds what no option consumed.
public auto parseProjectOptions(Own...)(
    ref string[] args,
    ref ProjectOptions options,
    Own own,
) {
    import std.algorithm.searching: countUntil;

    const separator = args.countUntil("--");
    if (separator >= 0) {
        options.programArguments = args[separator + 1 .. $].dup;
        args = args[0 .. separator];
    }

    return parseCommonOptions(
        args,
        options.importPaths,
        options.versions,
        options.lowmem,
        options.noJit,
        "J|string-import-path", "Add a string import path for a bare directory.",
            &options.stringImportPaths,
        own,
    );
}


// Registers the options that `bin/sb`, `bin/sb-repl` and `bin/bench` all
// take, together with `own`, and parses `args`.
public auto parseCommonOptions(Own...)(
    ref string[] args,
    ref string[] importPaths,
    ref string[] versions,
    ref bool lowmem,
    ref bool noJit,
    Own own,
) {
    import snakebite.gc: lowmemHelp;
    import std.getopt: getopt;

    return getopt(
        args,
        "I|import-path", "Add an import path for a bare directory.",
            &importPaths,
        "version", "Define a version identifier (repeatable).", &versions,
        "lowmem", lowmemHelp, &lowmem,
        "no-jit", noJitHelp, &noJit,
        own,
    );
}


// The `getopt` arguments of `-b|--backend`, for the tools that select a
// backend. Expand them into the call: `backendOption(name).expand`.
public auto backendOption(ref string name) {
    import std.typecons: tuple;

    return tuple("b|backend", "Select the backend (default: bytecode).", &name);
}
