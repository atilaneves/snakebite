module ut.project;


import core.atomic: atomicLoad;
import core.runtime: Runtime, UnitTestResult;
import snakebite.backends: BackendName, backendIdentity;
import snakebite.backends.backend: Program;
import snakebite.dependencyimage: TestHooks;
import snakebite.execution: prepareProject, executeBackend;
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
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
)) {
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


// A guest class subclasses a native class from a dependency image. The
// native base declares a second virtual method whose return type dmd must
// infer (`auto`) and that the guest never calls. Resolving that inherited
// vtable slot's native address must not depend on something else having
// already driven semantic analysis of that method's body.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
)) {
    @("guestSubclassOfNativeClassWithInferredVirtualMethod." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("dependency/dub.sdl", `name "vtable-dep"
targetType "library"
`);
        sandbox.writeFile("dependency/source/vtable_dep.d", q{
            module vtable_dep;
            import std.algorithm.iteration: filter;

            class Base {
                private int _value;
                this(int value) { _value = value; }
                int value() { return _value; }
                // Virtual, inferred return type, never called by the
                // guest subclass or `main` below.
                auto positives(int[] xs) {
                    return xs.filter!(x => x > 0);
                }
            }
        });
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("vtable-app",
            "dependency \"vtable-dep\" path=\"../dependency\"\n"));
        sandbox.writeFile("app/source/vtable_app.d", q{
            module vtable_app;
            import vtable_dep;

            class Derived : Base {
                this(int value) { super(value); }
                override int value() { return super.value() + 1; }
            }

            int main() {
                auto derived = new Derived(41);
                return derived.value() == 42 ? 0 : 1;
            }
        });
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}


// A native module-scope `auto` free function: its return type and
// attributes are inferred the same way as the vtable slot above, here for
// a plain function pointer the guest itself takes and calls - reaching
// `snakebite.ffi.plan.PlanCache.addressOf`/`prepareCommon` directly,
// never a class's vtable.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
)) {
    @("guestTakesAddressOfNativeInferredFreeFunction." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("dependency/dub.sdl", `name "fnptr-dep"
targetType "library"
`);
        sandbox.writeFile("dependency/source/fnptr_dep.d", q{
            module fnptr_dep;

            // Inferred return type and attributes, never called or
            // addressed anywhere in this module itself.
            auto increment(int x) { return x + 1; }
        });
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("fnptr-app",
            "dependency \"fnptr-dep\" path=\"../dependency\"\n"));
        sandbox.writeFile("app/source/fnptr_app.d", q{
            module fnptr_app;
            import fnptr_dep;

            int main() {
                auto fp = &increment;
                return fp(41) == 42 ? 0 : 1;
            }
        });
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}


// A native class's untyped D variadic constructor, called through `new`
// by the guest: the call passes the `TypeInfo` tuple before the declared
// parameters and the extra arguments after them, as compiled D does.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run D-style variadic functions"),
)) {
    @("guestNewsNativeClassWithVariadicConstructor." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("dependency/dub.sdl", `name "variadic-ctor-dep"
targetType "library"
`);
        sandbox.writeFile("dependency/source/variadic_ctor_dep.d", q{
            module variadic_ctor_dep;
            import core.vararg;

            class Summer {
                int total;
                this(int first, ...) {
                    total = first;
                    foreach (type; _arguments) {
                        assert(type == typeid(int));
                        total += va_arg!int(_argptr);
                    }
                }
            }
        });
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("variadic-ctor-app",
            "dependency \"variadic-ctor-dep\" path=\"../dependency\"\n"));
        sandbox.writeFile("app/source/variadic_ctor_app.d", q{
            module variadic_ctor_app;
            import variadic_ctor_dep;

            int main() {
                auto summer = new Summer(1, 2, 3);
                return summer.total == 6 ? 0 : 1;
            }
        });
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}

