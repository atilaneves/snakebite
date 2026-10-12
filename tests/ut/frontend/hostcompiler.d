module ut.frontend.hostcompiler;


// The druntime source is the one of the compiler that built the host, found
// by the binary the build recorded; a missing compiler or an unusable
// configuration file is an error of the user's environment.


import snakebite.exception: SnakebiteException;
import snakebite.frontend.hostcompiler: HostCompiler, hostCompiler, hostImportPaths;
import std.file: mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: thisProcessID;
import std.conv: text;
import ut;


@("hostcompiler.recordedBinaryGivesImportPaths")
unittest {
    hostCompiler.binary.should.not == "";
    hostImportPaths(hostCompiler, null).length.should.not == 0;
}


@("hostcompiler.missingBinaryAndNoCompilerOnPathNamesBoth")
unittest {
    const host = HostCompiler([], "", "/nonexistent/compiler");
    hostImportPaths(host, null).shouldThrowWithMessage!SnakebiteException(
        "`/nonexistent/compiler` built this binary and is gone, and `"
        ~ vendorName ~ "` is not on PATH: its configuration file gives the import paths of "
        ~ "druntime and Phobos",
    );
}


@("hostcompiler.configurationWithoutImportPathNamesCompilerAndFile")
unittest {
    const directory = buildPath(tempDir, "snakebite-ut-hostcompiler-" ~ thisProcessID.text);
    directory.mkdirRecurse;
    scope(exit) directory.rmdirRecurse;
    const binary = buildPath(directory, vendorName);
    const configuration = buildPath(directory, vendorName ~ ".conf");
    binary.write("");
    configuration.write("");

    hostImportPaths(HostCompiler([], "", binary), null).shouldThrowWithMessage!SnakebiteException(
        "the configuration file `" ~ configuration ~ "` of `" ~ binary ~ "` gives no import path",
    );
}


version (LDC)
    private enum vendorName = "ldc2";
else
    private enum vendorName = "dmd";
