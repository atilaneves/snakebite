module snakebite.build.compile;


private:


// The command of the compile statement:
//
//   sb --compile=FILE [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      --program-name=NAME --working-directory=DIRECTORY --image-path=IMAGE
//      [--c-imports-are-roots] [--lowmem] ROOT-FILE...
//
// It runs in the project directory. It runs the frontend on the root files,
// loads no dependency image, and writes the program to FILE with the save of
// `--save`. Beside FILE it writes what the image needs from the root code
// (`BuildFiles.imageSource`), only when that changed, and `FILE.dep`: the
// files that the frontend read.
public int compile(string[] args) {
    import snakebite.backends.bytecode.vm: JitSetting;
    import snakebite.build: BuildFiles, writeChanged;
    import snakebite.build.dependencyfile: writeDependencyFile;
    import snakebite.driver.execution: saveProgram;
    import snakebite.frontend.compiler: FrontendFlags, Snippets, initialize;
    import snakebite.memory.gc: selectFrontendMemory;
    import snakebite.project.dependencies: imageModule;
    import snakebite.project.dub: SourceSet;
    import snakebite.project.loading: loadProject;
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
    bool cImportsAreRoots;
    bool lowmem;
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
        "lowmem", &lowmem,
    );

    selectFrontendMemory(lowmem);
    initialize(Snippets.no);
    SourceSet sources;
    sources.files = args[1 .. $];
    sources.importPaths = importPaths;
    sources.stringImportPaths = stringImportPaths;
    sources.flags = FrontendFlags(compilerArguments);
    sources.workingDirectory = workingDirectory;
    sources.importedCFilesAreRoots = cImportsAreRoots;
    const directory = getcwd;
    // The image that the load uses exists, so the frontend accepts what only
    // the image runs.
    const buildsDependencyImage = true;
    auto project = loadProject(directory, sources, buildsDependencyImage,
        programName);
    project.program.startsAsProject = true;
    saveProgram(project.program, output, workingDirectory, imagePath,
        JitSetting.init);
    writeChanged(BuildFiles(output.dirName).imageSource,
        imageModule(project.program));
    writeDependencyFile(output ~ ".dep", output, directory);
    return 0;
}
