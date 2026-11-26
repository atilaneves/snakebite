module snakebite.build.image;


private:


// The command of the image statement:
//
//   sb --image=FILE DIR [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      [--lflag=ARGUMENT]... IMAGE-MODULE [LINKER-FILE]...
//
// It runs in the project directory DIR, where the host compiler finds the
// configuration of the project. It compiles the image module
// (`imageModuleText`) with the host compiler, links it with the linker files
// to FILE, and writes `FILE.dep`: the files that the host compiler read.
public int image(string[] args) {
    import snakebite.build.dependencyfile: writeRetargetedDependencyFile;
    import snakebite.image.preparation:
        defaultCompiler, defersStartup, ImageBuild, Optimise;
    import snakebite.project.loading: EndsProcess, ProjectDirectory;
    import std.file: mkdirRecurse, readText, rmdirRecurse;
    import std.getopt: getopt;
    import std.path: buildPath;

    string output;
    string[] compilerArguments;
    string[] importPaths;
    string[] stringImportPaths;
    string[] linkerArguments;
    getopt(
        args,
        "image", &output,
        "dflag", &compilerArguments,
        "I", &importPaths,
        "J", &stringImportPaths,
        "lflag", &linkerArguments,
    );
    if (args.length < 3)
        throw new Exception(
            "--image needs the project directory and the image module"
        );
    const directory = args[1];
    const source = args[2];
    scope entered = ProjectDirectory(directory, directory, EndsProcess.no);
    const build = ImageBuild(defaultCompiler, importPaths, stringImportPaths,
        compilerArguments, args[3 .. $], linkerArguments, Optimise.yes,
        defersStartup(source.readText));

    const staging = output ~ ".staging";
    staging.mkdirRecurse;
    scope(exit) staging.rmdirRecurse;
    const compilerRule = staging.buildPath("image.o.dep");
    const objectPath = build.make(source, staging, output, compilerRule);
    writeRetargetedDependencyFile(output ~ ".dep", output, compilerRule,
        objectPath);
    return 0;
}
