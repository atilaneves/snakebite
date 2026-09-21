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

    return parseDescribeLists(describe(pkgDir,
        ["--data=" ~ dataKinds.join(","), "--data-list"], config).output,
        dataKinds.length);
}


public struct DubDescription {
    public imported!"std.json".JSONValue value;
    public string[] buildArguments;
}


public string fetchProject(in string packageName) {
    import std.process: Config, execute;
    import std.string: strip;

    const fetched = execute(["dub", "fetch", packageName], null, Config.none);
    if (fetched.status != 0)
        throw new Exception("dub fetch failed for `" ~ packageName ~ "`:\n"
            ~ fetched.output);

    const described = execute([
        "dub", "describe", packageName,
        "--data=working-directory", "--data-list",
    ], null, Config.none);
    if (described.status != 0)
        throw new Exception("dub describe failed for `" ~ packageName ~ "`:\n"
            ~ described.output);

    const directories = parseDescribeList(described.output);
    if (directories.length != 1)
        throw new Exception(
            "dub describe returned no project directory for `"
            ~ packageName ~ "`",
        );
    return directories[0].strip;
}


public DubDescription dubDescribeProject(
    in string directory, in string[] versions = null,
) {
    import std.json: parseJSON;
    import snakebite.dependencyimage: defaultCompiler;

    import std.algorithm.iteration: map;
    import std.array: array;

    const versionArguments = versions.map!(v => "--d-version=" ~ v).array;
    const result = describe(directory,
        ["--compiler=" ~ defaultCompiler] ~ versionArguments, DubConfig.test);
    return DubDescription(parseJSON(result.output),
        (result.buildArguments ~ versionArguments).dup);
}


private auto describe(
    in string directory, in string[] arguments, in DubConfig config,
) {
    import std.typecons: tuple;

    const command = ["dub", "describe"];
    if (config == DubConfig.test) {
        const testArguments = ["--config=unittest", "--build=unittest"];
        const result = describeCapturingStdout(
            command ~ testArguments ~ arguments, directory);
        if (result.status == 0)
            return tuple!("output", "buildArguments")(result.output, testArguments.dup);
    }
    const result = describeCapturingStdout(command ~ arguments, directory);
    if (result.status != 0)
        throw new Exception("dub describe failed in " ~ directory ~ ": " ~ result.output);
    return tuple!("output", "buildArguments")(result.output, ["--build=debug"]);
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

// Let dub decide which targets are stale, including the full dependency
// chain of static-library roots. The shared image needs position-
// independent archives, which both host compilers emit by default on the
// supported platform. The build must not add a PIC flag through `DFLAGS`:
// dub keys its build-cache artifacts by `DFLAGS` too, so a build with an
// environment that `dub describe` did not see produces artifacts at paths
// the description does not name.
public void buildDubDependencies(
    in string directory, in string stateDirectory,
    in DubDescription description, in string[] linkerFiles,
) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.exception: SnakebiteException;
    import std.process: Config, execute;

    import std.file: exists, mkdirRecurse, readText, write;
    import std.path: buildPath;

    const statePath = buildPath(stateDirectory, "dub-dependencies");
    const fingerprint = dependencyFingerprint(directory, description);
    const before = fileFingerprint(linkerFiles);
    import std.algorithm: all;
    if (linkerFiles.all!exists && statePath.exists
            && statePath.readText == fingerprint ~ before)
        return;

    const result = execute(["dub", "build", "--deep", "--compiler=" ~ defaultCompiler]
        ~ description.buildArguments, null, Config.none,
        size_t.max, directory);
    if (result.status != 0)
        throw new SnakebiteException("Dub dependency build failed:\n" ~ result.output);
    if (!linkerFiles.all!exists)
        throw new SnakebiteException("Dub build did not produce all dependency libraries");
    stateDirectory.mkdirRecurse;
    statePath.write(fingerprint ~ fileFingerprint(linkerFiles));
}


// The full description provides dependency sources that the root's flat
// import-files list does not contain. Root source contents are excluded:
// editing a guest module must not cause another native build.
private string dependencyFingerprint(in string directory, in DubDescription description) {
    import std.conv: text;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.path: buildPath;
    import std.process: environment;
    import snakebite.dependencyimage: defaultCompiler;

    return text("snakebite-dub-v1", defaultCompiler, __VERSION__,
        environment.get("DFLAGS", ""), environment.get("LFLAGS", ""),
        description.value.toString,
        fileFingerprint(dubInputs(directory, description))).sha256Of.toHexString.idup;
}


public string[] dubInputs(in string directory, in DubDescription description) {
    import std.path: buildPath;

    const value = description.value;
    string[] files = [buildPath(directory, "dub.selections.json")];
    foreach (package_; value["packages"].array) {
        if (!package_["active"].boolean)
            continue;
        const path = package_["path"].str;
        files ~= [buildPath(path, "dub.json"), buildPath(path, "dub.sdl"),
            buildPath(path, "dub.selections.json")];
        if (package_["name"].str == value["rootPackage"].str)
            continue;
        foreach (file; package_["files"].array) {
            const role = file["role"].str;
            if (role == "source" || role == "import" || role == "import_"
                    || role == "stringImport")
                files ~= buildPath(path, file["path"].str);
        }
    }
    foreach (target; value["targets"].array)
        foreach (file; target["buildSettings"]["extraDependencyFiles"].array)
            files ~= file.str;
    return files;
}


private string fileFingerprint(in string[] files) {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.file: exists, isFile, read;
    import std.conv: text;

    string result;
    foreach (file; files)
        result ~= text(file.length, ":", file, ":",
            file.exists && file.isFile ? read(file).sha256Of.toHexString.idup : "missing");
    return result.sha256Of.toHexString.idup;
}
