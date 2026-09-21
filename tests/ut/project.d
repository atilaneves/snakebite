module ut.project;


import snakebite.dub: DubDescription;
import snakebite.project: dubSourceSetFromDescription,
    projectStateDirectory, sourceSet;
import std.algorithm.searching: any, endsWith;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.file: getcwd, write;
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


@("sourceSet.loadsDubPackageSettings")
unittest {
    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings");
    const sources = sourceSet(directory, null, null);

    sources.files.any!(path => path.endsWith("tests/main.d")).should == true;
    sources.importPaths.any!(path => path.endsWith("source/")).should == true;
}


// dub compiles a package from its own directory with paths relative to
// it, so a root module's `__FILE__` is that relative path, whether or
// not the file lies under an import path. A project loaded here names
// its root modules the same way, relative to the project directory,
// whatever the current working directory is.
static foreach (backend; Matrix!()) {
    @("rootModuleFileIsRelativeToProjectDirectory." ~ backend.stringof)
    @Serial
    unittest {
        enum moduleName = "file_name_" ~ backend.stringof;
        const relativePath = "sub/" ~ moduleName ~ ".d";
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("filename",
            "sourcePaths \"sub\"\nimportPaths \"imports\"\n"));
        sandbox.writeFile("app/imports/.keep");
        sandbox.writeFile("app/" ~ relativePath,
            "module " ~ moduleName ~ ";\n"
            ~ "int main() { return __FILE__ == \"" ~ relativePath ~ "\" ? 0 : 1; }\n");
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}


// An empty source file is a valid module, including when the project
// directory differs from the process's current directory.
static foreach (backend; Matrix!()) {
    @("emptyRootSourceOutsideWorkingDirectory." ~ backend.stringof)
    @Serial
    unittest {
        enum moduleName = "empty_root_" ~ backend.stringof;
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("emptyroot"));
        sandbox.writeFile("app/source/main_" ~ moduleName ~ ".d",
            "module main_" ~ moduleName ~ ";\n"
            ~ "int main() { return 0; }\n");
        write(sandbox.inSandboxPath("app/source/" ~ moduleName ~ ".d"), "");
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}


// dub's debug and unittest build types pass the compiler `-debug`, so a
// `debug` block in a root module is compiled in. A project loaded here
// gets the same flag from its dub options, and the frontend has to
// honour the bare flag, not only `-debug=identifier`.
static foreach (backend; Matrix!()) {
    @("dubDebugModeCompilesDebugBlocks." ~ backend.stringof)
    @Serial
    unittest {
        enum moduleName = "debug_mode_" ~ backend.stringof;
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("debugmode"));
        sandbox.writeFile("app/source/" ~ moduleName ~ ".d",
            "module " ~ moduleName ~ ";\n"
            ~ "int main() { debug { return 0; } return 1; }\n");
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}

// A dub recipe whose unittest configuration is an executable: dub's own
// synthetic unittest configuration would put a generated stub with its
// own `main` first, and a program takes the first root `main` it finds.
private string dubProjectRecipe(in string name, in string settings = "") {
    return "name \"" ~ name ~ "\"\ntargetType \"library\"\n" ~ settings
        ~ "configuration \"unittest\" {\n    targetType \"executable\"\n}\n";
}

// The dub project at `directory` has a `main` that returns 0: run through
// dub itself for the native oracle, or through the backend.
private void dubProjectMainShouldSucceed(backend)(in string directory) {
    import snakebite.backends.backend: run;
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.execution: prepareProject;
    import std.process: Config, execute;

    static if (is(backend == Native)) {
        const result = execute(
            ["dub", "run", "-q", "--config=unittest",
                "--compiler=" ~ defaultCompiler],
            null, Config.none, size_t.max, directory);
        result.status.shouldEqual(0, result.output);
    } else {
        auto project = prepareProject(directory).project;
        scope instance = new backend(project.program);
        run(instance, project.program).should == 0;
    }
}


// druntime's `_d_run_main` pairs the guest's `rt_init` with `rt_term` only
// when `runModuleUnitTests` returns. A runner hook that lets a throwable
// escape it - unit-threaded's own does, when it runs its suite - skips
// that `rt_term`, and the host's own `rt_term` then only decrements the
// count: no `thread_joinAll`, no module destructors before `exit`, and the
// loader runs those destructors itself after it has freed the DSO records
// a guest thread still walks when it ends, which segfaults `bin/sb`. The
// host must hand the runtime back at the depth it found it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot install a runtime hook"),
)) {
    @("runtime.escapingUnittestThrowableKeepsInitDepth." ~ backend.stringof)
    @Serial
    unittest {
        import core.atomic: atomicLoad;

        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", q{
            name "escaping-throwable-app"
            targetType "library"
        });
        sandbox.writeFile("app/source/escaping_throwable_app.d", q{
            module escaping_throwable_app;
            import core.runtime: Runtime, UnitTestResult;
            // The extended hook wins over the legacy one, whatever another
            // image left installed.
            shared static this() {
                Runtime.extendedModuleUnitTester = {
                    foreach (module_; ModuleInfo)
                        if (module_ && module_.unitTest
                                && module_.name == "escaping_throwable_app")
                            module_.unitTest()();
                    return UnitTestResult(1, 1, false, false);
                };
            }
            unittest { throw new Exception("escapes the runner"); }
        });
        const directory = sandbox.inSandboxPath("app");
        static if (is(backend == Native)) {
            import snakebite.dependencyimage: defaultCompiler;
            import std.process: Config, execute;
            // `dub test` reports a test program that exited 1 as its own 2.
            execute(["dub", "test", "--compiler=" ~ defaultCompiler],
                null, Config.none, size_t.max, directory).status.should == 2;
        } else {
            import snakebite.backends: backendIdentity;
            import snakebite.execution: executeBackend, prepareProject;

            auto program = prepareProject(directory).project.program;
            const depth = atomicLoad(runtimeInitDepth);
            executeBackend(backendIdentity!backend, program).status.should == 1;
            // Another test's guest run on another thread can hold the depth
            // one higher for a moment; a skipped `rt_term` holds it forever.
            runtimeInitDepthReturnsTo(depth).should == true;
        }
    }
}

// druntime's own `rt_init`/`rt_term` nesting depth.
pragma(mangle, "_D2rt6dmain210_initCountOm")
private extern shared size_t runtimeInitDepth;

private bool runtimeInitDepthReturnsTo(in size_t depth) {
    import core.atomic: atomicLoad;
    import core.thread: Thread;
    import core.time: msecs, MonoTime, seconds;

    const deadline = MonoTime.currTime + 5.seconds;
    while (atomicLoad(runtimeInitDepth) != depth) {
        if (MonoTime.currTime > deadline)
            return false;
        Thread.sleep(10.msecs);
    }
    return true;
}
