module ut.ffi.symbol;


import ut;
import snakebite.ffi: Resolver;
import snakebite.dependencyimage: DependencyImage, ProjectImageCache, defaultCompiler, prepareImage;
import std.file: timeLastModified;
import core.atomic: atomicStore, MemoryOrder;
import core.internal.atomic: atomicLoad;
import core.thread: Thread;
import core.lifetime: _d_newclassT;
import snakebite.exception: SnakebiteException;
import ut.backends;
import snakebite.backends.backend: Program, run;
import snakebite.execution: prepareProject;
import snakebite.frontend.dependencyimage: imageSource;
import core.atomic;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.file: dirEntries, SpanMode;
import std.array: array;
import std.process: execute;
import std.file: exists, readText, remove, setAttributes, setTimes;
import std.path: baseName;
import std.algorithm.iteration: filter;
import std.conv: octal;
import std.path: buildPath;

static foreach (backend; Matrix!()) {
    @("image.repeatedProjectTestRunner." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", q{
            name "repeat-runner-app"
            targetType "library"
            dependency "repeat-runner" path="../runner"
        });
        sandbox.writeFile("app/source/app.d", q{
            module repeat_runner_app;
            import repeat_runner;
            unittest { assert(false, "custom runner must replace default tests"); }
        });
        sandbox.writeFile("runner/dub.sdl", q{
            name "repeat-runner"
            targetType "staticLibrary"
        });
        sandbox.writeFile("runner/source/repeat_runner.d", q{
            module repeat_runner;
            import core.runtime: Runtime, UnitTestResult;
            private __gshared int calls;
            shared static this() {
                Runtime.extendedModuleUnitTester = () {
                    ++calls;
                    return UnitTestResult(1, 1, false, false);
                };
            }
            extern(C) int runner_calls() { return calls; }
        });
        const directory = sandbox.inSandboxPath("app");
        foreach (iteration; 1 .. 3) {
            static if (is(backend == Native)) {
                import std.process: Config;
                execute(["dub", "test", "--compiler=" ~ defaultCompiler],
                    null, Config.none, size_t.max, directory).status.should == 0;
            } else {
                import snakebite.execution: executeBackend;
                import snakebite.backends: backendIdentity;
                import snakebite.dependencyimage: TestHooks;
                auto project = prepareProject(directory).project;
                // A missing hook would enter this host's default unittest
                // runner recursively instead of giving a bounded failure.
                project.program.testHooks.should.not == TestHooks.init;
                executeBackend(backendIdentity!backend, project.program).status.should == 0;
                alias Count = extern(C) int function();
                const count = cast(Count)
                    project.program.dependencyImage.resolve("runner_calls");
                count().should == iteration;
                if (iteration == 1) {
                    // DMD can home these template instances on a previous
                    // project's root. Preparing it again must not import
                    // this separate, in-memory module into its native image.
                    parseSnippet(q{
                        import std.range.interfaces: inputRangeObject;
                        struct UnrelatedRangeItem { int value; }
                        Object makeRange() {
                            return inputRangeObject([UnrelatedRangeItem(1)]);
                        }
                    });
                }
            }
        }
    }
}

private enum atomicSource = q{
    module image;
    import core.atomic: MemoryOrder;
    import core.internal.atomic: atomicLoad;
    export __gshared auto retained = &atomicLoad!(MemoryOrder.seq, int);
};

// Tests in this module build many small images from the same handful of
// sources. The cache in prepareImage keys on content and compiler
// identity and publishes with an atomic rename, so one directory is safe
// to share across different sources: a test with new source still gets
// its own cache entry, and a repeat of the same source hits the cache
// instead of paying for a fresh compile and link. Tests that check the
// cache directory is empty after a failed build keep their own sandbox
// instead (image.compileFailure, image.linkFailure, image.compilerFamily).
private string sharedImageCache() {
    static string directory;
    if (directory is null) {
        import std.file: mkdirRecurse;
        import std.path: buildPath;
        import std.file: tempDir;

        directory = buildPath(tempDir(), "snakebite-image-test-cache");
        mkdirRecurse(directory);
    }
    return directory;
}

@("image.atomicLoad.cache")
@Serial
unittest {
    const directory = sharedImageCache;
    auto image = prepareImage(atomicSource, directory);
    const stamp = timeLastModified(image.path);
    auto reused = prepareImage(atomicSource, directory);
    reused.path.should == image.path;
    timeLastModified(reused.path).should == stamp;
    auto resolver = Resolver(&reused);
    alias Load = typeof(&atomicLoad!(MemoryOrder.seq, int));
    const load = cast(Load) resolver.resolve(atomicLoad!(MemoryOrder.seq, int).mangleof);
    load.should.not == null;
    shared int value;
    foreach (expected; [0, 42, -7, int.min, int.max]) {
        atomicStore(value, expected);
        load(cast(int*) &value).should == expected;
    }
    resolver.resolve("abs").should.not == null;
    resolver.resolve("image_missing_symbol").should == null;
}

@("image.sourceChange")
@Serial
unittest {
    const directory = sharedImageCache;
    auto first = prepareImage("export extern(C) int answer() { return 1; }", directory);
    auto second = prepareImage("export extern(C) int answer() { return 2; }", directory);
    first.path.should.not == second.path;
    alias Answer = extern(C) int function();
    (cast(Answer) first.resolve("answer"))().should == 1;
    (cast(Answer) second.resolve("answer"))().should == 2;
}

