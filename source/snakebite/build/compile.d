module snakebite.build.compile;


private:


// The command of the compile statement:
//
//   sb --compile=FILE [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      --program-name=NAME --working-directory=DIRECTORY --image-path=IMAGE
//      [--c-imports-are-roots] [--unit [--unit-files=LIST]] ROOT-FILE...
//
// It runs in the project directory. It runs the frontend on the root files,
// loads no dependency image, and writes the program to FILE with the save of
// `--save`, and `FILE.dep`: the files that the frontend read. With `--unit`
// the root files are one unit of the program and the file LIST holds the root
// files of the program, one on each line: FILE is the file of the unit, which
// a link joins to the files of the other units (`link`). Without it, beside FILE it writes
// what the image needs from the root code (`BuildFiles.imageSource`), only
// when that changed. With `--unit` the image needs nothing from the root
// code (ADR-0021, item 10).
public int compile(string[] args) {
    import snakebite.backends.bytecode.vm: JitSetting;
    import snakebite.build: BuildFiles, writeChanged;
    import snakebite.build.dependencyfile: writeDependencyFile;
    import snakebite.driver.execution: loadedProject, saveProgram;
    import snakebite.frontend.compiler: FrontendFlags;
    import snakebite.project.dependencies: imageModule;
    import snakebite.project.dub: SourceSet;
    import std.algorithm.iteration: filter;
    import std.algorithm.searching: canFind;
    import std.array: array;
    import std.file: getcwd, readText;
    import std.getopt: getopt;
    import std.path: dirName;
    import std.string: splitLines;

    string output;
    string[] compilerArguments;
    string[] importPaths;
    string[] stringImportPaths;
    string programName;
    string workingDirectory;
    string imagePath;
    bool cImportsAreRoots;
    bool isUnit;
    string unitFiles;
    getopt(
        args,
        "compile", &output,
        "dflag", &compilerArguments,
        "I", &importPaths,
        "J", &stringImportPaths,
        "program-name", &programName,
        "working-directory", &workingDirectory,
        "image-path", &imagePath,
        "c-imports-are-roots", &cImportsAreRoots,
        "unit", &isUnit,
        "unit-files", &unitFiles,
    );

    SourceSet sources;
    sources.files = args[1 .. $];
    sources.importPaths = importPaths;
    sources.stringImportPaths = stringImportPaths;
    sources.flags = FrontendFlags(compilerArguments);
    sources.workingDirectory = workingDirectory;
    sources.importedCFilesAreRoots = cImportsAreRoots;
    sources.isUnit = isUnit;
    if (unitFiles.length)
        sources.otherUnitFiles = unitFiles.readText.splitLines
            .filter!(file => !sources.files.canFind(file)).array;
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
