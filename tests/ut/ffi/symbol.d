module ut.ffi.symbol;


import ut;
import snakebite.ffi: Resolver;
import snakebite.dependencyimage:
    DependencyImage, ProjectImageCache, defaultCompiler, loadImage;
import core.thread: Thread;
import snakebite.execution: prepareProject;
import snakebite.dependencyimage: Optimise;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import snakebite.frontend.imagesource: imageInputs, imageSource;
import ut.backends;
import std.file: setTimes, timeLastModified;
import std.path: buildPath;


// A shared object that the build of `bin/ut` made (tests/fixtures/native):
// no test here starts a compiler. The tests of what a built image holds are
// in tests/run_cli.py, which runs the real `bin/sb`.
private enum emptyImageSource = "module image;\n";

private string symbolsLibrary() {
    return nativeFixture("symbols.so");
}

@("image.symbolSurvivesImageScope")
unittest {
    alias Answer = extern(C) int function();
    Answer answer;
    {
        auto image = loadImage(symbolsLibrary);
        answer = cast(Answer) image.resolve("retainedAnswer");
    }
    answer.should.not == null;
    answer().should == 381;
}

@("image.symbolSurvivesLoadingThread")
unittest {
    alias Answer = extern(C) int function();
    Answer answer;
    const library = symbolsLibrary;
    auto thread = new Thread({
        auto image = loadImage(library);
        answer = cast(Answer) image.resolve("threadRetainedAnswer");
    });
    thread.start;
    thread.join;
    answer.should.not == null;
    answer().should == 381;
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


// `bin/ut` (`--export-dynamic`) exports this under the same linker name a
// separately loaded shared object below also defines. A guest-declared
// symbol must resolve to the loaded shared object's copy, not to this one:
// snakebite itself can hold a native instantiation of a template a guest
// program also calls (`dirEntries` in `snakebite.project`, see
// docs/adr/0008), built with the host compiler's own closure layout, and a
// guest backend reading that layout back would see garbage.
export extern(C) int snakebite_symbol_dual_definition_test() { return 999; }

@("symbolAddress.loadedSharedObjectAnswersBeforeExecutable")
unittest {
    import core.sys.posix.dlfcn: dlclose, dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.string: toStringz;

    enum name = "snakebite_symbol_dual_definition_test";
    auto image = loadImage(symbolsLibrary);

    // `RTLD_GLOBAL` is what puts a shared object's symbols into the
    // process-wide scope the fix searches (`RTLD_NEXT` in `symbolAddress`);
    // `loadImage` keeps the image `RTLD_LOCAL` so it never
    // answers a lookup this way, only through the `DependencyImage` it
    // returns (a separate, already-tested tier). This second `dlopen` on
    // the same path does not load a second copy: it promotes the same
    // already-loaded object into the global scope.
    auto handle = dlopen(image.path.toStringz, RTLD_NOW | RTLD_GLOBAL);
    handle.should.not == null;
    scope(exit) dlclose(handle);

    Resolver resolver;
    alias Answer = extern(C) int function();
    const answer = cast(Answer) resolver.resolve(name);
    answer.should.not == null;
    answer().should == 511;
}

// A name of its own, never defined in `bin/ut` itself: nothing here masks
// the answer with a symbol the executable-only test above (or any other
// test's promoted shared object) already put in the process-wide scope.
@("resolveIndependent.stillAnswersFromALoadedSharedObject")
unittest {
    import core.sys.posix.dlfcn: dlclose, dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.string: toStringz;

    enum name = "snakebite_symbol_independent_only_test";
    auto image = loadImage(symbolsLibrary);

    auto handle = dlopen(image.path.toStringz, RTLD_NOW | RTLD_GLOBAL);
    handle.should.not == null;
    scope(exit) dlclose(handle);

    Resolver resolver;
    alias Answer = extern(C) int function();
    const answer = cast(Answer) resolver.resolveIndependent(name);
    answer.should.not == null;
    answer().should == 522;
}


// Nothing but `bin/ut` itself defines this symbol: the executable is still
// the answer when no dependency image and no other loaded shared object
// has it, the same as any native fixture `bin/ut`/`bin/at` build straight
// into the test binary.
export extern(C) int snakebite_symbol_executable_only_test() { return 733; }

@("symbolAddress.fallsBackToExecutableWhenNothingElseHasIt")
unittest {
    Resolver resolver;
    alias Answer = extern(C) int function();
    const answer = cast(Answer)
        resolver.resolve("snakebite_symbol_executable_only_test");
    answer.should.not == null;
    answer().should == 733;
}

// `resolveIndependent` answers the question `CallSelection.buildDecision`
// (`snakebite.backends.calls`) asks for a template instance: `resolve`
// still finds this executable-only symbol (the test right above), but
// `resolveIndependent` must never reach that last-resort tier - a guest
// call through a template instance must not bind to `bin/ut`'s own copy
// just because nothing else answers the name.
@("resolveIndependent.neverFallsBackToExecutable")
unittest {
    Resolver resolver;
    resolver.resolveIndependent(
        "snakebite_symbol_executable_only_test",
    ).should == null;
}


// The image source must import the module that names a template argument
// (`Thread`), or the instantiation `_d_newclassT!Thread` cannot be
// spelled in the image and falls back to the guest. Nothing here needs the
// built image: only the text that is made for it.
@("image.templateArgumentImports")
unittest {
    // Program requires a mutable AST.
    auto module_ = parseSnippet(q{
        import core.lifetime: _d_newclassT;
        import core.thread.osthread: Thread;
        Thread allocate() { return _d_newclassT!Thread(); }
    });
    const source = imageSource(Program([module_]));
    "import core.thread.osthread;".should.be in source;
}


// A source file that the program imports but does not own is an input of the
// built image, so that changing it invalidates the cache.
@("image.inputsNameImportedFiles")
unittest {
    // Program requires a mutable AST.
    auto module_ = parseSnippet(q{
        import core.thread.osthread: Thread;
        Thread allocate() { return null; }
    });
    import std.algorithm: any, endsWith;

    imageInputs(Program([module_]))
        .any!(path => path.endsWith("osthread.d")).should == true;
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
    // Nothing here needs the built image: only the source that is made for it.
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports, null, false, optimise: Optimise.no).project;
    const source = imageSource(project.program);
    "Thing".should.not.be in source;
    (moduleName ~ ".store!(" ~ moduleName ~ ".Bucket!(string, void delegate(int)))")
        .should.be in source;
}


