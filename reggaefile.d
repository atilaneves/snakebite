import reggae;
import reggae.config: configToDubInfo, options;
import reggae.dub.info: DubInfo;
import reggae.build: Build, Target;
import reggae.rules.dub: CompilationMode;
import reggae.rules.dub.runtime: dubBuild;
import reggae.types: CompilerFlags;
import std.algorithm: canFind, endsWith, filter, map, sort, startsWith;
import std.array: array;
import std.process: environment, executeShell, escapeShellCommand;
import std.exception: enforce;
import std.file: getcwd;
import std.path: baseName, buildPath, dirName, stripExtension;
import std.string: chomp, split, stripRight;

string ldcPath() {
    version (Windows)
        auto result = executeShell("where ldc2");
    else
        auto result = executeShell("command -v ldc2");
    return result.output.chomp;
}

// Native sources built by the system C compiler, not
// dmd/ldc, and linked into every dub target below - each for its own
// reason a comment on the source file itself explains (the FFI call
// stub, ADR-0001; the weak fallback for `dmd.astenums.Edition.init`).
// `cc` is what already
// understands `.cfi_` directives and `.note.GNU-stack`.
immutable string[] assembledSources = [
    "source/snakebite/ffi/sysv_amd64.S",
    "source/dmd/iasm/edition_init_amd64.S",
];

// `$project` keeps this target's own output text identical to the
// reference `dubTarget` adds to each dub package's file list
// (`info.packages[0].files`), so reggae's ninja backend resolves both
// to the same path and links the one object it actually builds.
//
// The object lands in the project root, not under `$builddir`
// (`.reggae/objs`, already covered by that directory's own `.gitignore`
// entry) or a `.reggae/objs`-rooted path directly: tried, and it broke
// the build. `$builddir/...` here expands correctly in this `Target`'s
// own name (reggae's `expandOutput`, `build.d`), but the identical
// string in `info.packages[0].files` - which a dub `DubPackage`'s file
// list does not run through that same expansion - reaches the
// generated `build.ninja` as a literal, unexpanded `$builddir` token
// glued onto an absolute path, which ninja then cannot resolve to the
// object this `Target` actually builds. `*.o` stays in `.gitignore`.
string assembledObjectPath(in string source) {
    return "$project/" ~ source.baseName.stripExtension ~ ".o";
}

Target assembledObject(in string source) {
    return Target(
        assembledObjectPath(source),
        "cc -c $in -o $out",
        Target(source),
    );
}

// The registry image of `source/snakebite/backends/guestmodules.d`: a shared
// object that the system C compiler makes from a tiny C file, and the object
// that embeds its bytes. Linked into every target like the `.S` files above,
// so no compiler is needed at run time to make it.
enum registrySlotSource = "source/snakebite/backends/registry_slot.c";
enum registryImageSource = "source/snakebite/backends/registry_image_amd64.S";

Target registryImageObject() {
    return Target(
        assembledObjectPath(registryImageSource),
        "cc -c $in -o $out -I$project",
        Target(registryImageSource),
        [Target(
            "$project/registry_slot.so",
            "cc -shared -fPIC -nostdlib -o $out $in",
            Target(registrySlotSource),
        ), Target("build/host-exports.map")],
    );
}

// The native libraries that `bin/ut` loads, built here so that no test
// starts a compiler for them. They lie in `bin/fixtures`, next to the test
// executable. They are implicit inputs of an empty object linked by
// `bin/ut` and `bin/arena`, so either target builds its own test fixtures.
Target testFixtureObject(in string objectSet, Target exportMap,
                         Target[] libraries) {
    return Target(
        "$project/" ~ objectSet ~ "_host_exports.o",
        "cc -x c -c /dev/null -o $out",
        Target[].init,
        libraries ~ exportMap,
    );
}

Target[] testFixtureLibraries() {
    return [
        Target(
            "$project/bin/fixtures/symbols.so",
            "cc -shared -fPIC -o $out $in",
            Target("tests/fixtures/native/symbols.c"),
        ),
        Target(
            "$project/bin/fixtures/cpp_image.so",
            "c++ -shared -fPIC -O2 -std=c++17 -o $out $in",
            Target("tests/fixtures/native/cpp_image.cpp"),
        ),
    ];
}

