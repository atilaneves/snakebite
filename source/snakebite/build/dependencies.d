module snakebite.build.dependencies;


private:


// The command of the dependencies statement:
//
//   sb --dub-dependencies DIR LIBRARY...
//
// It runs dub's build of the libraries of the dub dependencies of the
// project in the absolute directory DIR, which makes the files LIBRARY. dub
// decides which library is stale and writes only those, so a run that
// changes no library leaves their times as they were.
public int dependencies(string[] args) {
    import snakebite.build: dubDependenciesOption;
    import snakebite.project.dub: dubDescribeProject, runDubBuild;
    import std.getopt: getopt;

    bool builds;
    getopt(args, dubDependenciesOption[2 .. $], &builds);
    if (args.length < 3)
        throw new Exception(dubDependenciesOption
            ~ " takes one directory and the libraries that dub's build makes");
    const directory = args[1];
    // dub's build takes the configuration, the build type and the compiler
    // of the description.
    runDubBuild(directory, dubDescribeProject(directory), args[2 .. $]);
    return 0;
}