// `apply!(plain)`'s only template argument is an alias to `plain`, a
// module-level dependency function - a normal dependency, not a local one.
// A walk that treats the aliased symbol itself as "function-local" merely
// because it is a `FuncDeclaration` (rather than checking its *ancestors*
// for an enclosing function, see `imagesource.d`'s
// `hasFunctionLocalType`) wrongly drops this instantiation from the image.
@("image.aliasArgumentDependencyFunction")
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
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports, null, false, optimise: Optimise.no).project;
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
// reached here through an alias argument instead (see `imagesource.d`'s
// `eachFoundSymbol`, used from both `eachTemplateArgumentSymbol`'s
// `toDsymbol` path and `eachTemplateArgument`'s `isDsymbol` path). The
// instantiation must not leak an unresolvable, unqualified `Thing` spelling
// into the image.
@("image.aliasArgumentNestedRootType")
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
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports, null, false, optimise: Optimise.no).project;
    const source = imageSource(project.program);
    "apply!".should.not.be in source;
}


// `image.aliasArgumentNestedRootType` uses a single-member eponymous
// template (`pick(T)()`), so dmd collapses `pick!Thing` in `apply`'s tiargs
// down to the member `pick!Thing.pick` before it ever reaches
// `eachFoundSymbol` - the enclosing `TemplateInstance` is already
// `symbol.parent`, so climbing ancestors starting there finds it. A
// multi-member dependency template is not collapsed: the alias argument
// *is* the `TemplateInstance` itself, whose `.parent` is the module, so a
// climb starting at `symbol.parent` never reaches its tiargs and the
// root-owned `Thing` nested inside leaks through unresolved. The climb in
// `eachFoundSymbol` must therefore start at `symbol` itself, not
// `symbol.parent`. `apply!(pick!int)()` is the positive control: every type
// it nests is dependency-owned or built in, so it must still resolve.
@("image.aliasArgumentTemplateInstanceRootType")
unittest {
    const sandbox = Sandbox();
    enum moduleName = "image_alias_instance_root";
    sandbox.writeFile("deps/" ~ moduleName ~ ".d",
        "module " ~ moduleName ~ ";\n" ~ q{
            void apply(alias f)() {}
            template pick(T) {
                void one() {}
                void two() {}
            }
        });
    sandbox.writeFile("app/root_" ~ moduleName ~ ".d",
        "module root_" ~ moduleName ~ ";\nimport " ~ moduleName ~ ";\n" ~ q{
        class Thing {}
        void trigger() {
            apply!(pick!Thing)();
            apply!(pick!int)();
        }
    });
    const imports = [sandbox.inSandboxPath("deps")];
    auto project = prepareProject(sandbox.inSandboxPath("app"), imports, null, false, optimise: Optimise.no).project;
    const source = imageSource(project.program);
    // The registry holds the guest mangle of `pick!Thing`'s members, so the
    // name `Thing` appears. The alias argument must not.
    "apply!(__T4pickTC".should.not.be in source;
    "apply!".should.be in source;
}


