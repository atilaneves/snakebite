import reggae;
import reggae.config: configToDubInfo, options;
import reggae.dub.info: DubInfo;
import reggae.build: Build, Target;
import reggae.rules.dub: CompilationMode;
import reggae.rules.dub.runtime: dubBuild;
import reggae.types: CompilerFlags;
import std.algorithm: filter;
import std.array: array;
import std.process: environment, executeShell;
import std.string: chomp;

string ldcPath() {
    version (Windows)
        auto result = executeShell("where ldc2");
    else
        auto result = executeShell("command -v ldc2");
    return result.output.chomp;
}

Target dubTarget(string compiler, string config,
                 CompilerFlags flags = CompilerFlags()) {
    auto buildOptions = options.dup;
    buildOptions.dCompiler = compiler == "dmd"
        ? options.dCompiler
        : environment.get("LDC", ldcPath());
    if (compiler != "dmd")
        buildOptions.dubBuildType = "release";

    DubInfo info = configToDubInfo[config].dup;
    info.options = buildOptions;
    if (compiler != "dmd") {
        foreach (ref package_; info.packages)
            package_.dflags = package_.dflags
                .filter!(a => a != "-debug" && a != "-g")
                .array;
    }
    info.packages[0].targetPath = "bin";

    return dubBuild(buildOptions, info, CompilationMode.options, flags);
}

Build reggaeBuild() {
    auto build = Build(
        dubTarget("dmd", "unittest"),
        dubTarget("dmd", "acceptance-test"),
        dubTarget("ldc2", "sb", CompilerFlags("-release", "-O")),
        dubTarget("ldc2", "sb-repl", CompilerFlags("-release", "-O")),
        dubTarget("ldc2", "bench", CompilerFlags("-release", "-O")),
    );
    return build;
}

mixin BuildgenMain;
