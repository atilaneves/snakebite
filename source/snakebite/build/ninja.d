module snakebite.build.ninja;


private:


// Writes the `build.ninja` of mode `build` of the dub project in the
// absolute directory `directory`, only when its text differs from the file,
// and the list of the program files that the build writes. The build reads
// the description of the dub project only here and in the command of the
// dependencies statement, which runs dub's build.
public void writeBuildFile(
    in string directory, in imported!"snakebite.build".Build build,
) {
    import snakebite.build: buildFiles, writeChanged;
    import snakebite.project.dub: dubBuildInputs, dubDescribeProject, dubSources;
    import std.algorithm.iteration: map;
    import std.array: join;
    import std.file: mkdirRecurse, setTimes;
    import std.datetime: Clock;

    auto description = dubDescribeProject(directory);
    const sources = dubSources(directory, description);
    const files = buildFiles(directory, build);
    const compiles = compilesOf(directory, build, sources);
    const text = buildFileText(directory, build, sources, compiles,
        dubBuildInputs(description, sources.files));
    files.directory.mkdirRecurse;
    writeChanged(files.workingDirectoryFileName, sources.runDirectory(directory));
    writeChanged(files.programListFileName,
        compiles.map!(compile => compile.program ~ "\n").join);
    if (writeChanged(files.ninjaFile, text))
        return;
    // The run that makes the text can make an input of it, as dub makes its
    // test runner directory. ninja takes the inputs as they were before this
    // command ran, so the file must be newer than all of them.
    const now = Clock.currTime;
    setTimes(files.ninjaFile, now, now);
}


// `files`, the configuration files of a compiler, as a command in `directory`
// finds them: a compiler looks in the directory of the command first.
private string[] configurationFiles(
    in string directory, lazy string[] files,
) {
    import snakebite.project.loading: ProjectDirectory;

    scope entered = ProjectDirectory(directory);
    return files;
}


// One compile statement: the program file that it writes and the source
// files that it compiles.
private struct Compile {
    string program;
    string[] sources;
}


// The compiles of mode `build`: one of all the source files of the root
// package, or one of each source file, whose program file has the path of
// the source file in the project directory `directory`.
private Compile[] compilesOf(
    in string directory,
    in imported!"snakebite.build".Build build,
    in imported!"snakebite.project.dub".SourceSet sources,
) {
    import snakebite.build: Build, buildFiles;
    import std.algorithm.iteration: map;
    import std.array: array;

    const files = buildFiles(directory, build);
    final switch (build) with (Build) {
        case off:
            throw new Exception("a build of mode off has no compile");
        case project:
            return [Compile(files.projectProgram, sources.files.dup)];
        case module_:
            return sources.files
                .map!(source => Compile(
                    programOfSource(files.directory, directory, source),
                    [source]))
                .array;
    }
}


// The program file in `buildDirectory` of the compile of the source file
// `source` alone: its path relative to the project directory `directory`.
// A source file outside the project directory has a part `parent` for each
// directory up.
private string programOfSource(
    in string buildDirectory, in string directory, in string source,
) {
    import std.algorithm.iteration: map;
    import std.path: absolutePath, buildPath, pathSplitter, relativePath,
        setExtension;

    const relative = source.absolutePath(directory).relativePath(directory);
    return buildDirectory.buildPath(relative.pathSplitter
        .map!(part => part == ".." ? "parent" : part).buildPath)
        .setExtension("sbc");
}