// A native struct's untyped D variadic constructor, called through `new`
// by the guest: the call passes the `TypeInfo` tuple before the declared
// parameters and the extra arguments after them, as compiled D does.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run D-style variadic functions"),
)) {
    @("guestNewsNativeStructWithVariadicConstructor." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("dependency/dub.sdl", `name "variadic-struct-ctor-dep"
targetType "library"
`);
        sandbox.writeFile("dependency/source/variadic_struct_ctor_dep.d", q{
            module variadic_struct_ctor_dep;
            import core.vararg;

            struct Summer {
                int total;
                this(int first, ...) {
                    total = first;
                    foreach (type; _arguments) {
                        assert(type == typeid(int));
                        total += va_arg!int(_argptr);
                    }
                }
            }
        });
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("variadic-struct-ctor-app",
            "dependency \"variadic-struct-ctor-dep\" path=\"../dependency\"\n"));
        sandbox.writeFile("app/source/variadic_struct_ctor_app.d", q{
            module variadic_struct_ctor_app;
            import variadic_struct_ctor_dep;

            int main() {
                auto summer = new Summer(1, 2, 3);
                return summer.total == 6 ? 0 : 1;
            }
        });
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}

// A native class's `auto` method, resolved through a delegate the guest
// itself takes (`&instance.answer`), not through a subclass's vtable -
// `snakebite.frontend.dmd.delegates.delegateTargetOf` decides the call's
// shape, and the method's own inferred return type and attributes still
// have to be complete before `snakebite.ffi.plan` resolves its address.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
)) {
    @("guestCallsNativeInferredMethodThroughDelegate." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("dependency/dub.sdl", `name "delegate-dep"
targetType "library"
`);
        sandbox.writeFile("dependency/source/delegate_dep.d", q{
            module delegate_dep;

            class Greeter {
                private int _base;
                this(int base) { _base = base; }
                // Inferred return type and attributes.
                auto answer(int x) { return _base + x; }
            }
        });
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("delegate-app",
            "dependency \"delegate-dep\" path=\"../dependency\"\n"));
        sandbox.writeFile("app/source/delegate_app.d", q{
            module delegate_app;
            import delegate_dep;

            int main() {
                auto instance = new Greeter(40);
                auto dg = &instance.answer;
                return dg(2) == 42 ? 0 : 1;
            }
        });
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}


// An empty source file is a valid module, including when the project
// directory differs from the process's current directory.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
)) {
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
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
)) {
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

// The dub project at `directory` has a `main` that returns 0 on the backend.
private void dubProjectMainShouldSucceed(backend)(in string directory) {
    import snakebite.backends.backend: run;
    import snakebite.execution: prepareProject;

    auto project = prepareProject(directory).project;
    scope instance = new backend(project.program);
    run(instance, project.program).should == 0;
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
    Omit!(Native, Because.inexpressible,
        "the mixin cannot express a dub project"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot install a runtime hook"),
)) {
    @("runtime.escapingUnittestThrowableKeepsInitDepth." ~ backend.stringof)
    @Serial
    unittest {
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
        auto program = prepareProject(directory).project.program;
        const depth = atomicLoad(runtimeInitDepth);
        executeBackend(backendIdentity!backend, program).status.should == 1;
        // Another test's guest run on another thread can hold the depth
        // one higher for a moment; a skipped `rt_term` holds it forever.
        runtimeInitDepthReturnsTo(depth).should == true;
    }
}

// druntime's own `rt_init`/`rt_term` nesting depth.
pragma(mangle, "_D2rt6dmain210_initCountOm")
private extern shared size_t runtimeInitDepth;

private bool runtimeInitDepthReturnsTo(in size_t depth) {
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

// A handled inner runner failure must not terminate the outer runtime.
static foreach (backend; Matrix!()) {
    @("runtime.nestedRunnerKeepsInitDepth." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            rt_init;
            const depth = atomicLoad(runtimeInitDepth);
            rt_init;
            rt_term;
            atomicLoad(runtimeInitDepth).should == depth;
            rt_term;
        } else {
            const saved = TestHooks.current;
            scope(exit) saved.install;
            const sandbox = Sandbox();
            sandbox.writeFile("outer/outer.d", "module outer; int main() { return 0; }");
            sandbox.writeFile("inner/inner.d", "module inner; int main() { return 0; }");
            auto outer = prepareProject(sandbox.inSandboxPath("outer")).project.program; // Hooks are set below.
            _innerProgram = prepareProject(sandbox.inSandboxPath("inner")).project.program;
            _nestedBackend = backendIdentity!backend;
            Runtime.extendedModuleUnitTester = &throwingInnerRunner;
            _innerProgram.testHooks = TestHooks.current;
            Runtime.extendedModuleUnitTester = &successfulOuterRunner;
            outer.testHooks = TestHooks.current;
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