// The image source of a program with one root module.
private string snippetImageSource(in string code) {
    // Program requires a mutable AST.
    return imageSource(Program([parseSnippet(code)]));
}


// `atomicLoad` has inline assembler, so only its native instance runs. The
// image compiles it over a stand-in for the root type `Pair`, which the image
// cannot name, and still registers it under the guest's name, which holds
// `Pair`.
@("image.opaqueInstance.pointee")
unittest {
    const source = snippetImageSource(q{
        import core.atomic: atomicLoad;
        struct Pair { int first, second; }
        shared Pair pair;
        int answer() { shared(Pair*) pointer = &pair; return atomicLoad(pointer).first; }
    });
    "struct SnakebiteOpaque0;".should.be in source;
    "atomicLoad!(MemoryOrder.seq, shared(SnakebiteOpaque0)*)".should.be in source;
    "4Pair".should.be in source;
    "shared(Pair".should.not.be in source;
}


@("image.opaqueInstance.classReference")
unittest {
    const source = snippetImageSource(q{
        import core.atomic: atomicLoad;
        class Node { int value; }
        int answer() { shared Node node; return atomicLoad(node).value; }
    });
    // A class stand-in has a member list: it has a size.
    "class SnakebiteOpaque0 {}".should.be in source;
}


@("image.opaqueInstance.interfaceReference")
unittest {
    const source = snippetImageSource(q{
        import core.atomic: atomicLoad;
        interface Face {}
        int answer() { shared Face face; return atomicLoad(face) is null; }
    });
    "interface SnakebiteOpaque0;".should.be in source;
}


@("image.opaqueInstance.enumValue")
unittest {
    const source = snippetImageSource(q{
        import core.atomic: atomicLoad, atomicStore;
        enum Color : ubyte { red, green }
        int answer() { shared Color color; atomicStore(color, Color.green); return atomicLoad(color); }
    });
    "atomicLoad!(MemoryOrder.seq, ubyte)".should.be in source;
    "SnakebiteOpaque".should.not.be in source;
}


