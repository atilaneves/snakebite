module bench.wasm;


import bench.oracle: ProcessResult, dmdArguments, run;
import bench.report: BackendReport, timingStatistics, updateTestCounts;
import snakebite.project: SourceSet;


enum wasmName = "wasm32-jit";
enum wasmAlias = "wasm32";
enum wasmInterpreterName = "wasm32-interpreter";

enum WasmRuntime {
    wasmtime,
    wizard,
}

struct WasmTools {
    string compiler;
    string runtime;
    WasmRuntime runtimeKind = WasmRuntime.wasmtime;
}

// This external row includes the compiler frontend in both cmp and run.
// Toolchain setup and dependency builds are outside the measured cycle.
BackendReport wasmReport(
    in SourceSet sources,
    in string directory,
    in uint warmup,
    in uint runs,
    in WasmTools tools = defaultWasmTools,
) {
    import core.time: Duration;
    import std.algorithm.comparison: max;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.file: mkdir, rmdirRecurse, tempDir;
    import std.path: buildPath;
    import std.stdio: stderr;
    import std.uuid: randomUUID;

    BackendReport report;
    report.name = tools.runtimeKind == WasmRuntime.wizard
        ? wasmInterpreterName : wasmName;
    report.hasCompile = true;
    report.passed = true;
    report.timingNote = "cmp and run include the compiler frontend; "
        ~ (tools.runtimeKind == WasmRuntime.wizard
            ? "run also includes Wizard interpreter startup"
            : "run also includes Wasmtime startup and JIT compilation");

    const temporary = buildPath(tempDir, "snakebite-wasm32-" ~ randomUUID.toString);
    mkdir(temporary);
    scope(exit) rmdirRecurse(temporary);

    try {
        const prepared = prepareDependencies(
            tools, directory, temporary, sources.files,
        );
        const output = buildPath(temporary, "tests.wasm");
        const compile = [tools.compiler, "-mwasm32", "-os=wasm"]
            ~ dmdArguments(sources)
            ~ ["-unittest", "-main", "-od=" ~ temporary, "-of=" ~ output]
            ~ prepared.timedSources ~ prepared.objects ~ prepared.archives;
        const execute = tools.runtimeKind == WasmRuntime.wizard
            ? [tools.runtime, "--mode=int", "--dir=/",
                "--env=PWD=" ~ prepared.workingDirectory, output]
            : [tools.runtime, "run", "-C", "cache=n", "-W", "exceptions=y",
                "--dir=/", "--env", "PWD=" ~ prepared.workingDirectory, output];

        Duration[] compileTimes;
        Duration[] cycleTimes;
        foreach (round; 0 .. warmup + runs) {
            const cycleWatch = StopWatch(AutoStart.yes);
            const built = run(compile, directory);
            const compileTime = cycleWatch.peek;
            if (built.status != 0) {
                report.passed = false;
                stderr.writeln("wasm32 compile failed:\n", diagnostic(built));
                break;
            }
            const tested = run(execute, prepared.workingDirectory);
            const cycleTime = cycleWatch.peek;
            if (tested.status != 0) {
                report.passed = false;
                stderr.writeln("wasm32 tests failed:\n", diagnostic(tested));
                break;
            }
            if (round < warmup)
                continue;

            report.updateTestCounts(tested.stdout_);
            report.ramBytes = max(report.ramBytes, built.ramBytes, tested.ramBytes);
            compileTimes ~= compileTime;
            cycleTimes ~= cycleTime;
        }
        if (cycleTimes.length) {
            report.compileTime = timingStatistics(compileTimes);
            report.runTime = timingStatistics(cycleTimes);
        }
    } catch (Exception exception) {
        report.passed = false;
        stderr.writeln("wasm32 preparation failed:\n", exception.msg);
    }
    // An earlier summary must not hide a later failed process.
    if (!report.passed)
        report.haveCounts = false;
    return report;
}

private string diagnostic(in ProcessResult result) {
    import std.conv: text;

    return text("exit status ", result.status, "\n", result.stderr_, result.stdout_);
}

WasmTools defaultWizardTools() {
    import std.file: thisExePath;
    import std.path: absolutePath, buildNormalizedPath, buildPath, dirName;
    import std.process: environment;

    const root = environment.get(
        "SNAKEBITE_WASM32_ROOT",
        thisExePath.dirName.buildNormalizedPath("..", ".tools", "wasm32"),
    ).absolutePath;
    return WasmTools(
        buildPath(root, "dmd", "generated", "linux", "release", "64", "dmd"),
        buildPath(root, "bin", "wizeng"),
        WasmRuntime.wizard,
    );
}

