module snakebite.build.image;


private:


// The command of the image statement:
//
//   sb --image=FILE DIR [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      [--lflag=ARGUMENT]... IMAGE-SOURCE... [LINKER-FILE]...
//
// It runs in the project directory DIR, where the host compiler finds the
// configuration of the project. As for a D compiler, a file whose name ends
// in `.d` is an image source and any other file is a linker file. It builds
// the image of the image sources and the linker files to FILE
// (`ImageBuild.make`) and writes `FILE.dep`: the files that the host compiler
// read, but the image module, which the build writes and removes.
public int image(string[] args) {
    import snakebite.build.dependencyfile: writeRetargetedDependencyFile;
    import snakebite.image.preparation:
        defaultCompiler, ImageBuild, ImageSource, Optimise;
    import snakebite.project.loading: ProjectDirectory;
    import std.algorithm.searching: any;
    import std.algorithm.sorting: partition;
    import std.algorithm.mutation: SwapStrategy;
    import std.file: mkdirRecurse, readText, rmdirRecurse;
    import std.getopt: getopt;
    import std.path: buildPath, extension;

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
            "--image needs the project directory and the image sources"
        );
    const directory = args[1];
    // `auto`: `partition` reorders the paths in place. The order of the
    // linker files is the order of the link.
    auto inputPaths = args[2 .. $];
    static bool isImageSource(in string path) { return path.extension == ".d"; }
    const linkerFiles = inputPaths
        .partition!(isImageSource, SwapStrategy.stable);
    const sourcePaths = inputPaths[0 .. $ - linkerFiles.length];
    scope entered = ProjectDirectory(directory);
    // The image source of each compile says whether the program of the
    // compile has a C entry point. In a build of each module, only the
    // compile of the module that defines that entry point says yes, and the
    // image of the program defers the start of its modules when one does.
    const deferStartup = sourcePaths
        .any!(path => ImageSource.parse(path.readText).defersStartup);
    const build = ImageBuild(
        defaultCompiler,
        importPaths,
        stringImportPaths,
        compilerArguments,
        linkerFiles,
        linkerArguments,
        Optimise.yes,
        deferStartup,
    );

    const staging = output ~ ".staging";
    staging.mkdirRecurse;
    scope(exit) staging.rmdirRecurse;
    const compilerRule = staging.buildPath("image.o.dep");
    const objectPath = build.make(sourcePaths, staging, output, compilerRule);
    writeRetargetedDependencyFile(
        output ~ ".dep",
        output,
        compilerRule,
        objectPath,
        ImageBuild.modulePath(staging),
    );
    return 0;
}
