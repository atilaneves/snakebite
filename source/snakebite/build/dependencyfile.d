module snakebite.build.dependencyfile;


private:


// Writes to `path` a rule in the Makefile form that `dmd -makedeps` writes
// and that ninja reads with `deps = gcc`: `target` depends on each file that
// the compile read: the files of the frontend's record (`filesRead`). The
// frontend ran in `directory`, so a relative name is relative to it.
public void writeDependencyFile(
    in string path,
    in string target,
    in string directory,
) {
    import snakebite.frontend.compiler: escapedMakePath, filesRead;
    import std.algorithm.iteration: map, uniq;
    import std.algorithm.sorting: sort;
    import std.array: array, join;
    import std.file: write;
    import std.path: absolutePath, buildNormalizedPath;

    auto inputs = filesRead
        .map!(name => name.absolutePath(directory).buildNormalizedPath)
        .array;
    const rule = escapedMakePath(target) ~ ":"
        ~ inputs.sort.uniq.map!ruleInput.join ~ "\n";
    path.write(rule);
}


// The input `path` in the form of a rule that `dmd -makedeps` writes.
private string ruleInput(in string path) {
    import snakebite.frontend.compiler: escapedMakePath;

    return " \\\n  " ~ escapedMakePath(path);
}


// Writes to `path` the rule of the file `compilerRule`, which a host compiler
// wrote with `-makedeps` for its output `compilerTarget`, with `target` in
// place of that output and without the input `intermediate`: a file that the
// command writes and removes, so no input of the build.
public void writeRetargetedDependencyFile(
    in string path,
    in string target,
    in string compilerRule,
    in string compilerTarget,
    in string intermediate,
) {
    import snakebite.failure.report: internalFailure;
    import snakebite.frontend.compiler: escapedMakePath;
    import std.algorithm.searching: startsWith;
    import std.file: readText, write;
    import std.string: replace;

    const rule = compilerRule.readText;
    const ruleHead = escapedMakePath(compilerTarget) ~ ":";
    if (!rule.startsWith(ruleHead))
        internalFailure("the compiler's dependency file names another target");
    const inputs = rule[ruleHead.length .. $]
        .replace(ruleInput(intermediate), "");
    path.write(escapedMakePath(target) ~ ":" ~ inputs);
}
