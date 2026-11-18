module snakebite.build.image;


private:


// The command of the image statement:
//
//   sb --image=FILE [--dflag=ARGUMENT]... [-IPATH]... [-JPATH]...
//      [--lflag=ARGUMENT]... IMAGE-MODULE [LINKER-FILE]...
//
// It compiles the image module (`imageModuleText`) with the host compiler,
// links it with the linker files to FILE, and writes `FILE.dep`: the files
// that the host compiler read.
public int image(string[] args) {
    import snakebite.build.dependencyfile: writeRetargetedDependencyFile;
    import snakebite.image.preparation:
        defaultCompiler, defersStartup, ImageBuild, Optimise;
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
    if (args.length < 2)
        throw new Exception("--image needs the image module");
    const source = args[1];
    const build = ImageBuild(defaultCompiler, importPaths, stringImportPaths,
        compilerArguments, args[2 .. $], linkerArguments, Optimise.yes,
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
