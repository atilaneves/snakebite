module ut.ffi.symbol;


import ut;
import snakebite.ffi: Resolver;
import snakebite.dependencyimage: DependencyImage, ProjectImageCache, defaultCompiler, prepareImage;
import std.file: timeLastModified;
import core.atomic: atomicStore, MemoryOrder;
import core.internal.atomic: atomicLoad;
import core.thread: Thread;
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
import std.file: exists, readText, remove, setTimes;
import std.path: buildPath;

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
            (error.next !is null).should == true;
            "image compile diagnostic".shouldBeIn(error.next.msg);
            throw error;
        }
    })().shouldThrowWithMessage!SnakebiteException(
        "Dependency image compilation failed");
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
            (error.next !is null).should == true;
            "image_missing_dependency".shouldBeIn(error.next.msg);
            throw error;
        }
    })().shouldThrowWithMessage!SnakebiteException(
        "Dependency image linking failed");
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
        archive.remove;
        auto rebuilt = prepareProject(directory).project;
        archive.exists.should == true;
        rebuilt.program.dependencyImage.path.should == changedPath;
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
    auto image = prepareImage(atomicSource, directory);
    auto cache = ProjectImageCache(directory, "settings", [root]);
    cache.save(image.path, atomicSource, [dependency]);
    auto next = ProjectImageCache(directory, "settings", [root]);
    DependencyImage hit;
    string unexpectedSource() {
        throw new Exception("An unchanged image must skip source generation");
    }
    next.restore(hit, &unexpectedSource).should == true;
    hit.path.should == image.path;

    sandbox.writeFile("root.d", "changed root");
    next.restore(hit, () => atomicSource).should == true;
    auto changedSettings = ProjectImageCache(directory, "other settings", [root]);
    changedSettings.restore(hit, () => atomicSource).should == false;

    // A preserved mtime and size must not hide a changed dependency.
    const stamp = timeLastModified(dependency);
    sandbox.writeFile("dependency.d", "after!");
    setTimes(dependency, stamp, stamp);
    next.restore(hit, () => atomicSource).should == false;
}
