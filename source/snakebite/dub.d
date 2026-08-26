module snakebite.dub;

private:

// The import paths a dub package contributes to a build: its own source path
// plus those of its transitive dependencies. Feeding these to a frontend makes
// `import <pkg>` (and any transitive module) resolve the way `dub test` does.
public string[] dubImportPaths(in string name) {
    return dubDescribe(findPkgDir(name), "import-paths");
}

// Build the package so its dependency archives exist on disk for the dependency
// image (`buildDubDependencyImage`). Plain `dub build`, no compiler shim: dub
// already knows the build, and the frontend-relevant flags are asked for
// directly via `dubCompilerArguments`. dmd, so the archives' druntime and
// extern(D) ABI match the DMD-codegen'd project and the DMD-built run executor.
public void dubBuild(in string packageName, in string pkgDir) {
    import std.process: Config, execute;

    auto result = execute(
        ["dub", "build", "--config=unittest", "--compiler=dmd"],
        null, Config.none, size_t.max, pkgDir,
    );
    // Packages without a unittest configuration still build under the default.
    if (result.status != 0)
        result = execute(
            ["dub", "build", "--compiler=dmd"],
            null, Config.none, size_t.max, pkgDir,
        );
    if (result.status != 0)
        throw new Exception(
            "dub build failed for " ~ packageName ~ ": " ~ result.output,
        );
}

// The frontend-relevant compiler flags dub chose for the unittest build, asked
// for directly via `dub describe` and forwarded verbatim: dflags (e.g.
// -preview=dip1000/dip1008), versions, debug versions, and string-import paths.
// dub already reports all of this, so snakebite just relays it.
public string[] dubCompilerArguments(
    in string pkgDir,
    in DubConfig config = DubConfig.test,
) {
    string[] args = dubDescribe(pkgDir, "dflags", config);
    foreach (version_; dubDescribe(pkgDir, "versions", config))
        args ~= "-version=" ~ version_;
    foreach (debugVersion; dubDescribe(pkgDir, "debug-versions", config))
        args ~= "-debug=" ~ debugVersion;
    foreach (stringImportPath; dubDescribe(pkgDir, "string-import-paths", config))
        args ~= "-J=" ~ stringImportPath;
    return args;
}

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
    const describe = ["dub", "describe"];
    const dataArgs = ["--data=" ~ dataKind, "--data-list"];

    if (config == DubConfig.test) {
        // `--build=unittest` too: without it, describe reports the default
        // build type's flags, not the unittest build type's - missing
        // `-unittest` itself among others, since dub adds those per build
        // type, not per config.
        auto withUnittest = describeCapturingStdout(  // auto: need status and output
            describe ~ ["--config=unittest", "--build=unittest"] ~ dataArgs, pkgDir,
        );
        if (withUnittest.status == 0)
            return parseDescribeList(withUnittest.output);
    }

    const fallback = describeCapturingStdout(describe ~ dataArgs, pkgDir);
    if (fallback.status != 0)
        throw new Exception(
            "dub describe " ~ dataKind ~ " failed in " ~ pkgDir ~ ": "
            ~ fallback.output,
        );

    return parseDescribeList(fallback.output);
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

// Collapse dub-built dependency archives into the native dependency image used
// by the hot project link. The project itself is not part of this image.
// `systemLibs` and `linkerFlags` are dub's own `libs`/`lflags` for the package,
// forwarded so the image resolves the external C libraries its dependencies need
// (e.g. vibe-d's `ssl`/`crypto`); without them the image loads with undefined
// symbols like `RAND_poll`.
public string buildDubDependencyImage(
    in string packageName,
    in string[] dependencyArchives,
    in string outDir,
    in string[] systemLibs = null,
    in string[] linkerFlags = null,
) {
    import std.algorithm.iteration: map;
    import std.array: array, join;
    import std.conv: text;
    import std.file: exists, mkdirRecurse, remove, write;
    import std.path: buildPath, setExtension;
    import std.process: escapeShellFileName, execute;

    mkdirRecurse(outDir);
    const imagePath = buildPath(outDir, "lib" ~ packageName ~ "_dub_deps.so");
    const linkInputPath = buildPath(outDir, ".snakebite_dub_deps_link.d");
    const linkerResponsePath =
        buildPath(outDir, ".snakebite_dub_deps_link.rsp");
    const generatedPaths = [
        linkInputPath,
        linkerResponsePath,
        imagePath.setExtension("o"),
    ];
    scope(exit)
        foreach (path; generatedPaths)
            if (path.exists)
                path.remove;

    write(linkInputPath, "module snakebite_dub_dependency_image_link;\n");
    const linkerArguments = ["--whole-archive"]
        ~ dependencyArchives
        ~ "--no-whole-archive"
        ~ systemLibs.map!(lib => "-l" ~ lib).array
        ~ linkerFlags;
    // DMD groups linker options separately from linker files, which would move
    // the whole-archive delimiters away from the archives. A compiler-driver
    // response keeps every linker argument in its original order.
    write(
        linkerResponsePath,
        linkerArguments
            .map!(argument =>
                "-Xlinker\n" ~ argument.escapeShellFileName ~ "\n")
            .join,
    );

    const command = [
        "dmd",
        "-shared",
        "-fPIC",
        "-defaultlib=libphobos2.so",
        "-of=" ~ imagePath,
        linkInputPath,
        "-Xcc=@" ~ linkerResponsePath,
    ];

    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text(
            "dependency image link failed for ",
            packageName,
            ": ",
            result.output,
        ));

    return imagePath;
}

public string findPkgDir(in string name) {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: dirEntries, exists, isDir, SpanMode;
    import std.path: baseName, buildPath, expandTilde;
    import std.process: execute;
    import std.string: startsWith;

    // A name that is an existing directory with a dub recipe is a local
    // checkout (e.g. `--dub ~/coding/d/tardy`): bench the same instance
    // `dub test` runs in, skipping the registry cache entirely.
    const localDir = name.expandTilde;
    if (localDir.exists && localDir.isDir)
        foreach (recipe; ["dub.sdl", "dub.json"])
            if (buildPath(localDir, recipe).exists)
                return localDir;

    const cache = expandTilde("~/.dub/packages");

    // Handles both cache layouts:
    //   new: ~/.dub/packages/<name>/<version>/<name>/
    //   old: ~/.dub/packages/<name>-<version>/<name>/
    string[] scan() {
        if (!cache.exists) return [];
        const newStyle = buildPath(cache, name);
        if (newStyle.exists)
            return dirEntries(newStyle, SpanMode.shallow)
                .filter!(e => e.isDir)
                .map!(e => buildPath(e.name, name))
                .filter!(p => p.exists)
                .array;
        return dirEntries(cache, SpanMode.shallow)
            .filter!(e => e.isDir && e.name.baseName.startsWith(name ~ "-"))
            .map!(e => buildPath(e.name, name))
            .filter!(p => p.exists)
            .array;
    }

    auto found = scan;  // auto: mutable for sort and re-fetch
    if (found.length == 0) {
        execute(["dub", "fetch", name]);
        found = scan;
    }
    if (found.length == 0)
        throw new Exception("could not find package '" ~ name ~ "' in dub cache");
    found.sort;
    return found[$ - 1];
}
