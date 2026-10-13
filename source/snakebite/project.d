module snakebite.project;


private:


public import snakebite.sources: SourceSet;
public import snakebite.projectstate: projectStateDirectory;

public struct Project {
    import snakebite.backends: Program;

    public string name;
    public string directory;
    public SourceSet sources;
    public Program program;
}


// Finding the sources (`sourceSet`: `dub describe` for a dub project) and
// running the frontend over them are separate steps so a caller can time
// the second alone; see `snakebite.execution.prepareProject`.
public Project loadProject(
    in string directory,
    SourceSet sources,
    in bool dependencyImage,
) {
    import snakebite.backends: Program;
    import snakebite.frontend.compiler:
        checksOf, FrontendFlags, parseRootModules;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.path: absolutePath, baseName, buildNormalizedPath;

    Project project;
    project.directory = directory.absolutePath.buildNormalizedPath;
    project.name = project.directory.baseName;
    project.sources = sources;

    const flags = FrontendFlags(
        project.sources.flags.compilerArguments
        ~ project.sources.stringImportPaths.map!(path => "-J" ~ path).array,
    );

    auto parsed = parseRootModules(
        project.sources.files,
        project.sources.importPaths,
        flags,
        dependencyImage,
        project.sources.sourceOverrides,
        project.directory,
        project.sources.importedCFilesAreRoots,
    );
    project.program = Program(parsed, project.name, checksOf(flags));

    return project;
}


public SourceSet sourceSet(
    in string directory,
    in string[] importPaths,
    in string[] stringImportPaths,
    in string[] versions = null,
) {
    import std.conv: text;
    import std.file: exists, isDir;
    import std.path: absolutePath, buildNormalizedPath;

    if (!directory.exists || !directory.isDir)
        throw new Exception(text("not a directory: ", directory));

    // Absolute so the import paths derived from it work from any working
    // directory, e.g. as `-I` flags to a subprocess run elsewhere.
    const normalized = directory.absolutePath.buildNormalizedPath;

    if (isDubProject(normalized)) {
        import snakebite.dub: dubSources;
        return dubSources(normalized, versions);
    }

    auto sources = bareSourceSet(normalized, importPaths, stringImportPaths);
    foreach (identifier; versions)
        sources.flags.compilerArguments ~= "-version=" ~ identifier;
    return sources;
}


public bool isDubProject(in string directory) {
    import std.file: exists;
    import std.path: buildPath;

    foreach (recipe; ["dub.sdl", "dub.json"])
        if (buildPath(directory, recipe).exists)
            return true;

    return false;
}


// Whether the process ends when the guest returns.
public enum EndsProcess { no, yes }


// The frontend runs in the project directory, where dub builds. The guest
// runs in the working directory, where `dub test` runs it; `enterWorking`
// goes there, and goes there again after a guest has left it. The destructor
// goes back to where the host was, unless the process ends with the guest: its
// module destructors then run after the guest returns and see the directory
// that its constructors and `main` saw.
public struct ProjectDirectory {
    private string _project;
    private string _working;
    private string _previous;
    private EndsProcess _endsProcess;

    @disable this(this);

    this(
        in string project,
        in string working,
        in EndsProcess endsProcess,
    ) {
        import std.file: chdir, getcwd;

        _project = project;
        _working = working;
        _previous = getcwd;
        _endsProcess = endsProcess;
        chdir(_project);
    }

    void enterWorking() const {
        import std.file: chdir;

        chdir(_working);
    }

    ~this() {
        import std.file: chdir;

        if (_endsProcess == EndsProcess.no)
            chdir(_previous);
    }
}


private SourceSet bareSourceSet(
    in string directory,
    in string[] importPaths,
    in string[] stringImportPaths,
) {
    import std.algorithm.iteration: map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.conv: text;
    import std.file: SpanMode, dirEntries;

    auto files = dirEntries(directory, "*.d", SpanMode.depth)
        .map!(entry => entry.name)
        .array
        .sort
        .release;

    if (files.length == 0)
        throw new Exception(text("no D source files under ", directory));

    auto sources = SourceSet(
        files,
        directory ~ importPaths.dup,
        stringImportPaths.dup,
    );
    sources.importedCFilesAreRoots = true;
    return sources;
}
