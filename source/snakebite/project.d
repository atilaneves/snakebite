module snakebite.project;


private:


public struct SourceSet {
    import snakebite.frontend.compiler: FrontendFlags;
    import snakebite.dub: DubDescription;

    public string[] files;
    public string[] importPaths;
    public string[] stringImportPaths;
    public string[] linkerFlags;
    public FrontendFlags flags;
    public string[string] sourceOverrides;
    public string[] linkerFiles;
    public DubDescription dubDescription;
    // Where `dub test` runs the test binary; empty when the recipe sets no
    // `workingDirectory`, and for a bare directory.
    public string workingDirectory;
    // A bare directory is built as `dmd -i` builds it, which compiles a C
    // module that a D module imports. A dub recipe names its C files in
    // `sourceFiles`, and dub does not compile one that it does not name.
    public bool importedCFilesAreRoots;
}


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

    if (isDubProject(normalized))
        return dubSourceSet(normalized, versions);

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


// Project state lives under the directory snakebite started in. Guest code
// runs in the directory of its project so that it sees the files it expects,
// and that must not move the state with it.
private immutable string _startDirectory;

shared static this() {
    import std.file: getcwd;
    _startDirectory = getcwd;
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


public string projectStateDirectory(in string projectDirectory) {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.path: absolutePath, buildNormalizedPath, buildPath;

    const absolute = projectDirectory.absolutePath.buildNormalizedPath;
    return buildPath(_startDirectory, ".snakebite",
        absolute.sha256Of.toHexString.idup);
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


private SourceSet dubSourceSet(in string directory, in string[] versions) {
    import snakebite.dub: dubDescribeProject;

    return dubSourceSet(directory, dubDescribeProject(directory, versions));
}


version(unittest)
public SourceSet dubSourceSetFromDescription(
    in string directory,
    imported!"snakebite.dub".DubDescription description,
) {
    return dubSourceSet(directory, description);
}


private SourceSet dubSourceSet(
    in string directory,
    imported!"snakebite.dub".DubDescription description,
) {
    import snakebite.frontend.compiler: FrontendFlags;
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.conv: text;
    import dub.compilers.buildsettings: BuildOption, BuildSettings;
    import dub.description: SourceFileRole;
    import snakebite.dub: rootBuildSettings;
    import std.path: buildNormalizedPath, buildPath;
    import std.traits: EnumMembers;

    const project = description.project;
    const packageSettings = project.rootPackage in project.targetLookup;
    BuildSettings settings;
    string[] options;
    if (packageSettings) {
        settings = project.rootBuildSettings;
        static foreach (option; EnumMembers!BuildOption)
            static if (option != BuildOption.none)
                if (settings.options.values & option)
                    options ~= text(option);
    } else {
        foreach (package_; project.packages)
            if (package_.name == project.rootPackage
                    && package_.configuration == project.configuration) {
                settings.dflags = package_.dflags.dup;
                settings.lflags = package_.lflags.dup;
                settings.libs = package_.libs.dup;
                settings.versions = package_.versions.dup;
                settings.debugVersions = package_.debugVersions.dup;
                options = package_.options.map!(option => text(option)).array;
            }
    }

    // Without a target, the files and paths of the active packages are all
    // that dub describes.
    string[] sourceFiles = settings.sourceFiles.dup;
    string[] importPaths = settings.importPaths.dup;
    string[] stringImportPaths = settings.stringImportPaths.dup;
    if (!packageSettings)
        foreach (package_; project.packages) {
            if (!package_.active)
                continue;
            importPaths ~= package_.importPaths.map!(path => buildPath(package_.path, path)).array;
            stringImportPaths ~= package_.stringImportPaths
                .map!(path => buildPath(package_.path, path)).array;
            if (package_.name != project.rootPackage)
                continue;
            foreach (file; package_.files)
                if (file.role == SourceFileRole.source)
                    sourceFiles ~= buildPath(package_.path, file.path);
        }
    import std.algorithm: endsWith;
    const isLinkerFile = (string path) => path.endsWith(".a", ".o", ".so");
    const files = sourceFiles.filter!(path => !isLinkerFile(path)).array;
    // dub names each dependency by the copy it leaves in the package's
    // target path, and whichever compiler built that package last owns the
    // copy (issue #401). The artifact in dub's build cache is keyed by
    // compiler and build settings, so that is what the image links.
    const artifacts = cacheArtifacts(project);
    const linkerFiles = (settings.linkerFiles ~ sourceFiles.filter!(isLinkerFile).array)
        .map!(file => artifacts.get(file.buildNormalizedPath, file))
        .array;

    if (files.length == 0)
        throw new Exception(text("dub describe found no sources in ", directory));

    string[] compilerArguments = settings.dflags.dup;
    compilerArguments ~= settings.versions
        .map!(version_ => "-version=" ~ version_)
        .array;
    compilerArguments ~= settings.debugVersions
        .map!(debugVersion => "-debug=" ~ debugVersion)
        .array;
    compilerArguments ~= options
        .map!(dmdFlagsForOption)
        .filter!(flag => flag.length > 0)
        .array;

    import snakebite.frontend.checks: expandedCompilerArguments;

    auto sources = SourceSet(
        files.dup,
        importPaths.dup,
        stringImportPaths.dup,
        settings.lflags.map!(flag => "-L" ~ flag).array
            ~ settings.libs.map!(library => "-L-l" ~ library).array,
        FrontendFlags(expandedCompilerArguments(compilerArguments)),
        null,
        linkerFiles.dup,
        description,
    );
    // dub describe makes the directory absolute and leaves it empty when
    // the recipe names none.
    sources.workingDirectory = settings.workingDirectory;
    return sources;
}


// Each target's build-cache artifact, keyed by the path of the copy dub
// makes of it in the package's target path.
private string[string] cacheArtifacts(
    in imported!"dub.description".ProjectDescription project,
) {
    import std.path: baseName, buildNormalizedPath;

    string[string] packagePaths;
    foreach (package_; project.packages)
        packagePaths[package_.name] = package_.path;
    string[string] artifacts;
    foreach (target; project.targets) {
        const copy = buildNormalizedPath(
            packagePaths[target.rootPackage],
            target.buildSettings.targetPath, target.cacheArtifactPath.baseName);
        artifacts[copy] = target.cacheArtifactPath;
    }
    return artifacts;
}


private string dmdFlagsForOption(in string option) {
    switch (option) {
        case "debugMode": return "-debug";
        case "releaseMode": return "-release";
        case "coverage": return "-cov";
        case "coverageCTFE": return "-cov=ctfe";
        case "debugInfo": return "-g";
        case "debugInfoC": return "-g";
        case "alwaysStackFrame": return "-gs";
        case "stackStomping": return "-gx";
        case "inline": return "-inline";
        case "noBoundsCheck": return "-noboundscheck";
        case "optimize": return "-O";
        case "profile": return "-profile";
        case "unittests": return "-unittest";
        case "verbose": return "-v";
        case "ignoreUnknownPragmas": return "-ignore";
        case "syntaxOnly": return "-o-";
        case "warnings": return "-wi";
        case "warningsAsErrors": return "-w";
        case "ignoreDeprecations": return "-d";
        case "deprecationWarnings": return "-dw";
        case "deprecationErrors": return "-de";
        case "property": return "-property";
        case "profileGC": return "-profile=gc";
        case "betterC": return "-betterC";
        case "lowmem": return "-lowmem";
        case "color": return "-color";
        default: return null;
    }
}
