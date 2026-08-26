module bench.dub;


import bench.sources: SourceSet;


// dub's test configuration: the same sources, import paths and flags
// `dub test` itself would build with, so the bench mirrors the real
// workflow.
SourceSet dubSourceSet(in string directory) {
    import snakebite.dub: DubConfig, dubDescribe;
    import snakebite.frontend.compiler: FrontendFlags;
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.conv: text;

    auto files = dubDescribe(directory, "source-files", DubConfig.test);
    if (files.length == 0)
        throw new Exception(text("dub describe found no sources in ", directory));

    string[] compilerArguments =
        dubDescribe(directory, "dflags", DubConfig.test);
    compilerArguments ~= dubDescribe(directory, "versions", DubConfig.test)
        .map!(version_ => "-version=" ~ version_)
        .array;
    compilerArguments ~= dubDescribe(directory, "debug-versions", DubConfig.test)
        .map!(debugVersion => "-debug=" ~ debugVersion)
        .array;
    compilerArguments ~= dubDescribe(directory, "options", DubConfig.test)
        .map!(dmdFlagsForOption)
        .filter!(flag => flag.length > 0)
        .array;

    return SourceSet(
        files,
        dubDescribe(directory, "import-paths", DubConfig.test),
        dubDescribe(directory, "string-import-paths", DubConfig.test),
        dubDescribe(directory, "lflags", DubConfig.test),
        FrontendFlags(compilerArguments),
    );
}

// `dub describe --data=options` reports dub's own semantic option names
// (`unittests`, `debugMode`, ...), not compiler flags - every build type
// (not just configuration) contributes options this way, `-unittest`
// among them. This table is dub's own dmd binding
// (dub/source/dub/compilers/dmd.d, `dmdOptions`), copied because dub
// exposes no public API for it.
private string dmdFlagsForOption(in string option) {
    switch (option) {
        case "debugMode": return "-debug";
        case "releaseMode": return "-release";
        case "coverage": return "-cov";
        case "coverageCTFE": return "-cov=ctfe";
        case "debugInfo": return "-g";
        case "debugInfoC": return "-g";
        case "alwaysStackFrame": return "-gs";
        case "stackStomping": return "-gx";
        case "inline": return "-inline";
        case "noBoundsCheck": return "-noboundscheck";
        case "optimize": return "-O";
        case "profile": return "-profile";
        case "unittests": return "-unittest";
        case "verbose": return "-v";
        case "ignoreUnknownPragmas": return "-ignore";
        case "syntaxOnly": return "-o-";
        case "warnings": return "-wi";
        case "warningsAsErrors": return "-w";
        case "ignoreDeprecations": return "-d";
        case "deprecationWarnings": return "-dw";
        case "deprecationErrors": return "-de";
        case "property": return "-property";
        case "profileGC": return "-profile=gc";
        case "betterC": return "-betterC";
        case "lowmem": return "-lowmem";
        case "color": return "-color";
        // pic, singleFileD, _docs, _ddox and any future option: no bench
        // reason to care yet, and an unhandled dmd flag would be a worse
        // failure mode than silently dropping a dub-internal one.
        default: return null;
    }
}
