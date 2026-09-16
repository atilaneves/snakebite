module ut.ffi.symbol;


import ut;
import snakebite.ffi: Resolver;
import snakebite.dependencyimage: defaultCompiler, prepareImage;
import std.file: timeLastModified;
import core.atomic: atomicStore;
import snakebite.exception: SnakebiteException;
import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.file: dirEntries, SpanMode;
import std.array: array;

private enum atomicSource = q{
    module image;
    import core.atomic: atomicLoad;
    export extern(C) int image_atomic_load(shared int* value) {
        return atomicLoad(*value);
    }
};

@("image.atomicLoad.cache")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    auto image = prepareImage(atomicSource, directory);
    const stamp = timeLastModified(image.path);
    auto reused = prepareImage(atomicSource, directory);
    reused.path.should == image.path;
    timeLastModified(reused.path).should == stamp;
    auto resolver = Resolver(&reused);
    alias Load = extern(C) int function(shared int*);
    const load = cast(Load) resolver.resolve("image_atomic_load");
    load.should.not == null;
    shared int value;
    foreach (expected; [0, 42, -7, int.min, int.max]) {
        atomicStore(value, expected);
        load(&value).should == expected;
    }
    resolver.resolve("abs").should.not == null;
    resolver.resolve("image_missing_symbol").should == null;
}

@("image.sourceChange")
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    auto first = prepareImage("export extern(C) int answer() { return 1; }", directory);
    auto second = prepareImage("export extern(C) int answer() { return 2; }", directory);
    first.path.should.not == second.path;
    alias Answer = extern(C) int function();
    (cast(Answer) first.resolve("answer"))().should == 1;
    (cast(Answer) second.resolve("answer"))().should == 2;
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
    const directory = sandbox.sandboxPath;
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
        const sandbox = Sandbox();
        const directory = sandbox.sandboxPath;
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
@Serial
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
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