// What the compiler of this target says about itself (`-v`): its import
// paths and predefined version identifiers. The frontend inside the
// binary analyses that druntime source in the way that compiler does
// (`snakebite.frontend.hostcompiler`). Written when the build is
// generated, to a directory of its own per object set, and given to the
// compiler as a string import path.
string hostCompilerRecordDirectory(in string compiler, in string objectSet) {
    import std.file: mkdirRecurse, write;
    import std.path: absolutePath;
    import std.process: execute;
    import std.string: lineSplitter, split;

    const binary = compiler.executablePath.absolutePath;
    const result = execute([compiler, "-v", "-c", "-o-", "/dev/null"]);
    string record;
    foreach (line; result.output.lineSplitter) {
        if (line.startsWith("predefs"))
            foreach (identifier; line["predefs".length .. $].split)
                record ~= "version " ~ identifier ~ "\n";
    }
    enforce(record.length, compiler ~ " -v gave no predefs");
    const probe = pinnedFrontendProbe(compiler);
    record ~= "vendor " ~ probe.vendor ~ "\n";
    record ~= "compiler " ~ binary ~ "\n";
    const directory = buildPath(getcwd, ".reggae", "host-compiler", objectSet);
    mkdirRecurse(directory);
    write(buildPath(directory, "snakebite_host_compiler.txt"), record);
    write(buildPath(directory, "snakebite_host_features.txt"),
        probe.vendor == "LDC" ? ldcFeatureNames(compiler) : "");
    return directory;
}

// `compiler` as a path: itself when it names a path, else the first file of
// that name on `PATH`.
string executablePath(in string compiler) {
    import std.file: exists, isFile;

    if (compiler.canFind("/"))
        return compiler.idup;
    foreach (directory; environment.get("PATH", "").split(":")) {
        const candidate = buildPath(directory.length ? directory : ".", compiler);
        if (candidate.exists && candidate.isFile)
            return candidate;
    }
    throw new Exception(compiler ~ " is not on PATH");
}

// The probe of `compiler`, when its frontend is the one that snakebite links.
CompilerProbe pinnedFrontendProbe(in string compiler) {
    import std.conv: text;

    const probe = compilerProbe(compiler);
    const library = dmdLibraryVersion;
    enforce(probe.frontendVersion == library.number,
        compiler ~ " has the frontend version " ~ probe.frontendVersion.text
        ~ " but the dmd frontend library is " ~ library.number.text);
    return probe;
}

// What `__traits(targetHasFeature)` can be asked, one name on each line.
string ldcFeatureNames(in string compiler) {
    import std.process: execute;
    import std.regex: matchFirst, regex;
    import std.string: lineSplitter;

    const help = execute([compiler, "-mattr=help"]).output;
    string names;
    bool inFeatures;
    foreach (line; help.lineSplitter) {
        if (line.startsWith("Available features"))
            inFeatures = true;
        else if (inFeatures)
            if (const feature = line.matchFirst(regex(`^  (\S+)\s+- `)))
                names ~= feature[1] ~ "\n";
    }
    enforce(names.length, compiler ~ " -mattr=help lists no features");
    return names;
}

// What `__VENDOR__` and `__VERSION__` are for `compiler`: the strings a guest
// sees, and the version of the frontend that the compiler contains.
struct CompilerProbe {
    string vendor;
    uint frontendVersion;
}

// The probe runs once for each compiler: every target of the build asks.
CompilerProbe compilerProbe(in string compiler) {
    static CompilerProbe[string] probes;
    if (auto known = compiler in probes)
        return *known;
    return probes[compiler] = runProbe(compiler);
}

// A directory that is gone when its owner goes out of scope.
struct TemporaryDirectory {
    string path;

    this(string path) {
        import std.file: mkdirRecurse;

        this.path = path;
        mkdirRecurse(path);
    }

    ~this() {
        import std.file: exists, rmdirRecurse;

        if (path.exists)
            rmdirRecurse(path);
    }

    @disable this(this);
}

