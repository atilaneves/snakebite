/// What the compiler that built this binary tells the frontend: where its
/// druntime and Phobos source lie, and which version identifiers it
/// predefines. The build records both (`reggaefile.d`) in a string import.
module snakebite.frontend.hostcompiler;

private:

public struct HostCompiler {
    string[] importPaths;
    string[] versionIdentifiers;
}

/// The record that the build made for the compiler of this binary.
public HostCompiler hostCompiler() @safe pure {
    return parse(import("snakebite_host_compiler.txt"));
}

/// Lines are `import <path>` and `version <identifier>`.
HostCompiler parse(in string record) @safe pure {
    import std.algorithm.searching: startsWith;
    import std.string: lineSplitter;

    HostCompiler result;
    foreach (line; record.lineSplitter) {
        if (line.startsWith("import "))
            result.importPaths ~= line["import ".length .. $];
        else if (line.startsWith("version "))
            result.versionIdentifiers ~= line["version ".length .. $];
    }
    return result;
}
