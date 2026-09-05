module snakebite.project;


private:


public struct SourceSet {
    public string[] files;
    public string[] importPaths;
    public string[] stringImportPaths;
    public string[] linkerFlags;
    public imported!"snakebite.frontend.compiler".FrontendFlags flags;
    public string[string] sourceOverrides;
}


public struct Project {
    public string name;
    public string directory;
    public SourceSet sources;
    public imported!"snakebite.backends".Program program;
}


public Project loadProject(
    in string directory,
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
) {
    return loadProject(
        directory,
        sourceSet(directory, importPaths, stringImportPaths),
    );
}


// Finding the sources (`dub describe` for a dub project) and running the
// frontend over them are separate steps so a caller can time the second
// alone; see `snakebite.execution.prepareProject`.
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
    project.program = Program(parsed);

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
    import snakebite.dub: DubConfig, dubDescribe;
    import snakebite.frontend.compiler: FrontendFlags;
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.conv: text;
    import std.file: readText;

    auto files = dubDescribe(directory, "source-files", DubConfig.test);
    if (files.length == 0)
        throw new Exception(text("dub describe found no sources in ", directory));

    string[] compilerArguments =
        dubDescribe(directory, "dflags", DubConfig.test);
    compilerArguments ~= dubDescribe(directory, "versions", DubConfig.test)
        .map!(version_ => "-version=" ~ version_)
        .array;
    compilerArguments ~= dubDescribe(directory, "debug-versions", DubConfig.test)
        .map!(debugVersion => "-debug=" ~ debugVersion)
        .array;
    compilerArguments ~= dubDescribe(directory, "options", DubConfig.test)
        .map!(dmdFlagsForOption)
        .filter!(flag => flag.length > 0)
        .array;

    string[string] sourceOverrides;
    foreach (file; files)
        if (isGeneratedTestRoot(file))
            sourceOverrides[file] = noIoTestRoot(file.readText);

    return SourceSet(
        files,
        dubDescribe(directory, "import-paths", DubConfig.test),
        dubDescribe(directory, "string-import-paths", DubConfig.test),
        dubDescribe(directory, "lflags", DubConfig.test),
        FrontendFlags(compilerArguments),
        sourceOverrides,
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
