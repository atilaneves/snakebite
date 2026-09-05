module snakebite.dub;

private:

// Which dub configuration a describe call asks about. `test` prefers the
// unittest configuration, so test-only dependencies (e.g. unit-threaded) are
// included, falling back to the default for packages without one. dub's
// synthetic test configuration excludes an executable's main source file -
// and with it every unittest in that file - in favour of a generated stub,
// so a caller assembling a whole `Program` from the real sources wants
// `default_` instead.
public enum DubConfig {
    test,
    default_,
}

// Run `dub describe ... --data=<dataKind> --data-list` in pkgDir and return
// its lines.
public string[] dubDescribe(
    in string pkgDir,
    in string dataKind,
    in DubConfig config = DubConfig.test,
) {
    return dubDescribe(pkgDir, [dataKind], config)[0];
}

// One `dub describe` for several data kinds at once, one list of lines per
// kind, in the order asked. Every describe is a dub process that also
// spawns the compiler to identify it, around 10ms each; asking for
// everything in one call is what keeps finding a project's sources from
// costing as much as parsing them.
public string[][] dubDescribe(
    in string pkgDir,
    in string[] dataKinds,
    in DubConfig config = DubConfig.test,
) {
    import std.array: join;

    const describe = ["dub", "describe"];
    const dataArgs = ["--data=" ~ dataKinds.join(","), "--data-list"];

    if (config == DubConfig.test) {
        // `--build=unittest` too: without it, describe reports the default
        // build type's flags, not the unittest build type's - missing
        // `-unittest` itself among others, since dub adds those per build
        // type, not per config.
        auto withUnittest = describeCapturingStdout(  // auto: need status and output
            describe ~ ["--config=unittest", "--build=unittest"] ~ dataArgs, pkgDir,
        );
        if (withUnittest.status == 0)
            return parseDescribeLists(withUnittest.output, dataKinds.length);
    }

    const fallback = describeCapturingStdout(describe ~ dataArgs, pkgDir);
    if (fallback.status != 0)
        throw new Exception(
            "dub describe " ~ dataKinds.join(",") ~ " failed in " ~ pkgDir
            ~ ": " ~ fallback.output,
        );

    return parseDescribeLists(fallback.output, dataKinds.length);
}

// Run a `dub describe` command in pkgDir, capturing its stdout and discarding
// its stderr. dub emits diagnostics on stderr (e.g. dscanner's "License in
// sub-package ... is different" warning, arsd-official's "defines no import
// paths"). They are noise from the benchmarked project, so drop them rather than
// forward them to our console. They must also stay out of the captured stdout:
// merged in, a warning line parses as a bogus data value - forwarded as an
// lflag/linker-file it fails the dependency-image link with `cannot open <text>`.
private auto describeCapturingStdout(in string[] command, in string pkgDir) {
    import std.conv: text;
    import std.file: readText, tempDir;
    import std.path: buildPath;
    import std.process: Config, spawnProcess, thisProcessID, wait;
    import std.stdio: File, stdin;
    import std.typecons: tuple;

    // Capture stdout via a temp file rather than a pipe so a large describe list
    // cannot deadlock on a full pipe buffer. describe calls run sequentially, so
    // one per-process path reused across calls is enough.
    const stdoutPath =
        buildPath(tempDir, "snakebite-dub-describe-" ~ text(thisProcessID) ~ ".out");
    auto stdoutFile = File(stdoutPath, "w");
    auto devNull = File("/dev/null", "w");
    auto pid = spawnProcess(command, stdin, stdoutFile, devNull, null, Config.none, pkgDir);
    const status = wait(pid);
    stdoutFile.close();
    return tuple!("status", "output")(status, readText(stdoutPath));
}

// Split the `--data-list` output for several data kinds into one list per
// kind. dub prints each kind's lines joined by newlines, the kinds joined
// by one blank line, then a final newline: an empty kind is nothing between
// two blank lines (or nothing before the final newline when it is last).
// Splitting on the blank line keeps empty kinds in their place instead of
// collapsing them away.
public string[][] parseDescribeLists(in string output, in size_t kinds) @safe pure {
    import std.algorithm.iteration: map;
    import std.algorithm.searching: endsWith;
    import std.array: array, split;
    import std.conv: text;

    // Exactly the expected shape, or dub's format has changed and the lists
    // would land on the wrong kinds.
    if (!output.endsWith("\n"))
        throw new Exception(
            "dub describe output does not end in a newline:\n" ~ output,
        );

    auto lists = output[0 .. $ - 1].split("\n\n").map!parseDescribeList.array;
    if (lists.length != kinds)
        throw new Exception(text(
            "dub describe printed ", lists.length, " lists, expected ",
            kinds, ":\n", output,
        ));

    return lists;
}

// Split a `dub describe --data-list` block into its non-empty, trimmed lines.
public string[] parseDescribeList(in string output) @safe pure {
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.string: splitLines, strip;

    return output
        .splitLines
        .map!(l => l.strip.idup)
        .filter!(l => l.length > 0)
        .array;
}

