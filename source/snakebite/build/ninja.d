module snakebite.build.ninja;


private:


// Writes the `build.ninja` of the project in the absolute directory
// `directory`, only when its text differs from the file. This is the only
// place where the build reads the description of the dub project.
public void writeBuildFile(in string directory, in bool lowmem) {
    import snakebite.build: buildFiles, writeChanged;
    import snakebite.project.loading: sourceSet;
    import std.file: mkdirRecurse;

    const files = buildFiles(directory);
    const text = buildFileText(directory, sourceSet(directory, null, null),
        lowmem);
    files.directory.mkdirRecurse;
    writeChanged(files.ninjaFile, text);
}


// The build statements: `build.ninja` itself, the compile of the root
// package to the program and the image module, and the dependency image.
private string buildFileText(
    in string directory,
    in imported!"snakebite.project.dub".SourceSet sources,
    in bool lowmem,
) {
    import snakebite.build: buildFiles;
    import snakebite.image.preparation: compilerPath, defaultCompiler;
    import std.algorithm.iteration: map;
    import std.array: array, join;
    import std.file: getcwd, thisExePath;
    import std.path: baseName;

    const files = buildFiles(directory);
    const sb = thisExePath;
    const start = getcwd;
    const compiler = compilerPath(defaultCompiler);
    const lowmemOption = lowmem ? ["--lowmem"] : null;
    const generatorInputs = [sb] ~ buildFileInputs(directory, sources);
    const variables = [
        "flags": sources.flags.compilerArguments
            .map!(argument => "--dflag=" ~ argument).array,
        "includes": sources.importPaths.map!(path => "-I" ~ path).array,
        "stringImports": sources.stringImportPaths
            .map!(path => "-J" ~ path).array,
    ];
    const workingDirectory = sources.workingDirectory.length
        ? sources.workingDirectory : directory;

    string text = "builddir = " ~ files.directory.ninjaValue ~ "\n";
    text ~= rule("generate",
        ["cd", start, "&&", sb, "--build=project", "--generate"]
            ~ lowmemOption ~ [directory],
        ["generator = 1", "restat = 1", "pool = console"]);
    text ~= rule("compile",
        ["cd", directory, "&&", sb, "--compile=" ~ files.program]
            ~ commandVariables,
        ["depfile = " ~ files.program.ninjaValue ~ ".dep", "deps = gcc",
            "restat = 1", "pool = console"]);
    text ~= rule("image",
        ["cd", directory, "&&"] ~ environmentOfBuild
            ~ [sb, "--image=$out"] ~ commandVariables,
        ["depfile = $out.dep", "deps = gcc", "pool = console"]);

    text ~= statement([files.ninjaFile], "generate", null, generatorInputs);
    text ~= statement(generatorInputs, "phony", null, null);
    text ~= "\n" ~ statement([files.program, files.imageSource], "compile",
        sources.files, [sb]);
    foreach (name; ["flags", "includes", "stringImports"])
        text ~= variable(name, variables[name], 1);
    text ~= variable("options", [
        "--program-name=" ~ directory.baseName,
        "--working-directory=" ~ workingDirectory,
        "--image-path=" ~ files.image,
    ] ~ (sources.importedCFilesAreRoots ? ["--c-imports-are-roots"] : null)
        ~ lowmemOption, 1);
    text ~= "\n" ~ statement([files.image], "image",
        [files.imageSource] ~ sources.linkerFiles, [sb, compiler]);
    foreach (name; ["flags", "includes", "stringImports"])
        text ~= variable(name, variables[name], 1);
    text ~= variable("options",
        sources.linkerFlags.map!(flag => "--lflag=" ~ flag).array, 1);
    text ~= "\ndefault " ~ [files.program, files.image].map!ninjaPath.join(" ")
        ~ "\n";
    return text;
}


// The variables that the compile and the image statements set.
private enum commandVariables =
    ["$flags", "$includes", "$stringImports", "$options", "$in"];