@("image.symbolSurvivesImageScope")
@Serial
unittest {
    alias Answer = extern(C) int function();
    Answer answer;
    {
        auto image = prepareImage(
            "export extern(C) int retainedAnswer() { return 381; }",
            sharedImageCache,
        );
        answer = cast(Answer) image.resolve("retainedAnswer");
    }
    answer.should.not == null;
    answer().should == 381;
}

@("image.symbolSurvivesLoadingThread")
@Serial
unittest {
    alias Answer = extern(C) int function();
    Answer answer;
    const directory = sharedImageCache;
    auto thread = new Thread({
        auto image = prepareImage(
            "export extern(C) int threadRetainedAnswer() { return 381; }",
            directory,
        );
        answer = cast(Answer) image.resolve("threadRetainedAnswer");
    });
    thread.start;
    thread.join;
    answer.should.not == null;
    answer().should == 381;
}

@("image.compileFailure")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    (() {
        try {
            auto image = prepareImage(q{
                static assert(false, "image compile diagnostic");
            }, directory);
        } catch (SnakebiteException error) {
            "Dependency image compilation failed".shouldBeIn(error.msg);
            "Command: ".shouldBeIn(error.msg);
            "image compile diagnostic".shouldBeIn(error.msg);
            throw error;
        }
    })().shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}

@("image.linkFailure")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    (() {
        try {
            auto image = prepareImage(q{
                extern(C) int image_missing_dependency();
                export extern(C) int answer() { return image_missing_dependency(); }
            }, directory);
        } catch (SnakebiteException error) {
            "Dependency image linking failed".shouldBeIn(error.msg);
            "Command: ".shouldBeIn(error.msg);
            "image_missing_dependency".shouldBeIn(error.msg);
            throw error;
        }
    })().shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}

@("image.compilerFamily")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    version (DigitalMars) {
        const otherCompiler = "ldc2";
        const message = "Image compiler must be DMD";
    } else {
        const otherCompiler = "dmd";
        const message = "Image compiler must be LDC";
    }
    (() {
        auto image = prepareImage(atomicSource, directory, otherCompiler);
    })().shouldThrowWithMessage!SnakebiteException(message);
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}

// A repeat preparation with an unchanged compiler, source and inputs must
// not run the compiler at all: neither the version probe nor a build. A
// wrapper that fails once poisoned proves the second call never reached it.
@("image.unchangedImageSkipsCompiler")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    const poison = sandbox.inSandboxPath("poison");
    const wrapper = sandbox.inSandboxPath("compiler.sh");
    sandbox.writeFile("compiler.sh", "#!/bin/sh\n[ -e '" ~ poison
        ~ "' ] && exit 1\nexec " ~ defaultCompiler ~ " \"$@\"\n");
    setAttributes(wrapper, octal!755);
    auto image = prepareImage(atomicSource, directory, wrapper);
    sandbox.writeFile("poison", "");
    execute([wrapper, "--version"]).status.should.not == 0;
    auto reused = prepareImage(atomicSource, directory, wrapper);
    reused.path.should == image.path;
}

@("image.inputChange")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sharedImageCache;
    const input = sandbox.inSandboxPath("settings");
    sandbox.writeFile("settings", "first");
    auto first = prepareImage(atomicSource, directory,
        defaultCompiler, [input]);
    sandbox.writeFile("settings", "second");
    auto second = prepareImage(atomicSource, directory,
        defaultCompiler, [input]);
    first.path.should.not == second.path;
}

static foreach (backend; Matrix!()) {
    @("image.overloadedTemplate." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        enum moduleName = "image_overloads_" ~ backend.stringof;
        sandbox.writeFile("deps/" ~ moduleName ~ ".d",
            "module " ~ moduleName ~ ";\n" ~ q{
                template answer(T) {
                    T answer() { return 17; }
                    T answer(T value) { return value + 1; }
                }
                int invoke(string moduleName)() {
                    mixin("import " ~ moduleName ~ ";");
                    return mixin(moduleName ~ ".rootAnswer()");
                }
            });
        sandbox.writeFile("app/root_" ~ moduleName ~ ".d", "module root_" ~ moduleName ~ ";\nimport "
            ~ moduleName ~ ";\n" ~ q{
                int rootAnswer() { return 31; }
                int main() {
                    assert(answer!int() == 17);
                    assert(answer!int(23) == 24);
                    assert(invoke!(__MODULE__)() == 31);
                    return 0;
                }
            });
        const directory = sandbox.inSandboxPath("app");
        const imports = [sandbox.inSandboxPath("deps")];
        static if (is(backend == Native)) {
            const executable = sandbox.inSandboxPath("test");
            const result = execute([defaultCompiler, "-I" ~ imports[0],
                sandbox.inSandboxPath("app/root_" ~ moduleName ~ ".d"), "-of=" ~ executable]);
            result.status.shouldEqual(0, result.output);
            execute([executable]).status.should == 0;
        } else {
            auto project = prepareProject(directory, imports).project;
            scope instance = new backend(project.program);
            run(instance, project.program).should == 0;
        }
    }
}

