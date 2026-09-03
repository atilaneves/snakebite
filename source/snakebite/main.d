module snakebite.main;


private:


public int main(string[] args) {
    import snakebite.cli: parseArgs;
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project: loadProject;
    import std.stdio: stderr, write;

    const parsed = parseArgs(args);
    if (parsed.diagnostic.length)
        (parsed.status == 0 ? imported!"std.stdio".stdout : stderr)
            .write(parsed.diagnostic);
    if (parsed.status != 0 || parsed.options.showHelp)
        return parsed.status;

    initialize(Snippets.no);

    try {
        auto project = loadProject(
            parsed.options.projectDirectory,
            parsed.options.importPaths,
            parsed.options.stringImportPaths,
        );
        return runBackend(parsed.options.backend, project.program);
    } catch (Exception exception) {
        stderr.write("snakebite: ", exception.msg, "\n");
        return 1;
    }
}


private int runBackend(
    in string name,
    imported!"snakebite.backends".Program program,
) {
    import snakebite.backends.backend: run;

    static foreach (BackendType; imported!"snakebite.backends".Backends) {
        if (name == backendName!BackendType)
            return run(new BackendType(program), program);
    }

    assert(false, "backend name was validated by parseArgs");
}


private enum backendName(BackendType) =
    imported!"std.uni".toLower(BackendType.stringof);
