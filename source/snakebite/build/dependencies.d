module snakebite.build.dependencies;


private:


// The command of the dependencies statement:
//
//   sb --dub-dependencies DIR
//
// It runs dub's build of the libraries of the dub dependencies of the
// project in the absolute directory DIR. dub decides which library is stale
// and writes only those, so a run that changes no library leaves their times
// as they were.
public int dependencies(string[] args) {
    import snakebite.build: dubDependenciesOption;
    import snakebite.project.dub: dubDescribeProject, dubSources, runDubBuild;
    import std.getopt: getopt;

    bool builds;
    getopt(args, dubDependenciesOption[2 .. $], &builds);
    if (args.length != 2)
        throw new Exception(dubDependenciesOption ~ " takes one directory");
    const directory = args[1];
    // dub's build takes the configuration, the build type and the compiler
    // of the description.
    auto description = dubDescribeProject(directory);
    const copies = targetDirectories(description.project);
    runDubBuild(directory, description,
        dubSources(directory, description).linkerFiles);
    copies.restoreUnchanged;
    return 0;
}


// A directory and the times and the names of its entries.
private struct Directory {
    import std.datetime.systime: SysTime;

    string path;
    SysTime accessed;
    SysTime modified;
    string[] entries;
}


// The directories that exist and that dub copies a target into, after each
// build of a package and also when the target is up to date. Such a directory
// can be an input of `build.ninja`, whose statement must not run because of a
// copy.
private Directory[] targetDirectories(
    in imported!"dub.description".ProjectDescription project,
) {
    import std.algorithm.iteration: map, uniq;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: exists, getTimes, isDir;
    import std.path: buildNormalizedPath;

    string[string] packagePaths;
    foreach (package_; project.packages)
        packagePaths[package_.name] = package_.path;
    Directory[] directories;
    foreach (path; project.targets
            .map!(target => buildNormalizedPath(packagePaths[target.rootPackage],
                target.buildSettings.targetPath))
            .array.sort.uniq) {
        if (!path.exists || !path.isDir)
            continue;
        Directory directory;
        directory.path = path;
        getTimes(path, directory.accessed, directory.modified);
        directory.entries = entryNames(path);
        directories ~= directory;
    }
    return directories;
}


// Gives each directory of `directories` its times again when it has the same
// entries: a copy replaced a file with a file of the same name.
private void restoreUnchanged(in Directory[] directories) {
    import std.file: exists, setTimes;

    foreach (directory; directories)
        if (directory.path.exists && entryNames(directory.path) == directory.entries)
            setTimes(directory.path, directory.accessed, directory.modified);
}


private string[] entryNames(in string path) {
    import std.algorithm.iteration: map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: SpanMode, dirEntries;

    return dirEntries(path, SpanMode.shallow).map!(entry => entry.name).array
        .sort.release;
}
