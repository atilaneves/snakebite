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
    import std.json: JSONValue;

    public JSONValue value;
    public string[] buildArguments;
}


// `dub fetch` without a version always asks the registry for the latest
// one, over the network, even when the package is already on disk. So ask
// the local cache first and fetch only when the package is not there.
public string fetchProject(in string packageName) {
    import std.string: strip;

    const firstDescribe = describeWorkingDirectory(packageName);
    const described = firstDescribe.status == 0
        ? firstDescribe
        : fetchAndDescribe(packageName, firstDescribe.output);
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

private auto fetchAndDescribe(in string packageName, in string describeOutput) {
    import std.process: Config, execute;

    const fetched = execute(["dub", "fetch", packageName], null, Config.none);
    if (fetched.status != 0)
        throw new Exception("dub fetch failed for `" ~ packageName ~ "`:\n"
            ~ fetched.output
            ~ "after dub describe failed:\n" ~ describeOutput);
    return describeWorkingDirectory(packageName);
}

private auto describeWorkingDirectory(in string packageName) {
    import std.process: Config, execute;

    return execute([
        "dub", "describe", packageName,
        "--data=working-directory", "--data-list",
    ], null, Config.none);
}


public DubDescription dubDescribeProject(
    in string directory, in string[] versions = null,
) {
    import std.json: parseJSON;
    import snakebite.dependencyimage: defaultCompiler;
    import std.algorithm.iteration: map;
    import std.array: array;
    import snakebite.dubcache: cachedDubDescription;
    import std.json: JSONValue;

    const versionArguments = versions.map!(v => "--d-version=" ~ v).array;
    const cached = cachedDubDescription(directory, defaultCompiler, versions, {
        const result = describe(directory,
            ["--compiler=" ~ defaultCompiler] ~ versionArguments, DubConfig.test);
        return JSONValue(["value": parseJSON(result.output),
            "arguments": JSONValue((result.buildArguments ~ versionArguments).dup)]);
    });
    return DubDescription(cached["value"],
        cached["arguments"].array.map!(v => v.str).array);
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
public auto describeCapturingStdout(in string[] command, in string pkgDir) {
    import std.process: Config, spawnProcess, wait;
    import std.algorithm.iteration: joiner;
    import std.array: array;
    import std.stdio: File, stdin;
    import std.typecons: tuple;

    // Capture stdout via an anonymous temp file rather than a pipe so a large
    // describe list cannot deadlock on a full pipe buffer. Each call has its
    // own file: callers on several threads describe at the same time. The file
    // stays open in this process after the spawn, to read it back.
    auto stdoutFile = File.tmpfile;
    auto devNull = File("/dev/null", "w");
    auto pid = spawnProcess(command, stdin, stdoutFile, devNull, null, Config.retainStdout, pkgDir);
    const status = wait(pid);
    stdoutFile.rewind;
    const output = cast(string) stdoutFile.byChunk(64 * 1024).joiner.array.idup;
    return tuple!("status", "output")(status, output);
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
    import std.process: Config, execute, environment;
    import std.algorithm: all;
    import std.file: exists, mkdirRecurse, readText, write, remove, rmdir;
    import std.path: buildPath;

    const statePath = buildPath(stateDirectory, "dub-dependencies");
    const fingerprint = dependencyFingerprint(directory, description);
    const before = fileFingerprint(linkerFiles);
    if (linkerFiles.all!exists && statePath.exists
            && statePath.readText == fingerprint ~ before)
        return;

    const wrapperDirectory = rootCompilerWrapper(description, stateDirectory);
    scope(exit) if (wrapperDirectory.length) {
        remove(buildPath(wrapperDirectory, defaultCompiler));
        rmdir(wrapperDirectory);
    }
    auto buildEnvironment = environment.toAA;
    if (wrapperDirectory.length)
        buildEnvironment["PATH"] = wrapperDirectory ~ ":" ~ buildEnvironment["PATH"];
    const result = execute(["dub", "build", "--deep", "--compiler=" ~ defaultCompiler]
        ~ description.buildArguments, buildEnvironment, Config.none,
        size_t.max, directory);
    if (result.status != 0)
        throw new SnakebiteException("Dub dependency build failed:\n" ~ result.output);
    if (!linkerFiles.all!exists)
        throw new SnakebiteException("Dub build did not produce all dependency libraries");
    stateDirectory.mkdirRecurse;
    statePath.write(fingerprint ~ fileFingerprint(linkerFiles));
}

// Keep dub's compiler identity and dependency cache paths. Only the root
// output gets translated flags; dependencies retain their own checks.
// A real build lets dub run its hooks and report every build failure.
private string rootCompilerWrapper(
    in DubDescription description, in string stateDirectory,
) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.frontend.checks: isCheckFlag, ldcArguments;
    import std.algorithm: startsWith;
    import std.array: array;
    import std.algorithm.iteration: map;
    import std.conv: octal;
    import std.json: JSONValue;
    import std.file: mkdirRecurse, setAttributes, write;
    import std.path: absolutePath, buildPath;
    import std.process: environment, escapeShellCommand;
    import std.uuid: randomUUID;

    if (defaultCompiler != "ldc2")
        return null;
    foreach (target; description.value["targets"].array) {
        if (target["rootPackage"].str != description.value["rootPackage"].str)
            continue;
        const settings = target["buildSettings"];
        const flags = settings["dflags"].array.map!(value => value.str).array;
        const translatedFlags = ldcArguments(flags);
        if (flags == translatedFlags)
            continue;
        const output = target["cacheArtifactPath"].str;
        string responseArgument(in string argument) {
            import std.algorithm: canFind;
            import std.string: replace;

            return argument.canFind(' ') || argument.canFind('\t') || argument.canFind('"')
                ? "\"" ~ argument.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\""
                : argument;
        }
        string rewrite = "BEGIN {\n";
        foreach (flag; flags)
            rewrite ~= "remove[" ~ JSONValue(responseArgument(flag)).toString ~ "] = 1;\n";
        rewrite ~= "}\n!($0 in remove) { print }\nEND {\n";
        foreach (flag; translatedFlags)
            rewrite ~= "print " ~ JSONValue(responseArgument(flag)).toString ~ ";\n";
        rewrite ~= "}\n";
        string[] outputArguments;
        foreach (suffix; ["", ".o"])
            foreach (prefix; ["-of", "-of=", "--of="])
                outputArguments ~= ["-e", responseArgument(prefix ~ output ~ suffix)];
        string[] checkArguments;
        foreach (flag; flags)
            if (isCheckFlag(flag) || flag.startsWith("@"))
                checkArguments ~= ["-e", responseArgument(flag)];
        const directory = buildPath(stateDirectory,
            "dub-compiler-" ~ randomUUID.toString).absolutePath;
        directory.mkdirRecurse;
        const script = "#!/bin/bash\nPATH="
            ~ escapeShellCommand([environment["PATH"]]) ~ "\nexport PATH\n"
            // dub serializes one argument per line in its compiler response
            // file. Replace those records, not the response-file grammar.
            ~ "for arg in \"$@\"; do\ncase \"$arg\" in @*)\nfile=${arg:1}\n"
            ~ "if grep -Fxq " ~ escapeShellCommand(outputArguments) ~ " -- \"$file\""
            ~ " && grep -Fxq " ~ escapeShellCommand(checkArguments) ~ " -- \"$file\"; then\n"
            ~ "temporary=$(mktemp " ~ escapeShellCommand([buildPath(directory, "arguments.XXXXXX")]) ~ ") || exit 1\n"
            ~ "trap 'rm -f -- \"$temporary\"' EXIT\nawk " ~ escapeShellCommand([rewrite])
            ~ " \"$file\" > \"$temporary\" || exit 1\n"
            ~ "args=()\nfor original in \"$@\"; do\n"
            ~ "if [[ $original == \"$arg\" ]]; then args+=(\"@$temporary\"); else args+=(\"$original\"); fi\ndone\n"
            ~ "ldc2 \"${args[@]}\"\nexit $?\nfi\n;;\nesac\ndone\n"
            ~ "root=false\nfor arg in \"$@\"; do\ncase \"$arg\" in\n"
            ~ escapeShellCommand(["-of" ~ output]) ~ "|"
            ~ escapeShellCommand(["-of=" ~ output]) ~ "|"
            ~ escapeShellCommand(["--of=" ~ output]) ~ "|"
            ~ escapeShellCommand(["-of" ~ output ~ ".o"]) ~ "|"
            ~ escapeShellCommand(["-of=" ~ output ~ ".o"]) ~ "|"
            ~ escapeShellCommand(["--of=" ~ output ~ ".o"])
            ~ ") root=true;;\nesac\ndone\n"
            ~ "if $root; then\nargs=(\"$@\")\nflags=(" ~ escapeShellCommand(flags) ~ ")\n"
            ~ "for ((i=0; i<=${#args[@]}-${#flags[@]}; ++i)); do\nmatch=true\n"
            ~ "for ((j=0; j<${#flags[@]}; ++j)); do\n"
            ~ "if [[ ${args[i+j]} != \"${flags[j]}\" ]]; then match=false; break; fi\ndone\n"
            ~ "if $match; then\nexec ldc2 \"${args[@]:0:i}\" "
            ~ escapeShellCommand(translatedFlags)
            ~ " \"${args[@]:i+${#flags[@]}}\"\nfi\ndone\nfi\nexec ldc2 \"$@\"\n";
        const path = buildPath(directory, defaultCompiler);
        path.write(script);
        path.setAttributes(octal!700);
        return directory;
    }
    return null;
}


// The full description provides dependency sources that the root's flat
// import-files list does not contain. Root source contents are excluded:
// editing a guest module must not cause another native build.
public string dependencyFingerprint(in string directory, in DubDescription description) {
    import std.conv: text;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.path: buildPath;
    import std.process: environment;
    import snakebite.dependencyimage: defaultCompiler;

    return text("snakebite-dub-v2", defaultCompiler, __VERSION__,
        environment.get("DFLAGS", ""), environment.get("LFLAGS", ""),
        description.value.toString, description.buildArguments,
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
