module snakebite.cli;


private:


public struct Options {
    public imported!"snakebite.backends".BackendName backend;
    public string[] importPaths;
    public string[] stringImportPaths;
    public string[] versions;
    public string projectDirectory;
    public string[] programArguments;
    public bool showHelp;
}


public struct CliResult {
    public int status;
    public string diagnostic;
    public Options options;
}


public CliResult parseArgs(string[] args) {
    import snakebite.backends: parseBackendName, validBackendNames;
    import std.algorithm.searching: countUntil, startsWith;
    import std.getopt: getopt, GetOptException;

    CliResult result;
    const separator = args.countUntil("--");
    if (separator >= 0) {
        result.options.programArguments = args[separator + 1 .. $].dup;
        args = args[0 .. separator];
    }
    args = args.dup;
    foreach (ref argument; args[1 .. $])
        if (argument.startsWith("-version="))
            argument = "-" ~ argument;
    string backendName = "bytecode";

    typeof(getopt(args)) helpInfo;
    try {
        helpInfo = getopt(
            args,
            "b|backend", "Select the backend (default: bytecode).",
                &backendName,
            "I|import-path", "Add an import path.",
                &result.options.importPaths,
            "J|string-import-path", "Add a string import path.",
                &result.options.stringImportPaths,
            "version", "Define a version identifier (repeatable).",
                &result.options.versions,
        );
    } catch (GetOptException exception) {
        return CliResult(1, exception.msg);
    }

    if (helpInfo.helpWanted) {
        result.options.showHelp = true;
        result.diagnostic = helpText;
        return result;
    }

    if (args.length != 2)
        return CliResult(1, "expected one project directory\n" ~ helpText);

    result.options.projectDirectory = args[1];
    if (!parseBackendName(backendName, result.options.backend))
        return CliResult(
            1,
            "unknown backend: " ~ backendName ~ "\n" ~
                "valid backends: " ~ validBackendNames,
        );

    return result;
}


private enum helpText =
    "Usage: sb [options] <directory> [-- program arguments...]\n" ~
    "\n" ~
    "Run the D unit tests in a project directory.\n" ~
    "Pass arguments after -- to the program (for example: -- -d).\n" ~
    "\n" ~
    "Options:\n" ~
    "  -b, --backend <name>      Select the backend (default: bytecode)\n" ~
    "                            valid: "
        ~ imported!"snakebite.backends".validBackendNames ~ "\n" ~
    "  -I, --import-path <path>  Add an import path for a bare directory\n" ~
    "  -J, --string-import-path <path>\n" ~
    "                            Add a string import path for a bare directory\n" ~
    "  -version=<identifier>     Define a version identifier (repeatable)\n" ~
    "  -h, --help                Show this help\n";