@("image.opaqueInstance.oneStandInPerRootType")
unittest {
    const source = snippetImageSource(q{
        import core.atomic: atomicLoad, atomicStore;
        struct Pair { int first, second; }
        shared Pair pair;
        shared(Pair*) pointer;
        void answer() {
            atomicLoad(pointer);
            atomicStore(pointer, &pair);
        }
    });
    "atomicExchange!(MemoryOrder.seq, false, shared(SnakebiteOpaque0)*)".should.be in source;
    "atomicLoad!(MemoryOrder.seq, shared(SnakebiteOpaque0)*)".should.be in source;
    "SnakebiteOpaque1".should.not.be in source;
}


// An instance without inline assembler keeps its guest body: the template
// decides from the enum at compile time, which a stand-in would change.
@("image.rootTypedInstanceStaysInGuest")
unittest {
    const source = snippetImageSource(q{
        import std.conv: text;
        enum Color : ubyte { red, green }
        int answer() { return cast(int) text(Color.green).length; }
    });
    "Color".should.not.be in source;
}


static foreach (backend; Matrix!()) {
    @("image.hashWithCtfeHelper." ~ backend.stringof)
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
            auto instance = Owned!backend(program);
            int result;
            instance.call(findFunction(module_, "answer"), &result, []);
            result.should == 17;
        }
    }
}


