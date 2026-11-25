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
// item 10).
public int link(string[] args) {
    import snakebite.backends.bytecode.file: linkPrograms;
    import snakebite.build: BuildFiles, writeChanged;
    import snakebite.project.dependencies: imageModuleWithoutRootCode;
    import std.getopt: getopt;
    import std.path: dirName;

    string output;
    getopt(args, "link", &output);
    if (args.length < 2)
        throw new Exception("--link needs the files of the units");
    const linked = linkPrograms(args[1 .. $], output);
    writeChanged(BuildFiles(output.dirName).imageSource,
        imageModuleWithoutRootCode(linked.hasCEntryPoint && !linked.betterC));
    return 0;
}