CompilerProbe runProbe(in string compiler) {
    import std.conv: text, to;
    import std.file: tempDir, write;
    import std.process: execute, thisProcessID;
    import std.string: strip;

    scope directory = TemporaryDirectory(
        buildPath(tempDir, "snakebite-probe-" ~ thisProcessID.text));
    const source = buildPath(directory.path, "probe.d");
    write(source, `pragma(msg, __VENDOR__, "|", __VERSION__);`);
    const result = execute([compiler, "-c", "-o-", source]);
    enforce(result.status == 0, compiler ~ " cannot compile the probe: " ~ result.output);
    const fields = result.output.strip.split("|");
    enforce(fields.length == 2, "unexpected probe output: " ~ result.output);
    return CompilerProbe(fields[0], fields[1].strip.chomp("L").to!uint);
}

// The frontend that snakebite links, from the dub selection of `dmd`.
struct DmdLibraryVersion {
    string text; /// For example `2.113.0`.
    uint number; /// For example `2113`.
}

DmdLibraryVersion dmdLibraryVersion() {
    import std.conv: to;
    import std.file: readText;
    import std.json: parseJSON;

    const text = readText(buildPath(getcwd, "dub.selections.json"))
        .parseJSON["versions"]["dmd"].str;
    const parts = text.split(".");
    return DmdLibraryVersion(text, parts[0].to!uint * 1000 + parts[1].to!uint);
}

// For an LDC target the frontend is the pinned package source plus the
// additions that LDC makes to the same frontend version
// (`vendor/ldc-frontend`), because the source that LDC compiles uses them:
// its pragmas, its traits, 64-byte vectors, and intrinsics that the
// compile-time interpreter evaluates. The build stops, and names both
// versions, when `compiler` and the patch do not belong to the pin.
DubInfo withLdcFrontend(DubInfo info, in string compiler, in CompilerProbe probe) {
    import std.file: dirEntries, exists, isDir, SpanMode;
    import std.process: execute;
    import std.regex: matchFirst, regex;

    enforce(probe.vendor == "LDC", compiler ~ " is not LDC but the vendor is `" ~ probe.vendor ~ "`");
    const pin = dmdLibraryVersion.text;
    const versionText = execute([compiler, "--version"]).output;
    const ldcVersion = versionText.matchFirst(regex(`\((\d+\.\d+)\.\d+\)`));
    enforce(ldcVersion, compiler ~ " --version does not give an LDC version: " ~ versionText);

    const prefix = "dmd-" ~ pin ~ "-ldc-";
    const patches = buildPath(getcwd, "vendor", "ldc-frontend");
    const patchDirectory = buildPath(patches, prefix ~ ldcVersion[1]);
    if (!patchDirectory.exists || !patchDirectory.isDir) {
        import std.array: join;

        auto others = dirEntries(patches, SpanMode.shallow)
            .filter!(entry => entry.isDir && entry.name.baseName.startsWith(prefix))
            .map!(entry => entry.name.baseName[prefix.length .. $]).array;
        enforce(others.length,
            "there is no patch of LDC's additions for the dmd frontend " ~ pin
            ~ " (vendor/ldc-frontend/" ~ prefix ~ "*), and " ~ compiler ~ " is LDC " ~ ldcVersion[1]);
        throw new Exception("the patch of LDC's additions for the dmd frontend " ~ pin
            ~ " is for LDC " ~ others.join(", ") ~ " but " ~ compiler ~ " is LDC " ~ ldcVersion[1]);
    }

    const frontendPackages = info.packages.filter!(a => a.name.startsWith("dmd:")).array;
    enforce(frontendPackages.length, "no dmd:* package in the dub description");
    const packageDirectory = frontendPackages[0].path.stripRight("/");
    const frontend = patchedFrontendDirectory(packageDirectory, patchDirectory, pin);

    foreach (ref package_; info.packages) {
        foreach (ref path; package_.files)
            path = path.moveTree(packageDirectory, frontend);
        foreach (ref path; package_.importPaths)
            path = path.moveTree(packageDirectory, frontend);
        foreach (ref path; package_.cImportPaths)
            path = path.moveTree(packageDirectory, frontend);
        foreach (ref path; package_.stringImportPaths)
            path = path.moveTree(packageDirectory, frontend);
        package_.path = package_.path.moveTree(packageDirectory, frontend);
        if (package_.name == "dmd:frontend")
            package_.files ~= buildPath(frontend, "compiler", "src", "dmd", "hooks.d")
                ~ dirEntries(buildPath(frontend, "compiler", "src", "gen"), "*.d", SpanMode.shallow)
                    .map!(entry => entry.name).array;
    }
    return info;
}

