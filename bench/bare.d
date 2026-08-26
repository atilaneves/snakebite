module bench.bare;


import bench.sources: SourceSet;


// A bare directory of .d files: no dub to ask, so the files come from a
// glob (sorted, so the build is stable) and any import paths or string
// import paths beyond the directory itself have to come from the command
// line.
SourceSet bareSourceSet(
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
