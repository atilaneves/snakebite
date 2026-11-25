module snakebite.build.link;


private:


// The command of the link statement:
//
//   sb --link=FILE UNIT-FILE...
//
// It joins the files of the units, which the compile statements wrote, into
// the program FILE (`linkPrograms`), which the run loads. Beside FILE it
// writes the image module (`BuildFiles.imageSource`), only when that
// changed: no unit needs code of the root package in the image (ADR-0021,
// item 10). It prints the time of the join as a line of the report of a run.
public int link(string[] args) {
    import snakebite.backends.bytecode.file: linkPrograms;
    import snakebite.build: BuildFiles, writeChanged;
    import snakebite.image.preparation: generatorKey;
    import snakebite.project.dependencies: imageModuleWithoutRootCode;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.getopt: getopt;
    import std.path: dirName;
    import std.stdio: writefln;

    string output;
    getopt(args, "link", &output);
    if (args.length < 2)
        throw new Exception("--link needs the files of the units");
    auto stopWatch = StopWatch(AutoStart.yes);
    const linked = linkPrograms(args[1 .. $], output, generatorKey);
    const duration = stopWatch.peek;
    writeChanged(BuildFiles(output.dirName).imageSource,
        imageModuleWithoutRootCode(linked.hasCEntryPoint && !linked.betterC));
    // As the lines of the report of a run: the time of the join of the files
    // of the units, not of the image module.
    writefln("%-20s %8.1f ms", "link:", duration.total!"usecs" / 1000.0);
    return 0;
}
