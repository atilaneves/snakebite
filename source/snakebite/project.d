module snakebite.project;


private:


public struct SourceSet {
    public string[] files;
    public string[] importPaths;
    public string[] stringImportPaths;
    public string[] linkerFlags;
    public imported!"snakebite.frontend.compiler".FrontendFlags flags;
    public string[string] sourceOverrides;
    public string[] linkerFiles;
    public imported!"snakebite.dub".DubDescription dubDescription;
}


public struct Project {
    public string name;
    public string directory;
    public SourceSet sources;
    public imported!"snakebite.backends".Program program;
    private imported!"std.typecons".RefCounted!(
        imported!"snakebite.dependencyimage".DependencyImage) _image;
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
    );
    project.program = Program(parsed, project.name);

    return project;
}


public SourceSet sourceSet(
    in string directory,
    in string[] importPaths,
    in string[] stringImportPaths,
) {
    import std.conv: text;
    import std.file: exists, isDir;
    import std.path: absolutePath, buildNormalizedPath;

    if (!directory.exists || !directory.isDir)
        throw new Exception(text("not a directory: ", directory));

    // Absolute so the import paths derived from it work from any working
    // directory, e.g. as `-I` flags to a subprocess run elsewhere.
    const normalized = directory.absolutePath.buildNormalizedPath;

    return isDubProject(normalized)
        ? dubSourceSet(normalized)
        : bareSourceSet(normalized, importPaths, stringImportPaths);
}


public bool isDubProject(in string directory) {
    import std.file: exists;
    import std.path: buildPath;

    foreach (recipe; ["dub.sdl", "dub.json"])
        if (buildPath(directory, recipe).exists)
            return true;

    return false;
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


private SourceSet dubSourceSet(in string directory) {
    import snakebite.dub: dubDescribeProject;
    import snakebite.frontend.compiler: FrontendFlags;
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.conv: text;
    import std.file: readText;

    auto description = dubDescribeProject(directory); // Stored in the mutable SourceSet.
    import std.json: JSONValue;
    JSONValue settings;
    foreach (target; description.value["targets"].array)
        if (target["rootPackage"].str == description.value["rootPackage"].str)
            settings = target["buildSettings"];

    string[] values(in string key) {
        return settings[key].array.map!(value => value.str).array;
    }
    import std.algorithm: endsWith;
    const isLinkerFile = (string path) => path.endsWith(".a", ".o", ".so");
    const files = values("sourceFiles").filter!(path => !isLinkerFile(path)).array;
    const linkerFiles = values("linkerFiles")
        ~ values("sourceFiles").filter!(isLinkerFile).array;
    const dflags = values("dflags");
    const versions = values("versions");
    const debugVersions = values("debugVersions");
    const options = values("options");
    const importPaths = values("importPaths");
    const stringImportPaths = values("stringImportPaths");
    const lflags = values("lflags");

    if (files.length == 0)
        throw new Exception(text("dub describe found no sources in ", directory));

    string[] compilerArguments = dflags.dup;
    compilerArguments ~= versions
        .map!(version_ => "-version=" ~ version_)
        .array;
    compilerArguments ~= debugVersions
        .map!(debugVersion => "-debug=" ~ debugVersion)
        .array;
    compilerArguments ~= options
        .map!(dmdFlagsForOption)
        .filter!(flag => flag.length > 0)
        .array;

    string[string] sourceOverrides;
    foreach (file; files)
        if (isGeneratedTestRoot(file))
            sourceOverrides[file] = noIoTestRoot(file.readText);

    return SourceSet(
        files.dup,
        importPaths.dup,
        stringImportPaths.dup,
        lflags.map!(flag => "-L" ~ flag).array
            ~ values("libs").map!(library => "-L-l" ~ library).array,
        FrontendFlags(compilerArguments),
        sourceOverrides,
        linkerFiles.dup,
        description,
    );
}


private bool isGeneratedTestRoot(in string path) @safe pure {
    import std.path: baseName;

    return path.baseName == "dub_test_root.d";
}


private string noIoTestRoot(in string source) @safe pure {
    import std.algorithm.searching: skipOver;
    import std.string: indexOf, stripLeft;

    const runner = source.indexOf("version(D_BetterC)");
    if (runner < 0
        || source[0 .. runner].indexOf("module dub_test_root;") < 0
        || source[0 .. runner].indexOf("alias allModules") < 0)
        throw new Exception("Dub generated an unknown test root");

    auto remainder = source[runner .. $];
    if (!remainder.skipOver("version(D_BetterC)"))
        throw new Exception("Dub generated an unknown test root");
    remainder = remainder.stripLeft;
    remainder = afterBlock(remainder);
    remainder = remainder.stripLeft;
    if (!remainder.skipOver("else"))
        throw new Exception("Dub generated an unknown test root");
    remainder = remainder.stripLeft;
    remainder = afterBlock(remainder);
    if (remainder.stripLeft.length != 0)
        throw new Exception("Dub generated an unknown test root");

    return source[0 .. runner] ~ q{
int main() {
    foreach (module_; allModules)
        foreach (test; __traits(getUnitTests, module_))
            test();

    return 0;
}
};
}


private string afterBlock(in string source) @safe pure {
    if (source.length == 0 || source[0] != '{')
        throw new Exception("Dub generated an unknown test root");

    size_t depth;
    foreach (index, character; source) {
        if (character == '{')
            ++depth;
        else if (character == '}' && --depth == 0)
            return source[index + 1 .. $];
    }

    throw new Exception("Dub generated an unknown test root");
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
    import snakebite.dependencyimage: ProjectImageCache, prepareImage, defaultCompiler;
    import std.path: buildPath;

    import std.conv: text;
    import std.json: JSONValue;
    import std.process: environment;

    const directory = buildPath(project.directory, ".snakebite", "images");
    const settings = text(project.sources.flags, project.sources.importPaths,
        project.sources.stringImportPaths, project.sources.linkerFlags,
        project.sources.linkerFiles, JSONValue(project.sources.sourceOverrides),
        project.sources.dubDescription.value, environment.get("DFLAGS", ""),
        environment.get("LFLAGS", ""));
    auto cache = ProjectImageCache(directory, settings, project.sources.files);
    string source;
    bool sourcePrepared;
    string generateSource() {
        if (!sourcePrepared) {
            source = imageSource(project.program);
            sourcePrepared = true;
        }
        return source;
    }
    if (cache.restore(project._image.refCountedPayload, &generateSource)) {
        project.program.dependencyImage = &project._image.refCountedPayload();
        return;
    }
    if (project.sources.linkerFiles.length && isDubProject(project.directory)) {
        import snakebite.dub: buildDubDependencies;

        buildDubDependencies(project.directory, project.sources.dubDescription,
            project.sources.linkerFiles);
    }
    generateSource;
    if (!source.length && !project.sources.linkerFiles.length)
        return;
    project._image.refCountedPayload = prepareImage(
        source.length ? source : "module snakebite_dependency_image;\n",
        directory, defaultCompiler,
        imageInputs(project.program), project.sources.importPaths,
        project.sources.stringImportPaths,
        project.sources.flags.compilerArguments,
        project.sources.linkerFiles, project.sources.linkerFlags);
    import snakebite.dub: dubInputs;

    cache.save(project._image.refCountedPayload.path, source,
        imageInputs(project.program) ~ project.sources.linkerFiles
        ~ (isDubProject(project.directory)
            ? dubInputs(project.directory, project.sources.dubDescription) : null));
    project.program.dependencyImage = &project._image.refCountedPayload();
}