// Two overloads of one template share the name `answer!int`, so the address
// expression `&answer!int` is ambiguous without a target type. Each overload
// still has its own mangled name, and the registry must answer a lookup by
// that name with the overload that the mangle names, not with its sibling.
// The registry is the only route to such instances when an image keeps its
// template bodies out of the dynamic symbol table (LDC, `-linkonce-templates`),
// so the test calls it directly instead of relying on `dlsym` missing.
@("image.overloadRegistryAnswersEachOverload")
@Serial
unittest {
    import std.conv: text;

    const sandbox = Sandbox();
    enum moduleName = "image_registry_overloads";
    sandbox.writeFile("deps/" ~ moduleName ~ ".d",
        "module " ~ moduleName ~ ";\n" ~ q{
            template answer(T) {
                T answer() { return 17; }
                T answer(T value) { return value + 1; }
            }
        });
    sandbox.writeFile("app/root_" ~ moduleName ~ ".d", "module root_" ~ moduleName ~ ";\nimport "
        ~ moduleName ~ ";\n" ~ q{
            int main() {
                return answer!int() + answer!int(23);
            }
        });
    auto project = prepareProject(
        sandbox.inSandboxPath("app"), [sandbox.inSandboxPath("deps")]).project;
    const image = project.program.dependencyImage;
    image.should.not == null;

    // The image compiler infers `pure nothrow @nogc @safe` for both bodies,
    // and the mangle spells that out. `Qk` repeats the instance name.
    const prefix = text("_D", moduleName.length, moduleName, "__T6answerTiZQkFNaNbNiNf");
    alias NoArguments = int function();
    alias OneArgument = int function(int);
    const noArguments = cast(NoArguments) (*image).registryAnswer(prefix ~ "Zi");
    const oneArgument = cast(OneArgument) (*image).registryAnswer(prefix ~ "iZi");
    noArguments.should.not == null;
    oneArgument.should.not == null;
    noArguments().should == 17;
    oneArgument(23).should == 24;
}


// `rebindable` has two template overloads that give the same signature for an
// array argument, so even a typed address cannot choose between them. The
// registry then selects the declaration by its position among the overloads
// of that name, the order `__traits(getOverloads)` uses.
@("image.overloadRegistrySelectsByPosition")
@Serial
unittest {
    auto module_ = parseSnippet(q{
        import std.typecons: rebindable;
        int[] answer(int[] values) {
            return rebindable(values);
        }
    });
    auto program = Program([module_]);
    const image = prepareImage(imageSource(program), sharedImageCache,
        defaultCompiler, null, null, null, ["-w"]);
    alias Rebindable = int[] function(int[]);
    // The mangle is that of `rebindable!(int[])` with its inferred attributes.
    const rebindable = cast(Rebindable) image.registryAnswer(
        "_D3std8typecons__T10rebindableTAiZQqFNaNbNiNfQoZQr");
    rebindable.should.not == null;
    auto values = [17];
    rebindable(values).should == [17];
}

// The image exports its registry under `DependencyImage.registrySymbol`.
// `resolve` reaches it only after `dlsym` misses, and a DMD image keeps every
// instance in its symbol table, so a direct call is the way to see its answer.
private void* registryAnswer(in DependencyImage image, in char[] name) {
    import core.sys.posix.dlfcn: RTLD_NOW, dlopen, dlsym;
    import std.string: toStringz;

    // The image stays loaded, so this returns the handle that it already holds.
    auto handle = dlopen(image.path.toStringz, RTLD_NOW);
    handle.should.not == null;
    alias Registry = extern(C) void* function(const(char)[]);
    const registry = cast(Registry) dlsym(handle, DependencyImage.registrySymbol.toStringz);
    registry.should.not == null;
    return registry(name);
}