private WasmTools defaultWasmTools() {
    import std.file: thisExePath;
    import std.path: absolutePath, buildNormalizedPath, buildPath, dirName;
    import std.process: environment;

    const root = environment.get(
        "SNAKEBITE_WASM32_ROOT",
        thisExePath.dirName.buildNormalizedPath("..", ".tools", "wasm32"),
    ).absolutePath;
    return WasmTools(
        buildPath(root, "dmd", "generated", "linux", "release", "64", "dmd"),
        buildPath(root, "bin", "wasmtime"),
    );
}

private struct PreparedDependencies {
    string[] archives;
    string[] objects;
    string[] timedSources;
    string workingDirectory;
}

private PreparedDependencies prepareDependencies(
    in WasmTools tools,
    in string directory,
    in string temporary,
    in string[] sourceFiles,
) {
    import snakebite.project: isDubProject;
    import std.conv: text;
    import std.json: parseJSON;
    import std.path: absolutePath, buildPath;

    PreparedDependencies prepared;
    prepared.timedSources = sourceFiles.dup;
    prepared.workingDirectory = directory.absolutePath;
    if (!isDubProject(directory))
        return prepared;

    // The full description contains merged sourceLibrary files and their
    // package metadata, as well as each dependency target's flags and sources.
    // The fallback reassigns the result when the unittest configuration is absent.
    auto described = run(
        ["dub", "describe", "--config=unittest", "--build=unittest"], directory,
    );
    if (described.status != 0)
        described = run(["dub", "describe"], directory);
    if (described.status != 0)
        throw new Exception(diagnostic(described));

    const description = parseJSON(described.stdout_);
    foreach (index, target; description["targets"].array) {
        const settings = target["buildSettings"];
        if (target["rootPackage"].str == description["rootPackage"].str) {
            const workingDirectory = settings["workingDirectory"].str;
            if (workingDirectory.length)
                prepared.workingDirectory = workingDirectory.absolutePath(directory);
            foreach (file; sourceLibraryFiles(description, target)) {
                string[] remaining;
                foreach (source; prepared.timedSources)
                    if (source != file)
                        remaining ~= source;
                prepared.timedSources = remaining;
                const object = buildPath(
                    temporary, text("source-library-", prepared.objects.length, ".o"),
                );
                const result = run(
                    [tools.compiler, "-mwasm32", "-os=wasm"]
                    ~ dependencyArguments(settings)
                    ~ ["-unittest", "-c", "-od=" ~ temporary, "-of=" ~ object, file],
                    directory,
                );
                if (result.status != 0)
                    throw new Exception(text(
                        "cannot build sourceLibrary for wasm32:\n",
                        diagnostic(result),
                    ));
                prepared.objects ~= object;
            }
            continue;
        }
        const files = strings(settings["sourceFiles"]);
        if (files.length == 0)
            continue;
        const archive = buildPath(temporary, text("dependency-", index, ".a"));
        const result = run(
            [tools.compiler, "-mwasm32", "-os=wasm"]
            ~ dependencyArguments(settings)
            ~ ["-lib", "-od=" ~ temporary, "-of=" ~ archive] ~ files,
            directory,
        );
        if (result.status != 0)
            throw new Exception(text(
                "cannot build ", target["rootPackage"].str, " for wasm32:\n",
                diagnostic(result),
            ));
        prepared.archives ~= archive;
    }
    return prepared;
}

private string[] sourceLibraryFiles(
    in imported!"std.json".JSONValue description,
    in imported!"std.json".JSONValue target,
) {
    import std.path: buildPath;

    string[] files;
    foreach (targetPackage; target["packages"].array)
        foreach (package_; description["packages"].array)
            if (package_["name"].str == targetPackage.str
                && package_["name"].str != description["rootPackage"].str
                && package_["targetType"].str == "sourceLibrary")
                foreach (file; package_["files"].array)
                    if (file["role"].str == "source")
                        files ~= buildPath(
                            package_["path"].str, file["path"].str,
                        );
    return files;
}

private string[] dependencyArguments(in imported!"std.json".JSONValue settings) {
    import snakebite.project: dmdFlagsForOption;
    import std.algorithm.iteration: filter, map;
    import std.array: array;

    return strings(settings["dflags"])
        ~ strings(settings["versions"]).map!(v => "-version=" ~ v).array
        ~ strings(settings["debugVersions"]).map!(v => "-debug=" ~ v).array
        ~ strings(settings["options"]).map!dmdFlagsForOption
            .filter!(flag => flag.length > 0).array
        ~ strings(settings["importPaths"]).map!(p => "-I" ~ p).array
        ~ strings(settings["stringImportPaths"]).map!(p => "-J" ~ p).array;
}

private string[] strings(in imported!"std.json".JSONValue value) {
    import std.algorithm.iteration: map;
    import std.array: array;

    return value.array.map!(item => item.str).array;
}
