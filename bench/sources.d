module bench.sources;


// What the frontend needs to build a `Program` from a project directory.
// dub answers for dub projects (bench.dub); the command line has to say for
// bare directories of .d files (bench.bare).
struct SourceSet {
    string[] files;
    string[] importPaths;
    string[] stringImportPaths;
    string[] linkerFlags;
    imported!"snakebite.frontend.compiler".FrontendFlags flags;
    string[string] sourceOverrides;
}

SourceSet sourceSet(
    in string directory,
    in string[] cliImportPaths,
    in string[] cliStringImportPaths,
) {
    import bench.bare: bareSourceSet;
    import bench.dub: dubSourceSet;
    import std.conv: text;
    import std.file: exists, isDir;

    if (!directory.exists || !directory.isDir)
        throw new Exception(text("not a directory: ", directory));

    return isDubProject(directory)
        ? dubSourceSet(directory)
        : bareSourceSet(directory, cliImportPaths, cliStringImportPaths);
}

bool isDubProject(in string directory) {
    import std.file: exists;
    import std.path: buildPath;

    foreach (recipe; ["dub.sdl", "dub.json"])
        if (buildPath(directory, recipe).exists)
            return true;

    return false;
}