static foreach (backend; Matrix!()) {
    @("image.templateAliasOverloads." ~ backend.stringof)
    @Serial
    unittest {
        // Rebindable!T can alias T itself. Only the selected overload may
        // be emitted when two template declarations then share a signature.
        enum code = q{
            import std.typecons: rebindable;
            int answer() {
                int[] values = [17];
                return rebindable(values)[0];
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 17;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            auto image = prepareImage(imageSource(program), sharedImageCache,
                defaultCompiler, null, null, null, ["-w"]);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 17;
        }
    }
}


// `among` with a lambda predicate instantiates a template whose `.mangleof`
// names the instance, not the callable. The lookup in the image must key on
// the exact mangle of the function itself.
static foreach (backend; Matrix!()) {
    @("image.importedTemplateDelegate." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            import std.algorithm.comparison: among;

            int answer() {
                return among!((a, b) => a == b)("a", "x", "a");
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 2;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            auto image = prepareImage(imageSource(program), sharedImageCache,
                defaultCompiler, null, null, null, ["-w"]);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 2;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("image.atomicLoad." ~ backend.stringof)
    @Serial
    unittest {
        const directory = sharedImageCache;
        auto image = prepareImage(atomicSource, directory);
        shared int value = 42;
        static if (is(backend == Native)) {
            alias Load = typeof(&atomicLoad!(MemoryOrder.seq, int));
            const load = cast(Load) image.resolve(atomicLoad!(MemoryOrder.seq, int).mangleof);
            load(cast(int*) &value).should == 42;
        } else {
            auto module_ = parseSnippet(q{
                import core.internal.atomic: atomicLoad;
                int answer(shared int* value) {
                    return atomicLoad(cast(int*) value);
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            auto pointer = &value;
            int result;
            instance.call(findFunction(module_, "answer"), &result, [cast(void*) &pointer]);
            result.should == 42;
        }
    }
}

@("image.moduleConstructor")
@Serial
unittest {
    const directory = sharedImageCache;
    auto image = prepareImage(q{
        module image;
        __gshared int value;
        shared static this() { value = 73; }
        export extern(C) int answer() { return value; }
    }, directory);
    alias Answer = extern(C) int function();
    (cast(Answer) image.resolve("answer"))().should == 73;
}


@("resolved.once")
unittest {
    Resolver resolver;

    foreach (_; 0 .. 100)
        resolver.resolve("abs").should.not == null;

    resolver.lookups.should == 1;
}


@("missing.resolved.once")
unittest {
    Resolver resolver;

    foreach (_; 0 .. 100)
        resolver.resolve(
            "snakebite_symbol_that_does_not_exist",
        ).should == null;

    resolver.lookups.should == 1;
}

static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "atomicFetchAdd casts a runtime pointer to an integer"))) {
    @("image.discoveredAtomicFetchAdd." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            import core.atomic: atomicFetchAdd;
            import std.algorithm.comparison: min, max;
            int answer() {
                shared int value = 17;
                ulong amount = 4;
                const previous = atomicFetchAdd(value, min(amount, max(amount, 2UL)));
                assert(value == 21);
                return previous;
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 17;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            const source = imageSource(program);
            auto image = prepareImage(source, sharedImageCache,
                defaultCompiler, null, null, null, ["-w", "-checkaction=context"]);
            alias FetchAdd = __traits(getOverloads, core.atomic, "atomicFetchAdd", true)[0];
            image.resolve(FetchAdd!(MemoryOrder.seq, int).mangleof)
                .should.not == null;
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 17;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "atomicFetchAdd casts a runtime pointer to an integer"))) {
    @("image.projectAtomicFetchAdd." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            import core.atomic: atomicFetchAdd;
            int main() {
                shared int value = 17;
                assert(atomicFetchAdd(value, 4) == 17);
                assert(value == 21);
                return 0;
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            main.should == 0;
        } else {
            const sandbox = Sandbox();
            enum moduleName = "image_project_atomic_" ~ backend.stringof;
            const source = "module " ~ moduleName ~ ";\n" ~ code;
            sandbox.writeFile(moduleName ~ ".d", source);
            // A program can outlive the project that prepared its image.
            auto program = prepareProject(sandbox.sandboxPath).project.program;
            program.dependencyImage.should.not == null;
            scope instance = new backend(program);
            run(instance, program).should == 0;
            const path = program.dependencyImage.path;
            const stamp = timeLastModified(path);
            sandbox.writeFile(moduleName ~ ".d", source ~ "\n");
            auto reused = prepareProject(sandbox.sandboxPath).project;
            reused.program.dependencyImage.path.should == path;
            timeLastModified(path).should == stamp;
            scope second = new backend(reused.program);
            run(second, reused.program).should == 0;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE executes cached syntax, not a replacement native image"))) {
    @("image.dependencyEdit." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            int answer(T)() { return 7; }
            answer!int.should == 7;
        } else {
            const sandbox = Sandbox();
            enum moduleName = "image_dependency_" ~ backend.stringof;
            sandbox.writeFile("app/root_" ~ moduleName ~ ".d",
                "module root_" ~ moduleName ~ ";\nimport " ~ moduleName
                ~ "; int main() { return answer!int(); }");
            const dependencyPath = "deps/" ~ moduleName ~ ".d";
            const prefix = "module " ~ moduleName ~ ";\n";
            sandbox.writeFile(dependencyPath, prefix ~ "int answer(T)() { return 7; }");
            const directory = sandbox.inSandboxPath("app");
            const imports = [sandbox.inSandboxPath("deps")];
            auto project = prepareProject(directory, imports).project;
            const firstPath = project.program.dependencyImage.path;
            scope first = new backend(project.program);
            run(first, project.program).should == 7;
            sandbox.writeFile(dependencyPath, prefix ~ "int answer(T)() { return 9; }");
            auto changed = prepareProject(directory, imports).project;
            changed.program.dependencyImage.path.should.not == firstPath;
            scope second = new backend(changed.program);
            run(second, changed.program).should == 9;
        }
    }
}


// A global a dependency defines has one storage, the native image's: a
// native setter and an interpreted reader reach the same variable, for
// a `__gshared` and for a thread-local one alike. The dependency is a
// dub package, so its functions have machine code in an archive the
// image links, as a project's dependencies do.
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE has no native image to share a global with"))) {
    @("image.dependencyGlobal." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        const directory = dependencyGlobalProject(sandbox,
            "image_global_" ~ backend.stringof, q{
            __gshared int counter = 0;
            void bump() { ++counter; }
            struct Settings {
                static string path = "default";
                static void setPath(string value) { path = value; }
            }
        }, q{
            int main() {
                if (counter != 0) return 1;
                bump();
                if (counter != 1) return 2;
                if (Settings.path != "default") return 3;
                Settings.setPath("changed");
                if (Settings.path != "changed") return 4;
                return 0;
            }
        });
        runDependencyGlobalProject!backend(directory).should == 0;
    }
}


// A dependency's thread-local variable is still one copy per thread:
// the interpreted reader on a new thread sees that thread's own copy,
// not the one the main thread wrote. The dependency starts the thread,
// since that is native code either way, and calls back into the guest
// on it.
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE has no native image to share a global with"))) {
    @("image.dependencyThreadLocalPerThread." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        const directory = dependencyGlobalProject(sandbox,
            "image_tls_" ~ backend.stringof, q{
            import core.thread: Thread;
            struct Settings {
                static string path = "default";
                static void setPath(string value) { path = value; }
            }
            string readOnNewThread(string delegate() read) {
                string seen;
                auto thread = new Thread({ seen = read(); });
                thread.start;
                thread.join;
                return seen;
            }
        }, q{
            int main() {
                Settings.setPath("changed");
                if (Settings.path != "changed") return 1;
                if (readOnNewThread(() => Settings.path) != "default") return 2;
                if (Settings.path != "changed") return 3;
                return 0;
            }
        });
        runDependencyGlobalProject!backend(directory).should == 0;
    }
}

// An app package whose root module runs `rootSource`'s `main` against a
// static-library dependency built from `dependencySource`. The unittest
// configuration is an executable so the native oracle has one to run.
// `name` prefixes both module names: dmd keeps every module this
// process ever parsed, under its name, so two tests cannot share one.
private string dependencyGlobalProject(
    in Sandbox sandbox,
    in string name,
    in string dependencySource,
    in string rootSource,
) {
    sandbox.writeFile("app/dub.sdl", q{
        name "global-app"
        targetType "library"
        targetName "global-app"
        dependency "global-dependency" path="../dependency"
        configuration "unittest" {
            targetType "executable"
        }
    });
    sandbox.writeFile("app/source/" ~ name ~ "_app.d",
        "module " ~ name ~ "_app;\nimport " ~ name ~ "_dependency;\n"
        ~ rootSource);
    sandbox.writeFile("dependency/dub.sdl", q{
        name "global-dependency"
        targetType "staticLibrary"
    });
    sandbox.writeFile("dependency/source/" ~ name ~ "_dependency.d",
        "module " ~ name ~ "_dependency;\n" ~ dependencySource);
    return sandbox.inSandboxPath("app");
}

private int runDependencyGlobalProject(backend)(in string directory) {
    auto project = prepareProject(directory).project;
    static if (is(backend == Native)) {
        const description = project.sources.dubDescription.value;
        foreach (target; description["targets"].array)
            if (target["rootPackage"].str == description["rootPackage"].str) {
                const settings = target["buildSettings"];
                return execute([buildPath(settings["targetPath"].str,
                    settings["targetName"].str)]).status;
            }
        assert(false, "no root target in the dub description");
    } else {
        scope instance = new backend(project.program);
        return run(instance, project.program);
    }
}


static foreach (backend; Matrix!()) {
    @("image.narrowTemplateArguments." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        enum moduleName = "image_narrow_" ~ backend.stringof;
        sandbox.writeFile("deps/" ~ moduleName ~ ".d",
            "module " ~ moduleName ~ ";\n" ~ q{
                struct Selection(ushort value) { int member = value; }
                int read(T)(T value) { return value.member; }
                int number(short value)() { return value; }
                int literal(string value)() { return value == "!cast(ushort)1u"; }
            });
        sandbox.writeFile("app/root_" ~ moduleName ~ ".d",
            "module root_" ~ moduleName ~ ";\nimport " ~ moduleName ~ ";\n" ~ q{
            int main() {
                assert(read(Selection!1()) == 1);
                assert(number!(-2)() == -2);
                assert(literal!"!cast(ushort)1u"() == 1);
                return 0;
            }
        });
        const imports = [sandbox.inSandboxPath("deps")];
        static if (is(backend == Native)) {
            const executable = sandbox.inSandboxPath("test");
            const result = execute([defaultCompiler, "-I" ~ imports[0],
                sandbox.inSandboxPath("app/root_" ~ moduleName ~ ".d"), "-of=" ~ executable]);
            result.status.shouldEqual(0, result.output);
            execute([executable]).status.should == 0;
        } else {
            auto project = prepareProject(sandbox.inSandboxPath("app"), imports).project;
            scope instance = new backend(project.program);
            run(instance, project.program).should == 0;
        }
    }
}


static foreach (backend; Matrix!()) {
    @("image.recursiveConstructorCollector." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            struct Recursive {
                this(int depth) {
                    if (depth > 0) {
                        auto child = Recursive(depth - 1);
                    }
                }
            }
            int answer() {
                auto value = Recursive(0);
                return 0;
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 0;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            auto image = prepareImage(imageSource(program), sharedImageCache);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 0;
        }
    }
}


static foreach (backend; Matrix!()) {
    @("image.recursiveFunctionLiteralCollector." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            int answer() {
                int delegate(int) recursive = (int depth) {
                    if (depth > 0) return __traits(parent, depth)(depth - 1);
                    return 7;
                };
                return recursive(3);
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 7;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            auto image = prepareImage(imageSource(program), sharedImageCache);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 7;
        }
    }
}


static foreach (backend; Matrix!()) {
    @("image.constructorLocalTypes." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            import std.bigint: BigInt;
            int answer() { return BigInt("123").toInt; }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 123;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            auto image = prepareImage(imageSource(program), sharedImageCache);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 123;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot read the delegate funcptr used by toDelegate"))) {
    @("image.functionLinkageTemplateArgument." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            import std.functional: toDelegate;
            extern(C) int increment(int value) { return value + 1; }
            int answer() {
                return toDelegate(&increment)(16);
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 17;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            auto image = prepareImage(imageSource(program), sharedImageCache);
            program.dependencyImage = &image;
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 17;
        }
    }
}


@("image.templateArgumentImports")
@Serial
unittest {
    // Program requires a mutable AST.
    auto module_ = parseSnippet(q{
        import core.lifetime: _d_newclassT;
        import core.thread.osthread: Thread;
        Thread allocate() { return _d_newclassT!Thread(); }
    });
    const source = imageSource(Program([module_]));
    auto image = prepareImage(source, sharedImageCache,
        defaultCompiler, null, null, null, ["-de"]);
    image.resolve(_d_newclassT!Thread.mangleof).should.not == null;
}


// `store`'s first instantiation nests a root-owned type (`Thing`) two
// levels deep: inside `Bucket`'s own template arguments, inside a delegate
// parameter type. A walk that only follows pointer, array, and
// delegate-return-type links (dmd's `nextOf` chain) never reaches `Thing`,
// so it wrongly treats the instantiation as fully resolvable from the
// dependency module alone and emits it with `Thing` unqualified - a
// spelling that cannot resolve, and that the dmd 2.113.0 frontend segfaults
// on while trying to report as such. The instantiation must instead be
// excluded and left to the normal guest fallback. `store`'s second
// instantiation is the positive control: every type it nests (`string`,
// `int`, `Bucket` itself) is either built in or dependency-owned, so it
// must still resolve and be emitted with its correctly qualified spelling.
// An over-broad fix that excludes every nested-template-argument
// instantiation, not just root-owned ones, would pass the first assertion
// but fail the second.
@("image.nestedTemplateArgumentRootType")
@Serial
unittest {
    const sandbox = Sandbox();
    enum moduleName = "image_nested_root_type";
    sandbox.writeFile("deps/" ~ moduleName ~ ".d",
        "module " ~ moduleName ~ ";\n" ~ q{
            struct Bucket(K, V) { K key; V value; }
            void store(T)(T value) {}
        });
    sandbox.writeFile("app/root_" ~ moduleName ~ ".d",
        "module root_" ~ moduleName ~ ";\nimport " ~ moduleName ~ ";\n" ~ q{
        class Thing {}
        void trigger() {
            Bucket!(string, void delegate(Thing)) bucket;
            store(bucket);
            Bucket!(string, void delegate(int)) other;
            store(other);
        }
    });
    const imports = [sandbox.inSandboxPath("deps")];
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports).project;
    const source = imageSource(project.program);
    "Thing".should.not.be in source;
    (moduleName ~ ".store!(" ~ moduleName ~ ".Bucket!(string, void delegate(int)))")
        .should.be in source;
}


// `apply!(plain)`'s only template argument is an alias to `plain`, a
// module-level dependency function - a normal dependency, not a local one.
// A walk that treats the aliased symbol itself as "function-local" merely
// because it is a `FuncDeclaration` (rather than checking its *ancestors*
// for an enclosing function, see `dependencyimage.d`'s
// `hasFunctionLocalType`) wrongly drops this instantiation from the image.
@("image.aliasArgumentDependencyFunction")
@Serial
unittest {
    const sandbox = Sandbox();
    enum moduleName = "image_alias_argument";
    sandbox.writeFile("deps/" ~ moduleName ~ ".d",
        "module " ~ moduleName ~ ";\n" ~ q{
            void apply(alias f)() { f(); }
            void plain() {}
        });
    sandbox.writeFile("app/root_" ~ moduleName ~ ".d",
        "module root_" ~ moduleName ~ ";\nimport " ~ moduleName ~ ";\n" ~ q{
        void trigger() {
            apply!(plain)();
        }
    });
    const imports = [sandbox.inSandboxPath("deps")];
    // `plain` is not itself part of a linkable dependency library in this
    // sandbox, so building the real dependency image would fail to link;
    // this test only checks what `imageSource` generates, not that it links.
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports, null, false).project;
    const source = imageSource(project.program);
    "apply!".should.be in source;
}


// `apply!(pick!Thing)`'s alias argument names `pick!Thing`, a dependency
// template function instance whose own template argument (`Thing`) is
// root-owned. `pick!Thing.getModule` resolves to the dependency module (dmd
// homes an instantiated symbol on its template declaration's module), so
// checking only the aliased symbol's own module misses the root-owned type
// nested inside *its* template arguments - the same class of hole that
// `image.nestedTemplateArgumentRootType` covers for a type argument, but
// reached here through an alias argument instead (see `dependencyimage.d`'s
// `eachFoundSymbol`, used from both `eachTemplateArgumentSymbol`'s
// `toDsymbol` path and `eachTemplateArgument`'s `isDsymbol` path). The
// instantiation must not leak an unresolvable, unqualified `Thing` spelling
// into the image.
@("image.aliasArgumentNestedRootType")
@Serial
unittest {
    const sandbox = Sandbox();
    enum moduleName = "image_alias_nested_root";
    // `apply`'s body never calls `f`: the aliased `pick!Thing` instance is
    // therefore never itself visited (and so never itself directly marked
    // as needing root through the ordinary call-graph propagation). Only
    // the alias-argument walk over `apply!(pick!Thing)`'s own tiargs can
    // discover that `Thing` is root-owned.
    sandbox.writeFile("deps/" ~ moduleName ~ ".d",
        "module " ~ moduleName ~ ";\n" ~ q{
            void apply(alias f)() {}
            void pick(T)() {}
        });
    sandbox.writeFile("app/root_" ~ moduleName ~ ".d",
        "module root_" ~ moduleName ~ ";\nimport " ~ moduleName ~ ";\n" ~ q{
        class Thing {}
        void trigger() {
            apply!(pick!Thing)();
        }
    });
    const imports = [sandbox.inSandboxPath("deps")];
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports, null, false).project;
    const source = imageSource(project.program);
    "apply!".should.not.be in source;
}