string moveTree(in string path, in string from, in string to) {
    return path.startsWith(from) ? to ~ path[from.length .. $] : path;
}

// A copy of the pinned package with the patch applied, and the modules that
// the patch imports. Made again only when its inputs change, so that the
// time stamps of the sources stay and ninja does not rebuild the frontend.
string patchedFrontendDirectory(in string packageDirectory, in string patchDirectory, in string pin) {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.file: copy, dirEntries, exists, isDir, mkdirRecurse, readText, rmdirRecurse, SpanMode, write;
    import std.process: execute;

    const root = buildPath(getcwd, ".reggae", "ldc-frontend", pin);
    const patchFile = buildPath(patchDirectory, patchDirectory.baseName ~ ".patch");
    const generatedSources = dirEntries(buildPath(patchDirectory, "gen"), "*.d", SpanMode.shallow)
        .map!(entry => entry.name).array.sort.release;

    ubyte[] inputs = cast(ubyte[]) (packageDirectory ~ readText(patchFile));
    foreach (source; generatedSources)
        inputs ~= cast(ubyte[]) (source ~ readText(source));
    const stamp = sha256Of(inputs).toHexString.idup;
    const stampFile = buildPath(root, "stamp");
    if (stampFile.exists && readText(stampFile) == stamp)
        return root;

    if (root.exists)
        rmdirRecurse(root);
    foreach (relative; ["compiler/src", "generated/dub"])
        foreach (entry; dirEntries(buildPath(packageDirectory, relative), SpanMode.depth)) {
            const target = buildPath(root, entry.name[packageDirectory.length + 1 .. $]);
            if (entry.isDir)
                mkdirRecurse(target);
            else {
                mkdirRecurse(target.dirName);
                copy(entry.name, target);
            }
        }
    const applied = execute(["patch", "-p1", "-d", buildPath(root, "compiler", "src"), "-i", patchFile]);
    enforce(applied.status == 0, "the patch " ~ patchFile ~ " does not apply to "
        ~ packageDirectory ~ ": " ~ applied.output);
    const generatedDirectory = buildPath(root, "compiler", "src", "gen");
    mkdirRecurse(generatedDirectory);
    foreach (source; generatedSources)
        copy(source, buildPath(generatedDirectory, source.baseName));
    write(stampFile, stamp);
    return root;
}

