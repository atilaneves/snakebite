module snakebite.build.ninja;


private:


// Writes the `build.ninja` of the dub project in the absolute directory
// `directory`, only when its text differs from the file. This is the only
// place where the build reads the description of the dub project.
public void writeBuildFile(in string directory) {
    import snakebite.build: buildFiles, writeChanged;
    import snakebite.project.dub: dubDescribeProject, dubSources, dubWatchedPaths;
    import std.file: mkdirRecurse, setTimes;
    import std.datetime: Clock;

    auto description = dubDescribeProject(directory);
    const sources = dubSources(directory, description);
    if (sources.linkerFiles.length)
        throw new Exception("--build=project does not yet build the "
            ~ "dependencies of a dub project (issue #996, step 2)");
    const files = buildFiles(directory);
    const text = buildFileText(directory, sources,
        dubWatchedPaths(directory, description));
    files.directory.mkdirRecurse;
    if (writeChanged(files.ninjaFile, text))
        return;
    // The run that makes the text can make an input of it, as dub makes its
    // test runner directory. ninja takes the inputs as they were before this
    // command ran, so the file must be newer than all of them.
    const now = Clock.currTime;
    setTimes(files.ninjaFile, now, now);
}


// The build statements: `build.ninja` itself, the compile of the root
// package to the program and the image module, and the dependency image.
// `watched` are the paths whose change can change `sources`.
private string buildFileText(
    in string directory,
    in imported!"snakebite.project.dub".SourceSet sources,
    in string[] watched,
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
    const generatorInputs = [sb] ~ watched;
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
        plain(["cd", start]) ~ shell(["&&"])
            ~ plain([sb, "--build=project", "--generate", directory]),
        ["generator = 1", "restat = 1", "pool = console"]);
    text ~= rule("compile",
        plain(["cd", directory]) ~ shell(["&&"])
            ~ plain([sb, "--compile=" ~ files.program])
            ~ shell(commandVariables),
        ["depfile = " ~ files.program.ninjaValue ~ ".dep", "deps = gcc",
            "restat = 1", "pool = console"]);
    // ninja quotes the path of `$out` for the shell.
    text ~= rule("image",
        plain(["cd", directory]) ~ shell(["&&"]) ~ plain(environmentOfBuild)
            ~ plain([sb]) ~ shell(["--image=$out"])
            ~ shell(commandVariables),
        ["depfile = $out.dep", "deps = gcc", "pool = console"]);

    text ~= statement([files.ninjaFile], "generate", null, generatorInputs);
    text ~= statement(generatorInputs, "phony", null, null);
    text ~= "\n" ~ statement([files.program, files.imageSource], "compile",
        sources.files, [sb]);
    foreach (name; compilerVariables)
        text ~= statementVariable(name, variables[name]);
    text ~= statementVariable("options", [
        "--program-name=" ~ directory.baseName,
        "--working-directory=" ~ workingDirectory,
        "--image-path=" ~ files.image,
    ] ~ (sources.importedCFilesAreRoots ? ["--c-imports-are-roots"] : null));
    text ~= "\n" ~ statement([files.image], "image",
        [files.imageSource] ~ sources.linkerFiles, [sb, compiler]);
    foreach (name; compilerVariables)
        text ~= statementVariable(name, variables[name]);
    text ~= statementVariable("options",
        sources.linkerFlags.map!(flag => "--lflag=" ~ flag).array);
    text ~= "\ndefault " ~ [files.program, files.image].map!ninjaPath.join(" ")
        ~ "\n";
    return text;
}


// The variables of a statement that hold the arguments of the compiler.
private enum compilerVariables = ["flags", "includes", "stringImports"];


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


// A word of the command of a rule. The shell takes `text` as it is when it
// is `verbatim`: an operator of the shell, or a variable of ninja, which
// ninja expands to words. Other text is one word, quoted.
private struct Word {
    string text;
    bool verbatim;
}


private Word[] plain(in string[] words) {
    import std.algorithm.iteration: map;
    import std.array: array;

    return words.map!(word => Word(word, false)).array;
}


private Word[] shell(in string[] words) {
    import std.algorithm.iteration: map;
    import std.array: array;

    return words.map!(word => Word(word, true)).array;
}


private string rule(
    in string name, in Word[] command, in string[] settings,
) {
    import std.algorithm.iteration: map;
    import std.array: join;

    return "\nrule " ~ name ~ "\n"
        ~ "  command = "
        ~ command.map!(word => word.verbatim
            ? word.text : word.text.shellQuoted.ninjaValue).join(" ") ~ "\n"
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
