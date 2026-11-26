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
        ~ inputs.sort.uniq.map!(input => " \\\n  " ~ escapedMakePath(input))
            .join
        ~ "\n";
    path.write(rule);
}


// Writes to `path` the rule of the file `compilerRule`, which a host compiler
// wrote with `-makedeps` for its output `compilerTarget`, with `target` in
// place of that output and without the files `intermediates`. An
// intermediate file is one that the command writes and removes: it is no
// input of the build.
public void writeRetargetedDependencyFile(
    in string path,
    in string target,
    in string compilerRule,
    in string compilerTarget,
    in string[] intermediates,
) {
    import snakebite.failure.report: internalFailure;
    import snakebite.frontend.compiler: escapedMakePath;
    import std.algorithm.iteration: fold, map;
    import std.algorithm.searching: startsWith;
    import std.array: array;
    import std.file: readText, write;
    import std.string: replace;

    const rule = compilerRule.readText;
    const named = escapedMakePath(compilerTarget) ~ ":";
    if (!rule.startsWith(named))
        internalFailure("the compiler's dependency file names another target");
    // Each input has this form in the file that `-makedeps` writes.
    const forms = intermediates
        .map!(intermediate => " \\\n  " ~ escapedMakePath(intermediate))
        .array;
    const inputs = forms.fold!((text, form) => text.replace(form, ""))(
        rule[named.length .. $],
    );
    path.write(escapedMakePath(target) ~ ":" ~ inputs);
}
