module ut.project;


import core.atomic: atomicLoad;
import core.runtime: UnitTestResult;
import core.sync.mutex: Mutex;
import snakebite.backends: BackendName, backendIdentity;
import snakebite.backends.backend: Program;
import snakebite.dependencyimage: TestHooks;
import snakebite.execution: prepareProject, executeBackend;
import snakebite.dub: DubDescription;
import snakebite.project: dubSourceSetFromDescription, projectStateDirectory;
import std.algorithm.searching: endsWith;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.file: getcwd;
import std.path: absolutePath, buildNormalizedPath, buildPath, dirName;
import ut;
import ut.backends;


@("stateDirectoryIsCwdScopedAndProjectPartitioned")
unittest {
    const cwd = getcwd;
    const firstProject = "projects/first".absolutePath.buildNormalizedPath;
    const secondProject = "projects/second".absolutePath.buildNormalizedPath;
    const first = projectStateDirectory("projects/first");
    const second = projectStateDirectory("projects/second");

    first.should == buildPath(cwd, ".snakebite",
        firstProject.sha256Of.toHexString.idup);
    second.should == buildPath(cwd, ".snakebite",
        secondProject.sha256Of.toHexString.idup);
    first.should.not == second;
}


@("sourceSet.loadsPackageRecordsWithoutTargets")
unittest {
    import std.json: parseJSON;

    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings").absolutePath;
    auto description = DubDescription(parseJSON(`{
        "rootPackage": "root",
        "configuration": "unittest",
        "targets": [],
        "packages": [
            {
                "name": "root", "configuration": "unittest",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "tests/main.d"}],
                "importPaths": ["source"], "stringImportPaths": [],
                "linkerFiles": [], "dflags": [], "debugVersions": [],
                "options": [], "versions": [], "lflags": [], "libs": []
            },
            {
                "name": "dependency", "configuration": "library",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "source/package.d"}],
                "importPaths": ["source"], "stringImportPaths": []
            }
        ]
    }`));

    const sources = dubSourceSetFromDescription(directory, description);

    sources.files.length.should == 1;
    sources.files[0].endsWith("tests/main.d").should == true;
    sources.importPaths.length.should == 2;
}


// dub turns `-release`, `-noboundscheck` and `-betterC` into options of the
// package and takes them out of `dflags`, so the flags reach the program from
// the options.
@("sourceSet.dubOptionsBecomeFlags")
unittest {
    import std.json: parseJSON;

    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings").absolutePath;
    auto description = DubDescription(parseJSON(`{
        "rootPackage": "root",
        "configuration": "unittest",
        "targets": [],
        "packages": [
            {
                "name": "root", "configuration": "unittest",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "tests/main.d"}],
                "importPaths": ["source"], "stringImportPaths": [],
                "linkerFiles": [], "dflags": [], "debugVersions": [],
                "options": ["releaseMode", "noBoundsCheck", "betterC"],
                "versions": [], "lflags": [], "libs": []
            }
        ]
    }`));

    const sources = dubSourceSetFromDescription(directory, description);

    sources.flags.compilerArguments.should == [
        "-release", "-noboundscheck", "-betterC",
    ];
}


// druntime's own `rt_init`/`rt_term` nesting depth.
pragma(mangle, "_D2rt6dmain210_initCountOm")
private extern shared size_t runtimeInitDepth;

private Program _innerProgram;
private BackendName _nestedBackend;
private extern(C) int rt_init();
private extern(C) int rt_term();

private UnitTestResult throwingInnerRunner() {
    throw new Exception("inner runner failed");
}

private UnitTestResult successfulOuterRunner() {
    executeBackend(_nestedBackend, _innerProgram, null, false).status.should == 1;
    return UnitTestResult(1, 1, false, false);
}

private __gshared Mutex _initDepthLock;

shared static this() {
    _initDepthLock = new Mutex;
}

// A handled inner runner failure must not terminate the outer runtime. The
// variants of this test change druntime's nesting depth, so they take turns.
static foreach (backend; Matrix!()) {
    @("runtime.nestedRunnerKeepsInitDepth." ~ backend.stringof)
    unittest {
        {
            _initDepthLock.lock;
            scope(exit) _initDepthLock.unlock;

            static if (is(backend == Native)) {
                rt_init;
                const depth = atomicLoad(runtimeInitDepth);
                rt_init;
                rt_term;
                atomicLoad(runtimeInitDepth).should == depth;
                rt_term;
            } else {
                const sandbox = Sandbox();
                sandbox.writeFile("outer/outer.d", "module outer; int main() { return 0; }");
                sandbox.writeFile("inner/inner.d", "module inner; int main() { return 0; }");
                auto outer = prepareProject(sandbox.inSandboxPath("outer")).project.program;
                _innerProgram = prepareProject(sandbox.inSandboxPath("inner")).project.program;
                _nestedBackend = backendIdentity!backend;
                _innerProgram.testHooks = TestHooks.of(null, &throwingInnerRunner);
                outer.testHooks = TestHooks.of(null, &successfulOuterRunner);
                rt_init;
                const depth = atomicLoad(runtimeInitDepth);
                scope(exit) {
                    while (atomicLoad(runtimeInitDepth) < depth)
                        rt_init;
                    rt_term;
                }
                executeBackend(_nestedBackend, outer, null, false).status.should == 0;
                atomicLoad(runtimeInitDepth).should == depth;
            }
        }
    }
}