// The environment that a compile with the host compiler reads, with the
// values that it had when `build.ninja` was made: as reggae reads its
// options when it makes the build.
private string[] environmentOfBuild() {
    import std.process: environment;

    string[] command = ["env"];
    foreach (name; ["DFLAGS", "LFLAGS"]) {
        const value = environment.get(name);
        command ~= value is null ? ["-u", name] : [name ~ "=" ~ value];
    }
    return command;
}


// The files and directories whose change can change the text of
// `build.ninja`: the recipe and the freeze file of the root package, and each
// directory where a new or removed file can change the root files.
private string[] buildFileInputs(
    in string directory,
    in imported!"snakebite.project.dub".SourceSet sources,
) {
    import snakebite.project.state: projectStateDirectory;
    import std.algorithm.iteration: filter, map, uniq;
    import std.algorithm.searching: canFind;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: SpanMode, dirEntries, exists, isDir, isSymlink;
    import std.path: absolutePath, baseName, buildNormalizedPath, buildPath, dirName;

    // A state directory changes on each run, and is not a source directory.
    const state = projectStateDirectory(directory).dirName;
    const skipped = [".git", ".dub", state.baseName];
    string[] directories;
    void collect(in string path) {
        if (path == state || !path.exists || !path.isDir || path.isSymlink)
            return;
        directories ~= path;
        foreach (entry; dirEntries(path, SpanMode.shallow, false))
            if (entry.isDir && !entry.isSymlink
                    && !skipped.canFind(entry.name.baseName))
                collect(entry.name);
    }
    foreach (path; [directory] ~ sources.importPaths ~ sources.stringImportPaths)
        collect(path.absolutePath.buildNormalizedPath);

    const recipes = ["dub.json", "dub.sdl", "package.json", "dub.selections.json"]
        .map!(name => directory.buildPath(name))
        .filter!(path => path.exists)
        .array;
    return recipes ~ directories.sort.uniq.array;
}


private string rule(
    in string name, in string[] command, in string[] settings,
) {
    import std.algorithm.iteration: map;
    import std.array: join;

    return "\nrule " ~ name ~ "\n"
        ~ "  command = " ~ command.map!commandWord.join(" ") ~ "\n"
        ~ settings.map!(setting => "  " ~ setting ~ "\n").join;
}


// A word of the command of a rule: a variable of ninja (`$in`), which
// ninja expands to words that the shell reads; an operator of the shell; or
// a word that the shell takes as it is.
private string commandWord(in string word) {
    import std.algorithm.searching: all, startsWith;
    import std.ascii: isAlphaNum;

    if (word == "&&" || (word.startsWith("$") && word[1 .. $].all!isAlphaNum))
        return word;
    // ninja quotes the path of `$out` for the shell.
    if (word == "--image=$out")
        return word;
    return word.shellQuoted.ninjaValue;
}


private string shellQuoted(in string word) {
    import std.algorithm.searching: all, canFind;
    import std.string: replace;

    const plain = word.length && word.all!(c =>
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || "-_=+/.,:@%".canFind(c));
    return plain ? word : "'" ~ word.replace("'", `'\''`) ~ "'";
}


private string statement(
    in string[] outputs,
    in string rule,
    in string[] inputs,
    in string[] implicitInputs,
) {
    import std.algorithm.iteration: map;
    import std.array: join;

    return "build " ~ outputs.map!ninjaPath.join(" ") ~ ": " ~ rule
        ~ inputs.map!(input => " " ~ input.ninjaPath).join
        ~ (implicitInputs.length
            ? " |" ~ implicitInputs.map!(input => " " ~ input.ninjaPath).join
            : "")
        ~ "\n";
}


// A variable of the file, or of a build statement with `indent`, whose value
// is the words of a command.
private string variable(in string name, in string[] words, in int indent = 0) {
    import std.algorithm.iteration: map;
    import std.array: join, replicate;

    return "  ".replicate(indent) ~ name ~ " = "
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
