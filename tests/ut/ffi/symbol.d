module ut.ffi.symbol;


import ut;
import snakebite.ffi: Resolver;
import snakebite.dependencyimage: defaultCompiler, prepareImage;
import std.file: mkdirRecurse, rmdirRecurse, tempDir, timeLastModified;
import std.path: buildPath;
import std.conv: text;
import std.uuid: randomUUID;
import core.atomic: atomicStore;
import snakebite.exception: SnakebiteException;
import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.file: dirEntries, SpanMode, write;
import std.array: array;

private enum atomicSource = q{
    module image;
    import core.atomic: atomicLoad;
    export extern(C) int image_atomic_load(shared int* value) {
        return atomicLoad(*value);
    }
};

private string cacheDirectory() {
    const path = buildPath(tempDir, text("snakebite-image-", randomUUID));
    mkdirRecurse(path);
    return path;
}

@("image.atomicLoad.cache")
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
    auto image = prepareImage(atomicSource, directory);
    const stamp = timeLastModified(image.path);
    auto reused = prepareImage(atomicSource, directory);
    reused.path.should == image.path;
    timeLastModified(reused.path).should == stamp;
    auto resolver = Resolver(&reused);
    alias Load = extern(C) int function(shared int*);
    const load = cast(Load) resolver.resolve("image_atomic_load");
    assert(load !is null);
    shared int value;
    foreach (expected; [0, 42, -7, int.min, int.max]) {
        atomicStore(value, expected);
        load(&value).should == expected;
    }
    assert(resolver.resolve("abs") !is null);
    assert(resolver.resolve("image_missing_symbol") is null);
}

@("image.sourceChange")
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
    auto first = prepareImage("export extern(C) int answer() { return 1; }", directory);
    auto second = prepareImage("export extern(C) int answer() { return 2; }", directory);
    assert(first.path != second.path);
    alias Answer = extern(C) int function();
    (cast(Answer) first.resolve("answer"))().should == 1;
    (cast(Answer) second.resolve("answer"))().should == 2;
}

@("image.compileFailure")
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
    (() { auto image = prepareImage("this is invalid D", directory); })()
        .shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}

@("image.linkFailure")
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
    (() {
        auto image = prepareImage(q{
            extern(C) int image_missing_dependency();
            export extern(C) int answer() { return image_missing_dependency(); }
        }, directory);
    })().shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}

@("image.compilerFamily")
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
    version (DigitalMars)
        const otherCompiler = "ldc2";
    else
        const otherCompiler = "dmd";
    (() {
        auto image = prepareImage(atomicSource, directory, otherCompiler);
    })().shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}

@("image.inputChange")
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
    const input = buildPath(directory, "settings");
    input.write("first");
    auto first = prepareImage(atomicSource, directory,
        defaultCompiler, [input]);
    input.write("second");
    auto second = prepareImage(atomicSource, directory,
        defaultCompiler, [input]);
    assert(first.path != second.path);
}

static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("image.atomicLoad." ~ backend.stringof)
    unittest {
        const directory = cacheDirectory;
        scope(exit) rmdirRecurse(directory);
        auto image = prepareImage(atomicSource, directory);
        shared int value = 42;
        static if (is(backend == Native)) {
            alias Load = extern(C) int function(shared int*);
            (cast(Load) image.resolve("image_atomic_load"))(&value).should == 42;
        } else {
            auto module_ = parseSnippet(q{
                extern(C) int image_atomic_load(shared int*);
                int answer(shared int* value) {
                    return image_atomic_load(value);
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
unittest {
    const directory = cacheDirectory;
    scope(exit) rmdirRecurse(directory);
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
        assert(resolver.resolve("abs") !is null);

    resolver.lookups.should == 1;
}


@("missing.resolved.once")
unittest {
    Resolver resolver;

    foreach (_; 0 .. 100)
        assert(resolver.resolve(
            "snakebite_symbol_that_does_not_exist",
        ) is null);

    resolver.lookups.should == 1;
}
