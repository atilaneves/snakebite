module snakebite.build.image;


private:


// The command of the image statement:
//
//   sb --image=FILE DIR [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      [--lflag=ARGUMENT]... IMAGE-SOURCE... [LINKER-FILE]...
//
// It runs in the project directory DIR, where the host compiler finds the
// configuration of the project. As for a D compiler, a file whose name ends
// in `.d` is an image source and any other file is a linker file. It writes
// the image module of the image sources (`imageModuleText`) to `FILE.d`,
// compiles it and the image sources with the host compiler, links them with
// the linker files to FILE, and writes `FILE.dep`: the files that the host
// compiler read.
public int image(string[] args) {
    import snakebite.build.dependencyfile: writeRetargetedDependencyFile;
    import snakebite.image.preparation:
        defaultCompiler, defersStartup, ImageBuild, imageModuleText, Optimise;
    import snakebite.project.loading: ProjectDirectory;
    import std.algorithm.iteration: filter;
    import std.algorithm.searching: any;
    import std.array: array;
    import std.file: mkdirRecurse, readText, rmdirRecurse, write;
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
    const files = args[2 .. $];
    const sources = files.filter!(file => file.extension == ".d").array;
    const linkerFiles = files.filter!(file => file.extension != ".d").array;
    scope entered = ProjectDirectory(directory);
    const deferStartup = sources
        .any!(source => defersStartup(source.readText));
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

    const modulePath = output ~ ".d";
    modulePath.write(imageModuleText(sources, deferStartup));
    const staging = output ~ ".staging";
    staging.mkdirRecurse;
    scope(exit) staging.rmdirRecurse;
    const compilerRule = staging.buildPath("image.o.dep");
    const objectPath = build.make(
        [modulePath] ~ sources,
        staging,
        output,
        compilerRule,
    );
    writeRetargetedDependencyFile(output ~ ".dep", output, compilerRule,
        objectPath);
    return 0;
}
