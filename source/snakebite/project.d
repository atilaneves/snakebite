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
public Project loadProject(in string directory, SourceSet sources) {
    import snakebite.backends: Program;
    import snakebite.frontend.compiler: FrontendFlags, parseRootModules;
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
        project.sources.sourceOverrides,
        project.directory,
    );
    project.program = Program(parsed, project.name);

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


public string projectStateDirectory(in string projectDirectory) {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.file: getcwd;
    import std.path: absolutePath, buildNormalizedPath, buildPath;

    const absolute = projectDirectory.absolutePath.buildNormalizedPath;
    return buildPath(getcwd, ".snakebite",
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

    return SourceSet(
        files,
        directory ~ importPaths.dup,
        stringImportPaths.dup,
    );
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
    import std.json: JSONType, JSONValue;
    import std.path: buildNormalizedPath, buildPath;

    JSONValue settings;
    foreach (target; description.value["targets"].array)
        if (target["rootPackage"].str == description.value["rootPackage"].str)
            settings = target["buildSettings"];

    const packageSettings = settings.type == JSONType.object;
    if (!packageSettings)
        foreach (package_; description.value["packages"].array)
            if (package_["name"].str == description.value["rootPackage"].str
                    && package_["configuration"].str
                    == description.value["configuration"].str)
                settings = package_;

    string[] values(in string key) {
        if (!packageSettings && key == "linkerFiles")
            return null;
        if (packageSettings || key != "sourceFiles" && key != "importPaths"
                && key != "stringImportPaths")
            return settings[key].array.map!(value => value.str).array;

        string[] result;
        foreach (package_; description.value["packages"].array)
            if (package_["active"].boolean) {
                if (key == "sourceFiles") {
                    if (package_["name"].str
                            != description.value["rootPackage"].str)
                        continue;
                    foreach (file; package_["files"].array)
                        if (file["role"].str == "source")
                            result ~= buildPath(
                                package_["path"].str, file["path"].str);
                } else {
                    result ~= package_[key].array.map!(path => buildPath(
                        package_["path"].str, path.str)).array;
                }
            }
        return result;
    }
    import std.algorithm: endsWith;
    const isLinkerFile = (string path) => path.endsWith(".a", ".o", ".so");
    const files = values("sourceFiles").filter!(path => !isLinkerFile(path)).array;
    // dub names each dependency by the copy it leaves in the package's
    // target path, and whichever compiler built that package last owns the
    // copy (issue #401). The artifact in dub's build cache is keyed by
    // compiler and build settings, so that is what the image links.
    const artifacts = cacheArtifacts(description.value);
    const linkerFiles = (values("linkerFiles")
        ~ values("sourceFiles").filter!(isLinkerFile).array)
        .map!(file => artifacts.get(file.buildNormalizedPath, file))
        .array;
    const dflags = values("dflags");
    const debugVersions = values("debugVersions");
    const options = values("options");
    const importPaths = values("importPaths");
    const stringImportPaths = values("stringImportPaths");
    const lflags = values("lflags");

    if (files.length == 0)
        throw new Exception(text("dub describe found no sources in ", directory));

    string[] compilerArguments = dflags.dup;
    compilerArguments ~= values("versions")
        .map!(version_ => "-version=" ~ version_)
        .array;
    compilerArguments ~= debugVersions
        .map!(debugVersion => "-debug=" ~ debugVersion)
        .array;
    compilerArguments ~= options
        .map!(dmdFlagsForOption)
        .filter!(flag => flag.length > 0)
        .array;

    return SourceSet(
        files.dup,
        importPaths.dup,
        stringImportPaths.dup,
        lflags.map!(flag => "-L" ~ flag).array
            ~ values("libs").map!(library => "-L-l" ~ library).array,
        FrontendFlags(compilerArguments),
        null,
        linkerFiles.dup,
        description,
    );
}


// Each target's build-cache artifact, keyed by the path of the copy dub
// makes of it in the package's target path.
private string[string] cacheArtifacts(in imported!"std.json".JSONValue description) {
    import std.path: baseName, buildNormalizedPath;

    string[string] packagePaths;
    foreach (package_; description["packages"].array)
        packagePaths[package_["name"].str] = package_["path"].str;
    string[string] artifacts;
    foreach (target; description["targets"].array) {
        const artifact = target["cacheArtifactPath"].str;
        const copy = buildNormalizedPath(
            packagePaths[target["rootPackage"].str],
            target["buildSettings"]["targetPath"].str, artifact.baseName);
        artifacts[copy] = artifact;
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


public void prepareDependencies(ref Project project) {
    import snakebite.frontend.dependencyimage: imageSource, imageInputs;
    import snakebite.dependencyimage:
        DependencyImage, ProjectImageCache, prepareImage, defaultCompiler;
    import std.path: buildPath;

    import std.conv: text;
    import std.json: JSONValue;
    import std.process: environment;

    const stateDirectory = projectStateDirectory(project.directory);
    const directory = buildPath(stateDirectory, "images");
    const settings = text(project.sources.flags, project.sources.importPaths,
        project.sources.stringImportPaths, project.sources.linkerFlags,
        project.sources.linkerFiles, JSONValue(project.sources.sourceOverrides),
        project.sources.dubDescription.value, environment.get("DFLAGS", ""),
        environment.get("LFLAGS", ""));
    auto cache = ProjectImageCache(buildPath(directory, "project.json"),
        settings, project.sources.files);
    auto image = new DependencyImage;
    const prepared = cache.prepare(*image,
        () => imageSource(project.program),
        () {
            if (project.sources.linkerFiles.length
                    && isDubProject(project.directory)) {
                import snakebite.dub: buildDubDependencies;

                buildDubDependencies(project.directory, stateDirectory,
                    project.sources.dubDescription, project.sources.linkerFiles);
            }
        },
        source => prepareImage(source, directory, defaultCompiler,
            imageInputs(project.program), project.sources.importPaths,
            project.sources.stringImportPaths,
            project.sources.flags.compilerArguments,
            project.sources.linkerFiles, project.sources.linkerFlags),
        project.sources.linkerFiles.length != 0,
        () {
            import snakebite.dub: dubInputs;

            return imageInputs(project.program) ~ project.sources.linkerFiles
                ~ (isDubProject(project.directory)
                    ? dubInputs(project.directory,
                        project.sources.dubDescription) : null);
        });
    if (prepared) {
        project.program.dependencyImage = image;
    }
}
