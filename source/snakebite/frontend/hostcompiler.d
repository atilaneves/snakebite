/// What the compiler that built this binary tells the frontend: where its
/// druntime and Phobos source lie, and which version identifiers it
/// predefines. The build records both (`reggaefile.d`) in a string import.
module snakebite.frontend.hostcompiler;

private:

// An LDC target links the frontend with LDC's additions (`reggaefile.d`);
// a missing import path would build the unpatched one.
version (LDC) {
    import dmd.dsymbol: Dsymbol;

    static assert(__traits(hasMember, Dsymbol, "llvmInternal"),
        "the frontend is not the one with LDC's additions");
}

public struct HostCompiler {
    string[] importPaths;
    string[] versionIdentifiers;
    string vendor; /// What `__VENDOR__` is.
}

/// The record that the build made for the compiler of this binary.
public HostCompiler hostCompiler() @safe pure {
    return parse(import("snakebite_host_compiler.txt"));
}

/// Lines are `import <path>`, `version <identifier>` and `vendor <name>`.
HostCompiler parse(in string record) @safe pure {
    import std.algorithm.searching: startsWith;
    import std.string: lineSplitter;

    HostCompiler result;
    foreach (line; record.lineSplitter) {
        if (line.startsWith("import "))
            result.importPaths ~= line["import ".length .. $];
        else if (line.startsWith("version "))
            result.versionIdentifiers ~= line["version ".length .. $];
        else if (line.startsWith("vendor "))
            result.vendor = line["vendor ".length .. $];
    }
    return result;
}