// The build statements: `build.ninja` itself, the compiles `compiles` of the
// source files of the root package, each to a program file and an image
// module, and for a build of the whole root package the libraries of the dub
// dependencies and the dependency image. `buildInputs` are the inputs of
// `build.ninja`: the paths whose change can change `sources`.
private string buildFileText(
    in string directory,
    in imported!"snakebite.build".Build build,
    in imported!"snakebite.project.dub".SourceSet sources,
    in Compile[] compiles,
    in string[] buildInputs,
) {
    import snakebite.build: Build, buildFiles, buildName, dubDependenciesOption,
        imageSourceOf;
    import snakebite.frontend.hostcompiler: compilerConfigurationFiles, hostCompiler,
        hostConfigurationFiles;
    import snakebite.image.preparation: compilerPath, defaultCompiler;
    import std.algorithm.iteration: filter, map, uniq;
    import std.algorithm.searching: canFind;
    import std.algorithm.sorting: sort;
    import std.array: array, join;
    import std.file: exists, thisExePath;

    const files = buildFiles(directory, build);
    const sb = thisExePath;
    // The frontend of the compile reads the configuration of the compiler
    // that built `sb`. dub's build and the image run `compiler`.
    const compiler = compilerPath(defaultCompiler);
    const frontendConfiguration = configurationFiles(directory,
        hostConfigurationFiles(hostCompiler));
    const compilerConfiguration = configurationFiles(directory,
        compilerConfigurationFiles(compiler));
    // A configuration file changes the text: the statements name it. When it
    // is removed, `build.ninja` is made again without it.
    const generatorInputs = [sb] ~ buildInputs ~ frontendConfiguration
        ~ compilerConfiguration;
    const variables = [
        "flags": sources.flags.compilerArguments
            .map!(argument => "--dflag=" ~ argument).array,
        "includes": sources.importPaths.map!(path => "-I" ~ path).array,
        "stringImports": sources.stringImportPaths
            .map!(path => "-J" ~ path).array,
    ];
    string text = "builddir = " ~ files.directory.ninjaValue ~ "\n";
    // ninja runs the commands in the directory that `sb` started in, which
    // the project state directory depends on. Each command gets the project
    // directory as an argument.
    text ~= rule(
        "generate",
        [sb, "--build=" ~ buildName(build), "--generate", directory],
        ["generator = 1", "restat = 1", "pool = console"],
    );
    text ~= rule(
        "dependencies",
        [sb, dubDependenciesOption, directory],
        ["$out"],
        ["restat = 1", "pool = console"],
    );
    text ~= rule(
        "compile",
        [sb, directory],
        ["--compile=$out"] ~ commandVariables,
        [
            "depfile = $out.dep",
            "deps = gcc",
            "restat = 1",
            "pool = console",
        ],
    );
    // ninja quotes the path of `$out` for the shell.
    text ~= rule(
        "image",
        [sb, directory],
        ["--image=$out"] ~ commandVariables,
        ["depfile = $out.dep", "deps = gcc", "pool = console"],
    );

    // The outputs are the libraries that dub's build makes. A linker file
    // that exists before the build is an input of the image. `inputs` names
    // each name that the recipe of a package can have: only the files that
    // exist are inputs.
    const libraries = sources.dependencies.targets;
    const dependencyInputs = [sb, compiler] ~ compilerConfiguration
        ~ sources.dependencies.inputs.filter!(path => path.exists).array;
    // As reggae does for the inputs of `build.ninja`: a phony statement names
    // each input that no statement makes, so that a removed input is not an
    // error.
    const sourceInputs = (generatorInputs ~ (libraries.length ? dependencyInputs : null)
            ~ sources.files ~ frontendConfiguration ~ sources.linkerFiles)
        .filter!(path => !libraries.canFind(path)).array.dup.sort.uniq.array;

    text ~= statement(
        [files.ninjaFile, files.workingDirectoryFileName,
            files.programListFileName],
        "generate",
        null,
        generatorInputs,
    );
    text ~= statement(sourceInputs, "phony", null, null);
    // The compile statements depend on no other statement: an edit of an
    // imported module starts each compile whose dependency file names it.
    foreach (compile; compiles) {
        text ~= "\n" ~ statement([compile.program], "compile", compile.sources,
            [sb] ~ frontendConfiguration, [imageSourceOf(compile.program)]);
        foreach (name; compilerVariables)
            text ~= statementVariable(name, variables[name]);
        text ~= statementVariable(
            "options",
            sources.importedCFilesAreRoots ? ["--c-imports-are-roots"] : null,
        );
    }
    auto defaults = compiles.map!(compile => compile.program).array;
    // The dependency image of a build of each module, from the native
    // template instances of all its compiles, is not built yet (ADR-0021,
    // item 14).
    if (build == Build.project) {
        if (libraries.length)
            text ~= "\n" ~ statement(libraries, "dependencies", null,
                dependencyInputs);
        text ~= "\n" ~ statement([files.image], "image",
            [imageSourceOf(files.projectProgram)] ~ sources.linkerFiles,
            [sb, compiler] ~ compilerConfiguration);
        foreach (name; compilerVariables)
            text ~= statementVariable(name, variables[name]);
        text ~= statementVariable(
            "options",
            sources.linkerFlags.map!(flag => "--lflag=" ~ flag).array,
        );
        defaults ~= files.image;
    }
    text ~= "\ndefault " ~ defaults.map!ninjaPath.join(" ") ~ "\n";
    return text;
}


