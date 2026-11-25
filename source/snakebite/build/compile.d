module snakebite.build.compile;


private:


// The command of the compile statement:
//
//   sb --compile=FILE [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      --program-name=NAME --working-directory=DIRECTORY --image-path=IMAGE
//      [--unit [--other-unit=FILE]... [--file-position=N]...] ROOT-FILE...
//
// It runs in the project directory. It runs the frontend on the root files,
// loads no dependency image, and writes the program to FILE with the save of
// `--save`, and `FILE.dep`: the files that the frontend read. With `--unit`
// the root files are one unit of the program and the files `--other-unit`
// are the other units, and each `--file-position` is the position of a root
// file among the root files of the program, one for each root file. FILE is
// the file of the unit, which a link joins to the files of the other units
// (`link`). Without it, beside FILE it writes what the image needs from the
// root code (`BuildFiles.imageSource`), only when that changed. With `--unit`
// the image needs nothing from the root code (ADR-0021, item 10).
public int compile(string[] args) {
    import snakebite.backends.bytecode.vm: JitSetting;
    import snakebite.build: BuildFiles, writeChanged;
    import snakebite.build.dependencyfile: writeDependencyFile;
    import snakebite.driver.execution: loadedProject, saveProgram;
    import snakebite.frontend.compiler: FrontendFlags;
    import snakebite.project.dependencies: imageModule;
    import snakebite.project.dub: SourceSet;
    import std.file: getcwd;
    import std.getopt: getopt;
    import std.path: dirName;

    string output;
    string[] compilerArguments;
    string[] importPaths;
    string[] stringImportPaths;
    string programName;
    string workingDirectory;
    string imagePath;
    bool isUnit;
    string[] otherUnitFiles;
    size_t[] filePositions;
    getopt(
        args,
        "compile", &output,
        "dflag", &compilerArguments,
        "I", &importPaths,
        "J", &stringImportPaths,
        "program-name", &programName,
        "working-directory", &workingDirectory,
        "image-path", &imagePath,
        "unit", &isUnit,
        "other-unit", &otherUnitFiles,
        "file-position", &filePositions,
    );

    if (const message = filePositionsError(
            isUnit, args[1 .. $], filePositions)) {
        import std.stdio: stderr;

        stderr.writeln("sb --compile: ", message);
        return 1;
    }

    SourceSet sources;
    sources.files = args[1 .. $];
    sources.importPaths = importPaths;
    sources.stringImportPaths = stringImportPaths;
    sources.flags = FrontendFlags(compilerArguments);
    sources.workingDirectory = workingDirectory;
    sources.isUnit = isUnit;
    sources.otherUnitFiles = otherUnitFiles;
    sources.rootPositions = filePositions;
    const directory = getcwd;
    // The image that the load uses exists, so the frontend accepts what only
    // the image runs.
    const buildsDependencyImage = true;
    auto project = loadedProject(directory, sources, buildsDependencyImage,
        programName);
    saveProgram(project.program, output, workingDirectory, imagePath,
        JitSetting.init);
    if (!isUnit)
        writeChanged(BuildFiles(output.dirName).imageSource,
            imageModule(project.program));
    writeDependencyFile(output ~ ".dep", output, directory);
    return 0;
}


// Why the positions cannot go with the root files, or null. A unit has one
// position for each root file; a compile that is not a unit has none.
public string filePositionsError(
    in bool isUnit, in string[] rootFiles, in size_t[] positions,
) {
    import std.conv: text;

    const expected = isUnit ? rootFiles.length : 0;
    if (positions.length == expected)
        return null;

    return text("the compile has ", rootFiles.length, " root files and ",
        positions.length, " --file-position options; it needs ", expected);
}
