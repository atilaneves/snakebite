import reggae;
import reggae.config: configToDubInfo, options;
import reggae.dub.info: DubInfo;
import reggae.build: Build, Target;
import reggae.rules.dub: CompilationMode;
import reggae.rules.dub.runtime: dubBuild;
import reggae.types: CompilerFlags;
import std.algorithm: canFind, filter, startsWith;
import std.array: array;
import std.process: environment, executeShell;
import std.path: baseName;
import std.string: chomp;

string ldcPath() {
    version (Windows)
        auto result = executeShell("where ldc2");
    else
        auto result = executeShell("command -v ldc2");
    return result.output.chomp;
}

Target dubTarget(string compiler, string config, string objectSet,
                 string output, CompilerFlags flags = CompilerFlags()) {
    auto buildOptions = options.dup;
    buildOptions.dubObjsDir = "$builddir/.reggae/objs/bin/"
        ~ objectSet ~ ".objs";
    buildOptions.allAtOnce = compiler == "dmd";
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
    info.options = buildOptions;
    if (compiler == "dmd")
        info.packages[0].importPaths = info.packages[0].importPaths
            .filter!(a => a.baseName != "tests" && a.baseName != "acceptance")
            .array ~ ["tests", "acceptance"];
    info.packages[0].targetPath = "bin";
    info.packages[0].targetFileName = objectSet;

    auto target = dubBuild(buildOptions, info, CompilationMode.options, flags);
    target.rawOutputs[0] = "bin/" ~ output;
    return target;
}

Build reggaeBuild() {
    auto build = Build(
        dubTarget("dmd", "unittest", "unittest", "ut"),
        dubTarget("dmd", "acceptance-test", "acceptance", "at"),
        dubTarget("ldc2", "sb", "release", "sb", CompilerFlags("-release", "-O", "-flto=thin")),
        dubTarget("ldc2", "sb-repl", "release", "sb-repl", CompilerFlags("-release", "-O", "-flto=thin")),
        dubTarget("ldc2", "bench", "release", "bench", CompilerFlags("-release", "-O", "-flto=thin")),
    );
    return build;
}

mixin BuildgenMain;
