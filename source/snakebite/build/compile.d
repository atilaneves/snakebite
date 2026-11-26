module snakebite.build.compile;


private:


// The command of the compile statement:
//
//   sb --compile=FILE DIR [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      [--c-imports-are-roots] ROOT-FILE...
//
// It runs in the project directory DIR, as the names of the root files are
// relative to it. It runs the frontend on the root files, loads no
// dependency image, and writes the program to FILE with the save of
// `--save`. Beside FILE it writes what the image needs from the root code
// (`BuildFiles.imageSource`), only when that changed, and `FILE.dep`: the
// files that the frontend read.
public int compile(string[] args) {
    import snakebite.backends.bytecode.vm: JitSetting;
    import snakebite.build: BuildFiles, writeChanged;
    import snakebite.build.dependencyfile: writeDependencyFile;
    import snakebite.driver.execution: loadedProject, saveProgram;
    import snakebite.frontend.compiler: FrontendFlags;
    import snakebite.project.dependencies: imageModule;
    import snakebite.project.dub: SourceSet;
    import snakebite.project.loading: EndsProcess, ProjectDirectory;
    import std.getopt: getopt;
    import std.path: dirName;

    string output;
    string[] compilerArguments;
    string[] importPaths;
    string[] stringImportPaths;
    bool cImportsAreRoots;
    getopt(
        args,
        "compile", &output,
        "dflag", &compilerArguments,
        "I", &importPaths,
        "J", &stringImportPaths,
        "c-imports-are-roots", &cImportsAreRoots,
    );

    if (args.length < 2)
        throw new Exception("--compile needs the project directory");
    const directory = args[1];
    SourceSet sources;
    sources.files = args[2 .. $];
    sources.importPaths = importPaths;
    sources.stringImportPaths = stringImportPaths;
    sources.flags = FrontendFlags(compilerArguments);
    sources.importedCFilesAreRoots = cImportsAreRoots;
    scope entered = ProjectDirectory(directory, directory, EndsProcess.no);
    // The image that the load uses exists, so the frontend accepts what only
    // the image runs.
    const buildsDependencyImage = true;
    auto project = loadedProject(directory, sources, buildsDependencyImage);
    saveProgram(project.program, output, JitSetting.init);
    writeChanged(BuildFiles(output.dirName).imageSource,
        imageModule(project.program));
    writeDependencyFile(output ~ ".dep", output, directory);
    return 0;
}