@("image.projectCacheSkipsPreparation")
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
    DependencyImage makeImage(in string) {
        return loadImage(symbolsLibrary);
    }
    cache.prepare(*image,
        () {
            ++sources;
            return emptyImageSource;
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
            return emptyImageSource;
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
    changedSettings.prepare(hit, () => emptyImageSource, () {
            ++builds;
        }, &makeImage, true,
        &dependencyInputs).should == true;
    builds.should == 2;
    inputReads.should == 2;

    // A preserved mtime and size must not hide a changed dependency.
    const stamp = timeLastModified(dependency);
    sandbox.writeFile("dependency.d", "after!");
    setTimes(dependency, stamp, stamp);
    changedSettings.prepare(hit, () => emptyImageSource, () {
            ++builds;
        }, &makeImage, true,
        &dependencyInputs).should == true;
    builds.should == 3;
    inputReads.should == 3;

    sandbox.writeFile("root.d", "changed root again");
    changedSettings.prepare(hit, () {
            ++sources;
            return emptyImageSource ~ "\nenum changedSource = 1;\n";
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


// "No image" is an answer like an image is: unchanged inputs give it back
// without generating the source, and a changed input asks again, whichever
// way the answer then goes.
@("image.projectCacheRemembersNoImage")
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("root.d", "root");
    sandbox.writeFile("dependency.d", "before");
    const root = sandbox.inSandboxPath("root.d");
    const dependency = sandbox.inSandboxPath("dependency.d");
    const directory = sandbox.sandboxPath;
    const record = buildPath(directory, "project.json");
    string[] dependencyInputs() {
        return [dependency.idup];
    }
    DependencyImage makeImage(in string) {
        return loadImage(symbolsLibrary);
    }
    DependencyImage failImage(in string) {
        throw new Exception("A project that needs no image must not build one");
    }
    size_t sources;
    string countedSource(in string source) {
        ++sources;
        return source;
    }
    DependencyImage image;

    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    sources.should == 1;

    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    sources.should == 1;

    // A root edit that still calls no dependency template.
    sandbox.writeFile("root.d", "changed root");
    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    sources.should == 2;
    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    sources.should == 2;

    // A root edit that now calls one.
    sandbox.writeFile("root.d", "root that calls a dependency template");
    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(emptyImageSource), () {}, &makeImage,
            false, &dependencyInputs)
        .should == true;
    sources.should == 3;
    image.path.length.should.not == 0;

    // And back again.
    sandbox.writeFile("root.d", "root");
    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    sources.should == 4;

    // A dependency edit asks again, even with the roots unchanged.
    sandbox.writeFile("dependency.d", "after");
    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(emptyImageSource), () {}, &makeImage,
            false, &dependencyInputs)
        .should == true;
    sources.should == 5;

    // Settings are an input of the answer too.
    sandbox.writeFile("dependency.d", "before");
    ProjectImageCache(record, "settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    ProjectImageCache(record, "other settings", [root])
        .prepare(image, () => countedSource(""), () {}, &failImage, false,
            &dependencyInputs)
        .should == false;
    sources.should == 7;
}


// The recorded image is a function of the generator that built it, not
// only of its inputs: a new snakebite binary must not reuse an image an
// older binary produced, even when nothing about the project changed.
@("image.projectCacheDetectsChangedGenerator")
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("root.d", "root");
    const root = sandbox.inSandboxPath("root.d");
    const directory = sandbox.sandboxPath;
    const record = buildPath(directory, "project.json");
    sandbox.writeFile("generator-stand-in", "generator v1");
    const generator = sandbox.inSandboxPath("generator-stand-in");
    string[] noInputs() { return []; }
    DependencyImage makeImage(in string) {
        return loadImage(symbolsLibrary);
    }

    auto cache = ProjectImageCache(record, "settings", [root], defaultCompiler, generator);
    auto image = new DependencyImage;
    cache.prepare(*image, () => emptyImageSource, () {}, &makeImage, true,
        &noInputs).should == true;

    // Same generator, unchanged: the recorded image is restored.
    auto unchanged = ProjectImageCache(record, "settings", [root], defaultCompiler, generator);
    DependencyImage hit;
    size_t sourceCalls;
    unchanged.prepare(hit, () {
            ++sourceCalls;
            return emptyImageSource;
        },
        () {
            throw new Exception("An unchanged generator must skip preparation");
        },
        &makeImage, true, &noInputs).should == true;
    hit.path.should == image.path;
    sourceCalls.should == 0;

    // A rebuilt generator at the same path must be treated as a cache
    // miss: the recorded image was produced by a binary that no longer
    // exists in that form.
    sandbox.writeFile("generator-stand-in", "generator v2, rebuilt");
    auto rebuilt = ProjectImageCache(record, "settings", [root], defaultCompiler, generator);
    DependencyImage regenerated;
    size_t regeneratedSourceCalls;
    size_t builds;
    rebuilt.prepare(regenerated, () {
            ++regeneratedSourceCalls;
            return emptyImageSource;
        },
        () { ++builds; },
        &makeImage, true, &noInputs).should == true;
    regeneratedSourceCalls.should == 1;
    builds.should == 1;
}


// Two different generators that share a record path, as two builds of
// snakebite do on one project, never accept each other's image. Each keeps
// its own record, so alternating between them rebuilds nothing.
@("image.projectCacheKeepsGeneratorsApart")
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("root.d", "root");
    const root = sandbox.inSandboxPath("root.d");
    const directory = sandbox.sandboxPath;
    const record = buildPath(directory, "project.json");
    sandbox.writeFile("generator-a", "generator a");
    sandbox.writeFile("generator-b", "generator b, a different build");
    const generatorA = sandbox.inSandboxPath("generator-a");
    const generatorB = sandbox.inSandboxPath("generator-b");
    string[] noInputs() { return []; }
    DependencyImage makeImage(in string) {
        return loadImage(symbolsLibrary);
    }

    size_t builds;
    void prepare(in string generator) {
        auto cache = ProjectImageCache(record, "settings", [root],
            defaultCompiler, generator);
        DependencyImage image;
        cache.prepare(image, () => emptyImageSource, () { ++builds; },
            &makeImage, true, &noInputs).should == true;
    }

    prepare(generatorA);
    builds.should == 1;
    prepare(generatorB);
    builds.should == 2;
    prepare(generatorA);
    prepare(generatorB);
    builds.should == 2;
}

