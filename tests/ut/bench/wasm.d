module ut.bench.wasm;


import bench.wasm: WasmRuntime, WasmTools, wasmReport;
import core.time: Duration, msecs;
import std.algorithm.searching: canFind;
import snakebite.project: SourceSet, sourceSet;
import std.algorithm.searching: count;
import std.conv: octal;
import std.file: exists, mkdir, readText, rmdirRecurse, setAttributes, tempDir, write;
import std.path: buildPath;
import std.uuid: randomUUID;
import ut;


@("wasm32.measuresBuildAndExecution")
unittest {
    const fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    const report = wasmReport(fixture.sources, fixture.directory, 1, 2, fixture.tools);

    report.name.should == "wasm32-jit";
    report.passed.should == true;
    report.isOracle.should == false;
    report.totalCount.should == 3;
    report.passCount.should == 3;
    (report.compileTime.minimum >= 20.msecs).should == true;
    (report.runTime.minimum >= report.compileTime.minimum + 20.msecs).should == true;
    buildPath(fixture.directory, "builds").readText.count("build\n").should == 3;
    buildPath(fixture.directory, "runs").readText.count("run\n").should == 3;
}


@("wasm32.buildFailureDoesNotRunTests")
unittest {
    const fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    fixture.tools.compiler.write("#!/bin/sh\necho 'compiler rejected source' >&2\nexit 1\n");

    const report = wasmReport(fixture.sources, fixture.directory, 0, 2, fixture.tools);

    report.passed.should == false;
    report.runTime.minimum.should == Duration.zero;
    buildPath(fixture.directory, "runs").exists.should == false;
}


@("wasm32.wizardUsesInterpreterOptions")
unittest {
    auto fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    fixture.tools.runtimeKind = WasmRuntime.wizard;

    const report = wasmReport(
        fixture.sources, fixture.directory, 0, 1, fixture.tools,
    );

    report.name.should == "wasm32-interpreter";
    report.passed.should == true;
    const arguments = buildPath(
        fixture.directory, "runtime-arguments",
    ).readText;
    arguments.canFind("--mode=int").should == true;
    arguments.canFind("--env=PWD=").should == true;
}


@("wasm32.laterFailureOverridesEarlierSummary")
unittest {
    const fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    fixture.tools.runtime.write(`#!/bin/sh
if test -e runs; then
    echo 'runtime trap' >&2
    exit 1
fi
touch runs
echo '3 test(s) run, 0 failed'
`);

    const report = wasmReport(fixture.sources, fixture.directory, 0, 2, fixture.tools);

    report.passed.should == false;
    report.haveCounts.should == false;
}


@("wasm32.missingCompilerFails")
unittest {
    // The compiler path is changed to exercise process failure handling.
    auto fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    fixture.tools.compiler = buildPath(fixture.directory, "missing-dmd");

    const report = wasmReport(fixture.sources, fixture.directory, 0, 1, fixture.tools);

    report.passed.should == false;
    buildPath(fixture.directory, "runs").exists.should == false;
}


@("wasm32.dependenciesBuildOnce")
unittest {
    const fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    const dependency = buildPath(fixture.directory, "dependency");
    dependency.mkdir;
    buildPath(dependency, "dub.json").write(`{
        "name": "wasm-fixture-dependency", "targetType": "staticLibrary",
        "sourcePaths": ["."], "importPaths": ["."]
    }`);
    buildPath(dependency, "dependency.d").write("module dependency; int value() { return 1; }");
    buildPath(fixture.directory, "dub.json").write(`{
        "name": "wasm-fixture", "targetType": "executable",
        "sourceFiles": ["tests.d"], "sourcePaths": [],
        "dependencies": {"wasm-fixture-dependency": {"path": "dependency"}}
    }`);

    const report = wasmReport(fixture.sources, fixture.directory, 1, 2, fixture.tools);

    report.passed.should == true;
    buildPath(fixture.directory, "libraries").readText.count("library\n").should == 1;
    buildPath(fixture.directory, "builds").readText.count("build\n").should == 3;
}


@("wasm32.sourceLibraryBuildsOnceFromDubSources")
unittest {
    const fixture = WasmFixture.create;
    scope(exit) fixture.directory.rmdirRecurse;
    const dependency = buildPath(fixture.directory, "dependency");
    dependency.mkdir;
    buildPath(dependency, "dub.json").write(`{
        "name": "wasm-fixture-source-dependency", "targetType": "sourceLibrary",
        "sourcePaths": ["."], "importPaths": ["."]
    }`);
    buildPath(dependency, "dependency.d").write(`module dependency;
int value() { return 1; }
unittest { assert(value() == 1); }
`);
    buildPath(fixture.directory, "tests.d").write(
        "import dependency; void main() {} unittest { assert(value() == 1); }",
    );
    buildPath(fixture.directory, "dub.json").write(`{
        "name": "wasm-fixture-source-root", "targetType": "executable",
        "sourceFiles": ["tests.d"], "sourcePaths": [],
        "dependencies": {"wasm-fixture-source-dependency": {"path": "dependency"}}
    }`);

    const sources = sourceSet(fixture.directory, [], []);
    const report = wasmReport(sources, fixture.directory, 1, 2, fixture.tools);

    report.passed.should == true;
    buildPath(fixture.directory, "commands").readText
        .count(buildPath(dependency, "dependency.d")).should == 1;
    buildPath(fixture.directory, "objects").readText.count("object\n").should == 1;
    buildPath(fixture.directory, "builds").readText.count("build\n").should == 3;
}


private struct WasmFixture {
    string directory;
    SourceSet sources;
    WasmTools tools;

    static WasmFixture create() {
        WasmFixture fixture;
        fixture.directory = buildPath(tempDir, "wasm fixture " ~ randomUUID.toString);
        fixture.directory.mkdir;
        const source = buildPath(fixture.directory, "tests.d");
        source.write("void main() {} unittest { assert(true); }");
        fixture.sources.files = [source];
        fixture.tools = WasmTools(
            buildPath(fixture.directory, "dmd"),
            buildPath(fixture.directory, "wasmtime"),
        );
        fixture.tools.compiler.write(`#!/bin/sh
set -eu
kind=build
for arg do
    echo "$arg" >> commands
    case "$arg" in
        -of=*) output=${arg#-of=} ;;
        -c) kind=object ;;
        -lib) kind=library ;;
    esac
done
if test "$kind" = library; then
    echo library >> libraries
elif test "$kind" = object; then
    echo object >> objects
else
    echo build >> builds
fi
sleep 0.02
echo wasm-fixture > "$output"
`);
        fixture.tools.runtime.write(`#!/bin/sh
set -eu
printf '%s\\n' "$@" > runtime-arguments
for arg do binary=$arg; done
test "$(cat "$binary")" = wasm-fixture
echo run >> runs
sleep 0.02
echo '3 test(s) run, 0 failed'
`);
        fixture.tools.compiler.setAttributes(octal!700);
        fixture.tools.runtime.setAttributes(octal!700);
        return fixture;
    }
}