@("image.compilerArguments")
@Serial
unittest {
    auto image = prepareImage(q{
        module image;
        version (ImageSetting) {} else static assert(false, "missing version");
        debug {} else static assert(false, "missing debug");
        export extern(C) int answer() { return 42; }
    }, sharedImageCache, defaultCompiler, null, null, null,
        ["-debug", "-version=ImageSetting"]);
    alias Answer = extern(C) int function();
    (cast(Answer) image.resolve("answer"))().should == 42;
}

// D checks a member function of a template instance only when something uses
// it, so a dependency can hold an unused member that a strict project flag
// such as `-preview=dip1000` would reject. `-allinst` forces the compiler to
// check every member of every instance, including the ones no call reaches,
// so an LDC image built with it fails on such a dependency even though the
// dependency's own build passes. The image must build with the flag that
// emits only the referenced bodies. A DMD image keeps `-allinst`, which its
// symbol table needs, so this runs on LDC only.
version (LDC)
@("image.unusedTemplateMemberIsNotAnalysed")
@Serial
unittest {
    const sandbox = Sandbox();
    const dependency = sandbox.inSandboxPath("deps/image_unused_member.d");
    sandbox.writeFile("deps/image_unused_member.d", q{
        module image_unused_member;

        int* stored;

        struct Colored(T) {
            T value;

            T get() @safe { return value; }

            // Never called. Only `-preview=dip1000` rejects this store.
            void leak(scope int* pointer) @safe { stored = pointer; }
        }

        Colored!T paint(T)(T value) { return Colored!T(value); }

        // A dependency's own function has its machine code in the dependency's
        // object, not in the image. Its return type instantiates `Colored!int`
        // outside every module that the image compiles as a root.
        Colored!int paintInt(int value) @safe pure nothrow @nogc {
            return value.paint;
        }
    });
    const objectPath = sandbox.inSandboxPath("image_unused_member.o");
    const compiled = execute([defaultCompiler, "-c", "-relocation-model=pic",
        dependency, "-of=" ~ objectPath]);
    compiled.status.shouldEqual(0, compiled.output);

    auto image = prepareImage(q{
        module image;
        import image_unused_member;

        export extern(C) int answer() { return paintInt(42).get; }
    }, sharedImageCache, defaultCompiler, [dependency],
        [sandbox.inSandboxPath("deps")], null, ["-preview=dip1000"],
        [objectPath]);
    alias Answer = extern(C) int function();
    (cast(Answer) image.resolve("answer"))().should == 42;
}

