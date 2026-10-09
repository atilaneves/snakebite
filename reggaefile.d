import reggae;
import reggae.config: configToDubInfo, options;
import reggae.dub.info: DubInfo;
import reggae.build: Build, Target;
import reggae.rules.dub: CompilationMode;
import reggae.rules.dub.runtime: dubBuild;
import reggae.types: CompilerFlags;
import std.algorithm: canFind, endsWith, filter, map, startsWith;
import std.array: array;
import std.process: environment, executeShell, escapeShellCommand;
import std.path: baseName, stripExtension;
import std.string: chomp;

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
// stub, ADR-0001; the interpreter's native-stack switch; the weak
// fallback for `dmd.astenums.Edition.init`). `cc` is what already
// understands `.cfi_` directives and `.note.GNU-stack`.
immutable string[] assembledSources = [
    "source/snakebite/ffi/sysv_amd64.S",
    "source/snakebite/backends/interpreter/interpreter_stack_amd64.S",
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
// executable. They are implicit inputs of an empty object that only
// `bin/ut` links, so that `ninja bin/ut` makes them and no other target
// needs a C or C++ compiler for them.
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
    if (config == "acceptance-test")
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
    const testHost = config == "unittest" || config == "acceptance-test";
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
            config == "unittest" ? testFixtureLibraries : [])] : [target];
}

Build reggaeBuild() {
    Target[] targets = assembledSources.map!assembledObject.array ~ [
        registryImageObject,
    ]
        ~ dubTarget("dmd", "unittest", "unittest", "ut")
        ~ dubTarget("ldc2", "acceptance-test", "release", "at", CompilerFlags("-release", "-O", "-flto=thin"))
        ~ dubTarget("ldc2", "sb", "release", "sb", CompilerFlags("-release", "-O", "-flto=thin"))
        ~ dubTarget("ldc2", "sb-repl", "release", "sb-repl", CompilerFlags("-release", "-O", "-flto=thin"))
        ~ dubTarget("ldc2", "bench", "release", "bench", CompilerFlags("-release", "-O", "-flto=thin"));
    return Build(targets);
}

mixin BuildgenMain;