Target[] dubTarget(string compiler, string config, string objectSet,
                 string output, CompilerFlags flags = CompilerFlags()) {
    auto buildOptions = options.dup;
    buildOptions.dubObjsDir = "$builddir/.reggae/objs/bin/"
        ~ objectSet ~ ".objs";
    buildOptions.dCompiler = compiler == "dmd"
        ? options.dCompiler
        : environment.get("LDC", ldcPath());
    if (compiler != "dmd")
        buildOptions.dubBuildType = "release";

    DubInfo info = configToDubInfo[config].dup;
    if (compiler != "dmd")
        info = info.withLdcFrontend(buildOptions.dCompiler,
            pinnedFrontendProbe(buildOptions.dCompiler));
    if (config == "acceptance-test" || config == "arena-validation")
        info.packages[0].dflags ~= "-unittest";
    if (compiler != "dmd") {
        foreach (ref package_; info.packages)
            package_.dflags = package_.dflags
                .filter!(a => a != "-debug" && a != "-g")
                .array;
        // LDC needs -flto and the same optimisation level on both the
        // compile and link commands: ThinLTO's codegen happens at link
        // time from the merged/imported IR, so without -O there the
        // linker backend recompiles everything at -O0, throwing away the
        // per-object optimisation the compile step already did. dub.sdl's
        // own `lflags` get wrapped as `-L<flag>` (raw linker pass-through),
        // which breaks LDC-level flags like these, so they are appended
        // here instead, unwrapped, straight onto the link command.
        if (flags.value.canFind!(a => a.startsWith("-flto")))
            // GCC's own LTO driver cannot consume LLVM bitcode objects: it
            // hands them to the LLVMgold plugin using its own lto-wrapper
            // protocol, which the plugin doesn't understand. Telling LDC to
            // invoke clang for linking sidesteps that mismatch without
            // pinning a specific linker; whichever `ld` is the system
            // default (this machine's is mold) still gets used.
            info.packages[0].lflags ~= flags.value ~ "-gcc=clang";
    }
    // The executable and loaded D images must share one runtime.
    info.packages[0].lflags ~= compiler == "dmd"
        ? "-defaultlib=libphobos2.so" : "-link-defaultlib-shared";
    info.options = buildOptions;
    info.packages[0].stringImportPaths ~=
        hostCompilerRecordDirectory(buildOptions.dCompiler, objectSet);
    if (compiler == "dmd")
        info.packages[0].importPaths = info.packages[0].importPaths
            .filter!(a => a.baseName != "tests" && a.baseName != "acceptance")
            .array ~ ["tests", "acceptance"];
    info.packages[0].targetPath = "bin";
    info.packages[0].targetFileName = objectSet;
    // Links each hand-written `.S` object into this target - see
    // `assembledSources`. Reggae sweeps a dub package's own `.o` files
    // into the same link line as the D-compiled ones.
    info.packages[0].files ~= assembledSources.map!assembledObjectPath.array
        ~ assembledObjectPath(registryImageSource);
    const unitHost = config == "unittest" || config == "arena-validation";
    const testHost = unitHost || config == "acceptance-test";
    if (testHost)
        info.packages[0].files ~= "$project/" ~ objectSet ~ "_host_exports.o";

    auto exportMap = Target("build/host-exports.map");
    if (testHost) {
        string[] arguments = [buildOptions.dCompiler, "-c", "-o-", "-unittest"];
        if (config == "acceptance-test")
            arguments ~= compiler == "dmd"
                ? "-version=SnakebiteAcceptanceHostExports"
                : "-d-version=SnakebiteAcceptanceHostExports";
        foreach (package_; info.packages) {
            arguments ~= package_.importPaths.map!(path => "-I" ~ path).array;
            arguments ~= package_.stringImportPaths.map!(path => "-J" ~ path).array;
            arguments ~= package_.versionFlags(buildOptions.dCompiler.baseName).array;
            arguments ~= package_.dflags;
        }
        exportMap = Target(
            "$project/.reggae/" ~ output ~ "-host-exports.map",
            "python3 $project/build/host_exports.py $out "
                ~ escapeShellCommand(arguments) ~ " $in",
            Target("build/host_exports.d"),
            [Target("build/host_exports.py"), Target("build/host-exports.map"),
                Target(buildOptions.dCompiler)]
                ~ info.packages[0].files
                    .filter!(path => path.endsWith(".d"))
                    .map!(path => Target(path)).array,
        );
        info.packages[0].lflags = info.packages[0].lflags
            .map!(flag => flag.canFind("--version-script=")
                ? "-L--version-script=" ~ exportMap.rawOutputs[0] : flag).array;
    }
    auto target = dubBuild(buildOptions, info, CompilationMode.options, flags);
    target.rawOutputs[0] = "bin/" ~ output;
    return testHost
        ? [target, testFixtureObject(objectSet, exportMap,
            unitHost ? testFixtureLibraries : [])] : [target];
}

Build reggaeBuild() {
    // Function alignment fixes the addresses of the VM handlers.
    auto releaseFlags = CompilerFlags("-release", "-O", "-flto=thin",
        "-L-plugin-opt=-align-all-functions=6");
    Target[] targets = assembledSources.map!assembledObject.array ~ [
        registryImageObject,
    ]
        ~ dubTarget("dmd", "unittest", "unittest", "ut")
        ~ dubTarget("dmd", "arena-validation", "arena-validation", "arena")
        ~ dubTarget("ldc2", "acceptance-test", "release", "at", releaseFlags)
        ~ dubTarget("ldc2", "sb", "release", "sb", releaseFlags)
        ~ dubTarget("ldc2", "sb-repl", "release", "sb-repl", releaseFlags)
        ~ dubTarget("ldc2", "bench", "release", "bench", releaseFlags);
    return Build(targets);
}

mixin BuildgenMain;