static foreach (backend; Matrix!()) {
    @("image.hashWithCtfeHelper." ~ backend.stringof)
    @Serial
    unittest {
        enum code = q{
            import core.internal.hash: hashOf;
            struct Value { int number; }
            int answer() {
                auto value = Value(17);
                return hashOf(value) == hashOf(Value(17)) ? 17 : 0;
            }
        };
        static if (is(backend == Native)) {
            mixin(code);
            answer.should == 17;
        } else {
            auto module_ = parseSnippet(code);
            auto program = Program([module_]);
            imageSource(program);
            scope instance = new backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 17;
        }
    }
}


static foreach (backend; Matrix!()) {
    @("image.dubTransitiveArchives." ~ backend.stringof)
    @Serial
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", q{
            name "image-app"
            targetType "library"
            targetName "image-app"
            preBuildCommands "test ! -e reject-build"
            dependency "image-middle" path="../middle"
            configuration "unittest" {
                targetType "executable"
            }
        });
        sandbox.writeFile("app/source/app.d", q{
            module image_app;
            import image_middle;
            unittest { assert(answer() == 42); }
            int main() { assert(answer() == 42); return 0; }
        });
        sandbox.writeFile("middle/dub.sdl", q{
            name "image-middle"
            targetType "staticLibrary"
            dependency "image-leaf" path="../leaf archives"
        });
        sandbox.writeFile("middle/source/image_middle.d", q{
            module image_middle;
            import image_leaf;
            int answer() { return leaf() + 1; }
        });
        sandbox.writeFile("leaf archives/dub.sdl", q{
            name "image-leaf"
            targetType "staticLibrary"
        });
        sandbox.writeFile("leaf archives/source/image_leaf.d", q{
            module image_leaf;
            int leaf() { return 41; }
        });
        // A separate archive member has no reference from the guest or the
        // image source. It must still be present for later symbol lookups.
        sandbox.writeFile("leaf archives/source/image_unused.d", q{
            module image_unused;
            extern(C) int image_unused_answer() { return 73; }
        });
        const directory = sandbox.inSandboxPath("app");
        const archive = sandbox.inSandboxPath("leaf archives/libimage-leaf.a");
        archive.exists.should == false;
        auto project = prepareProject(directory).project;
        archive.exists.should == true;
        project.program.dependencyImage.should.not == null;
        alias Answer = extern(C) int function();
        const unused = cast(Answer)
            project.program.dependencyImage.resolve("image_unused_answer");
        unused.should.not == null;
        unused().should == 73;
        static if (is(backend == Native)) {
            const description = project.sources.dubDescription.value;
            foreach (target; description["targets"].array)
                if (target["rootPackage"].str == description["rootPackage"].str) {
                    const settings = target["buildSettings"];
                    execute([buildPath(settings["targetPath"].str,
                        settings["targetName"].str)]).status.should == 0;
                }
        } else {
            scope instance = new backend(project.program);
            run(instance, project.program).should == 0;
        }
        const path = project.program.dependencyImage.path;
        const stamp = timeLastModified(archive);
        sandbox.writeFile("app/reject-build", "");
        sandbox.writeFile("app/source/app.d",
            sandbox.inSandboxPath("app/source/app.d").readText ~ "\n");
        auto reused = prepareProject(directory).project;
        reused.program.dependencyImage.path.should == path;
        timeLastModified(archive).should == stamp;
        sandbox.inSandboxPath("app/reject-build").remove;
        sandbox.writeFile("leaf archives/source/image_unused.d", q{
            module image_unused;
            extern(C) int image_unused_answer() { return 179; }
        });
        auto changed = prepareProject(directory).project;
        const changedPath = changed.program.dependencyImage.path;
        changedPath.should.not == path;
        const changedAnswer = cast(Answer)
            changed.program.dependencyImage.resolve("image_unused_answer");
        changedAnswer.should.not == null;
        changedAnswer().should == 179;
        // The image links dub's per-compiler build artifact, not the copy
        // dub leaves in the package directory: a build by another compiler
        // replaces that copy, and the guest's own compiled output must not
        // change because of it.
        const linked = changed.sources.linkerFiles
            .filter!(file => file.baseName == archive.baseName).array;
        linked.length.should == 1;
        linked[0].should.not == archive;
        sandbox.writeFile("leaf archives/libimage-leaf.a", "not an archive");
        auto foreign = prepareProject(directory).project;
        foreign.program.dependencyImage.path.should == changedPath;
        // A missing artifact is compiled again. The image is keyed on the
        // archive's bytes, which a fresh archive need not repeat, so what
        // must hold is that the image still serves the leaf's symbols.
        linked[0].remove;
        auto rebuilt = prepareProject(directory).project;
        linked[0].exists.should == true;
        const rebuiltAnswer = cast(Answer)
            rebuilt.program.dependencyImage.resolve("image_unused_answer");
        rebuiltAnswer.should.not == null;
        rebuiltAnswer().should == 179;
    }
}