// The variables of a statement that hold the arguments of the compiler.
private enum compilerVariables = ["flags", "includes", "stringImports"];


// The variables that the compile and the image statements set.
private enum commandVariables =
    ["$flags", "$includes", "$stringImports", "$options", "$in"];


// A rule whose command is `words`, each one word for the shell.
private string rule(
    in string name,
    in string[] words,
    in string[] settings,
) {
    return rule(name, words, null, settings);
}


// A rule whose command is `words`, each one word for the shell, then the
// ninja variables `variables`, which ninja expands to words.
private string rule(
    in string name,
    in string[] words,
    in string[] variables,
    in string[] settings,
) {
    import std.algorithm.iteration: map;
    import std.array: array, join;

    const command = words.map!(word => word.shellQuoted.ninjaValue).array
        ~ variables;
    return "\nrule " ~ name ~ "\n"
        ~ "  command = " ~ command.join(" ") ~ "\n"
        ~ settings.map!(setting => "  " ~ setting ~ "\n").join;
}


private string shellQuoted(in string word) {
    import std.algorithm.searching: all, canFind;
    import std.string: replace;

    const plain = word.length && word.all!(c =>
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || "-_=+/.,:@%".canFind(c));
    return plain ? word : "'" ~ word.replace("'", `'\''`) ~ "'";
}


// A build statement. `implicitOutputs` are outputs that `$out` does not
// name.
private string statement(
    in string[] outputs,
    in string rule,
    in string[] inputs,
    in string[] implicitInputs,
    in string[] implicitOutputs = null,
) {
    import std.algorithm.iteration: map;
    import std.array: join;

    return "build " ~ outputs.map!ninjaPath.join(" ")
        ~ (implicitOutputs.length
            ? " |" ~ implicitOutputs.map!(output => " " ~ output.ninjaPath).join
            : "")
        ~ ": " ~ rule
        ~ inputs.map!(input => " " ~ input.ninjaPath).join
        ~ (implicitInputs.length
            ? " |" ~ implicitInputs.map!(input => " " ~ input.ninjaPath).join
            : "")
        ~ "\n";
}


// A variable of a build statement whose value is the words of a command.
private string statementVariable(in string name, in string[] words) {
    import std.algorithm.iteration: map;
    import std.array: join;

    return "  " ~ name ~ " = "
        ~ words.map!shellQuoted.join(" ").ninjaValue ~ "\n";
}


// `path` in a build line: `$`, the space and the colon are ninja's.
private string ninjaPath(in string path) {
    import std.string: replace;

    return path.ninjaValue.replace(" ", "$ ").replace(":", "$:");
}


private string ninjaValue(in string text) {
    import std.algorithm.searching: canFind;
    import std.string: replace;

    if (text.canFind('\n'))
        throw new Exception("a name in a build of ninja has a new line: " ~ text);
    return text.replace("$", "$$");
}
