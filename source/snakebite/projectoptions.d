module snakebite.projectoptions;


private:


// The options that `bin/sb` and `bin/bench` both take to describe the
// project to run.
public struct ProjectOptions {
    public string[] importPaths;       // bare directories only; dub knows its own
    public string[] stringImportPaths; // ditto
    public string[] versions;
    public bool lowmem;
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
    import snakebite.gc: lowmemHelp;
    import std.algorithm.searching: countUntil;
    import std.getopt: getopt;

    const separator = args.countUntil("--");
    if (separator >= 0) {
        options.programArguments = args[separator + 1 .. $].dup;
        args = args[0 .. separator];
    }

    return getopt(
        args,
        "I|import-path", "Add an import path for a bare directory.",
            &options.importPaths,
        "J|string-import-path", "Add a string import path for a bare directory.",
            &options.stringImportPaths,
        "version", "Define a version identifier (repeatable).",
            &options.versions,
        "lowmem", lowmemHelp, &options.lowmem,
        own,
    );
}
