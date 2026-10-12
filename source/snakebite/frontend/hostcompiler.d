/// What the compiler that built this binary tells the frontend: where its
/// druntime and Phobos source lie, and which version identifiers it
/// predefines. The build (`reggaefile.d`) records the identifiers and the
/// binary in a string import; the import paths come from the configuration
/// file of that binary when the frontend is set up.
module snakebite.frontend.hostcompiler;

private:

import snakebite.exception: SnakebiteException;

// An LDC target links the frontend with LDC's additions (`reggaefile.d`);
// a missing import path would build the unpatched one.
version (LDC) {
    import dmd.dsymbol: Dsymbol;

    static assert(__traits(hasMember, Dsymbol, "llvmInternal"),
        "the frontend is not the one with LDC's additions");
}

public struct HostCompiler {
    string[] versionIdentifiers;
    string vendor; /// What `__VENDOR__` is.
    string binary; /// Absolute path of the compiler that built this binary.
}

/// The record that the build made for the compiler of this binary.
public HostCompiler hostCompiler() @safe pure {
    return parse(import("snakebite_host_compiler.txt"));
}

/// Lines are `version <identifier>`, `vendor <name>` and `compiler <path>`.
private HostCompiler parse(in string record) @safe pure {
    import std.algorithm.searching: startsWith;
    import std.string: lineSplitter;

    HostCompiler result;
    foreach (line; record.lineSplitter) {
        if (line.startsWith("version "))
            result.versionIdentifiers ~= line["version ".length .. $];
        else if (line.startsWith("vendor "))
            result.vendor = line["vendor ".length .. $];
        else if (line.startsWith("compiler "))
            result.binary = line["compiler ".length .. $];
    }
    return result;
}

// The binary of the compiler that built this host, by its own name: the
// compiler of another vendor on `PATH` is not it.
version (LDC)
    private enum compilerName = "ldc2";
else version (DigitalMars)
    private enum compilerName = "dmd";
else
    static assert(false, "the host is built by a compiler that has no configuration file here");

/// The import paths in the configuration file of the compiler that built
/// this binary: the binary the build recorded, and only when that file is
/// gone the compiler of the same vendor on `PATH` (`onPath`). An environment
/// without the compiler, or a configuration file without an import path, is
/// an error of the user's environment: it throws a `SnakebiteException`.
/// Call it outside the frontend's arena, which must hold no pointer to the
/// garbage-collected heap.
public string[] hostImportPaths(in HostCompiler host, lazy string onPath = firstOnPath(compilerName)) {
    import dmd.frontend: findDMDConfig, findLDCConfig;
    import std.file: exists, isFile;
    import std.path: dirName;

    const binary = host.binary.exists && host.binary.isFile
        ? host.binary
        : onPath;
    if (binary is null)
        throw new SnakebiteException("`" ~ host.binary ~ "` built this binary and is gone, and `"
            ~ compilerName ~ "` is not on PATH: its configuration file gives the import paths of "
            ~ "druntime and Phobos");

    version (LDC)
        const configuration = findLDCConfig(binary);
    else
        const configuration = findDMDConfig(binary);
    if (configuration is null || !configuration.exists)
        throw new SnakebiteException("`" ~ binary ~ "` has no configuration file (`"
            ~ configurationFile ~ "`)");

    const paths = importPathsOf(configuration, binary.dirName);
    if (paths.length == 0)
        throw new SnakebiteException("the configuration file `" ~ configuration ~ "` of `"
            ~ binary ~ "` gives no import path");
    return paths.dup;
}

// LDC reads a directory of `*.conf` files in name order as well as one file;
// `findLDCConfig` returns the directory as it finds it.
private string[] configurationFiles(in string configuration) {
    import std.algorithm.iteration: map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: dirEntries, isDir, SpanMode;

    if (!configuration.isDir)
        return [configuration.dup];
    return configuration.dirEntries("*.conf", SpanMode.shallow)
        .map!(entry => entry.name).array.sort.release;
}

// What `dmd.frontend.parseImportPathsFromConfig` returns for the same file.
// That function cannot be called from here: it infers `@safe` under this
// project's `-preview=dip1000` and the frontend library was built without
// it, so the symbol the call needs does not exist.
private string[] importPathsOf(in string configuration, in string binaryDirectory) {
    import std.algorithm.iteration: filter, joiner, map, uniq;
    import std.algorithm.sorting: sort;
    import std.array: array, replace;
    import std.path: buildNormalizedPath;
    import std.regex: matchAll, regex;
    import std.stdio: File;

    return configurationFiles(configuration)
        .map!(file => File(file, "r").byLineCopy)
        .joiner
        .map!(line => line.matchAll(regex(`-I[^ "]+`)).joiner)
        .joiner
        .map!(option => option[2 .. $]
            .replace("%@P%", binaryDirectory)
            .replace("%%ldcbinarypath%%", binaryDirectory))
        .array.sort.uniq
        .map!(path => buildNormalizedPath(path))
        .array;
}

version (LDC)
    private enum configurationFile = "ldc2.conf";
else
    private enum configurationFile = "dmd.conf";

// The first file of that name in a directory of `PATH`, or null.
private string firstOnPath(in string name) {
    import std.file: exists, isFile;
    import std.path: buildPath;
    import std.process: environment;
    import std.string: split;

    foreach (directory; environment.get("PATH", "").split(":")) {
        const candidate = buildPath(directory.length ? directory : ".", name);
        if (candidate.exists && candidate.isFile)
            return candidate;
    }
    return null;
}
