module snakebite.repl.cli;


private:


// The backends the REPL can select with `-b`/`--backend`.
public enum ReplBackendName {
    interpreter,
    bytecode,
    ctfe,
}


public struct ReplOptions {
    public ReplBackendName backend;
    public bool hasCommand;
    public string command;
    public string[] importPaths;
    public bool showHelp;
    public string[] files;
    public bool liveAfterFiles;
}


public struct ReplCliResult {
    public int status;
    public string diagnostic;
    public ReplOptions options;
}


// Parse the REPL's command line. The default backend is `interpreter`:
// it is the only backend with no compile step, so it starts fastest.
public ReplCliResult parseReplArgs(string[] args) {
    import std.getopt: getopt, GetOptException;

    ReplCliResult result;
    string backendName = "interpreter";

    typeof(getopt(args)) helpInfo;
    try {
        helpInfo = getopt(
            args,
            "c", "Run one D expression and exit.", (string _, string val) {
                result.options.hasCommand = true;
                result.options.command = val;
            },
            "I", "Add an import path.", (string _, string val) {
                result.options.importPaths ~= val;
            },
            "b|backend", "Select the backend (default: interpreter).",
                &backendName,
            "l", "Stay interactive after loading file arguments.",
                &result.options.liveAfterFiles,
        );
    } catch (GetOptException exception) {
        return ReplCliResult(1, exception.msg);
    }

    if (helpInfo.helpWanted) {
        result.options.showHelp = true;
        result.diagnostic = helpText;
        return result;
    }

    if (!parseBackendName(backendName, result.options.backend))
        return ReplCliResult(
            1,
            "unknown backend: " ~ backendName ~ "\n" ~
                "valid backends: " ~ validBackendNames,
        );

    result.options.files = args[1 .. $];

    return result;
}


private enum helpText =
    "Usage: sb-repl [options] [file.d ...]\n" ~
    "\n" ~
    "Options:\n" ~
    "  -c <command>          Run one D expression and exit\n" ~
    "  -I <path>             Add an import path\n" ~
    "  -b, --backend <name>  Select the backend (default: interpreter)\n" ~
    "                        valid: " ~ validBackendNames ~ "\n" ~
    "  -l                    Stay interactive after loading file arguments\n" ~
    "  -h, --help            Show this help\n";


private enum validBackendNames = "interpreter, bytecode, ctfe";


private bool parseBackendName(
    in string input,
    out ReplBackendName backend,
) @safe pure nothrow {
    switch (input) with (ReplBackendName) {
        case "interpreter":
            backend = interpreter;
            return true;
        case "bytecode":
            backend = bytecode;
            return true;
        case "ctfe":
            backend = ctfe;
            return true;
        default:
            return false;
    }
}