@("image.projectCacheSkipsPreparation")
@Serial
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("root.d", "root");
    sandbox.writeFile("dependency.d", "before");
    const root = sandbox.inSandboxPath("root.d");
    const dependency = sandbox.inSandboxPath("dependency.d");
    const directory = sandbox.sandboxPath;
    const record = buildPath(directory, "project.json");
    auto cache = ProjectImageCache(record, "settings", [root]);
    auto image = new DependencyImage;
    size_t builds;
    size_t sources;
    size_t inputReads;
    string[] dependencyInputs() {
        ++inputReads;
        return [dependency.idup];
    }
    DependencyImage makeImage(in string source) {
        return prepareImage(source, directory);
    }
    cache.prepare(*image,
        () {
            ++sources;
            return atomicSource;
        },
        () {
            ++builds;
        },
        &makeImage,
        true,
        &dependencyInputs).should == true;
    builds.should == 1;
    sources.should == 1;
    inputReads.should == 1;
    auto next = ProjectImageCache(record, "settings", [root]);
    DependencyImage hit;
    void failPreparation() {
        throw new Exception("An unchanged image must skip preparation");
    }
    DependencyImage failImage(in string) {
        failPreparation;
        assert(0);
    }
    next.prepare(hit, () {
            failPreparation;
            return "";
        },
        &failPreparation,
        &failImage,
        true,
        &dependencyInputs)
        .should == true;
    hit.path.should == image.path;

    sandbox.writeFile("root.d", "changed root");
    next.prepare(hit, () {
            ++sources;
            return atomicSource;
        },
        () {
            throw new Exception("A root edit with the same source skips build");
        },
        &failImage,
        true,
        &dependencyInputs).should == true;
    sources.should == 2;
    inputReads.should == 1;
    auto changedSettings = ProjectImageCache(record, "other settings", [root]);
    changedSettings.prepare(hit, () => atomicSource, () {
            ++builds;
        }, &makeImage, true,
        &dependencyInputs).should == true;
    builds.should == 2;
    inputReads.should == 2;

    // A preserved mtime and size must not hide a changed dependency.
    const stamp = timeLastModified(dependency);
    sandbox.writeFile("dependency.d", "after!");
    setTimes(dependency, stamp, stamp);
    changedSettings.prepare(hit, () => atomicSource, () {
            ++builds;
        }, &makeImage, true,
        &dependencyInputs).should == true;
    builds.should == 3;
    inputReads.should == 3;

    sandbox.writeFile("root.d", "changed root again");
    changedSettings.prepare(hit, () {
            ++sources;
            return atomicSource ~ "\nenum changedSource = 1;\n";
        },
        () {
            ++builds;
        },
        &makeImage, true, &dependencyInputs).should == true;
    sources.should == 3;
    builds.should == 4;
    inputReads.should == 4;

    auto empty = ProjectImageCache(buildPath(directory, "empty.json"),
        "settings", [root]);
    empty.prepare(hit, () => "", () {}, &failImage, false,
        &dependencyInputs).should == false;
}
