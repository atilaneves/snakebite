module at.ffi.image;


import ut;
import snakebite.dependencyimage: Optimise, defaultCompiler, prepareImage;
import snakebite.exception: SnakebiteException;
import std.array: array;
import std.file: SpanMode, dirEntries;
import std.process: execute;


// `bin/at` is built with ldc2, so `defaultCompiler` is ldc2 here. The image
// compiler invocation differs between ldc2 and dmd: another spelling for
// version and debug flags, no `-allinst`, and another set of link flags.


// `-version=`, `-debug` and `-debug=` are dmd spellings that ldc2 only
// accepts as `-d-version=`, `-d-debug` and `-d-debug=`.
@("image.versionAndDebugFlags")
unittest {
    const sandbox = Sandbox();
    auto image = prepareImage(q{
        module image;

        export extern(C) int answer() {
            int result;
            version (AtImageFlag)
                result += 40;
            debug
                result += 2;
            debug (AtImageDebug)
                result += 100;
            return result;
        }
    }, sandbox.inSandboxPath("cache"), defaultCompiler, null, null, null,
        ["-version=AtImageFlag", "-debug", "-debug=AtImageDebug"],
        optimise: Optimise.no);
    alias Answer = extern(C) int function();
    (cast(Answer) image.resolve("answer"))().should == 142;
}


// D checks a member function of a template instance only when something uses
// it, so a dependency can hold an unused member that a strict project flag
// such as `-preview=dip1000` would reject. `-allinst` forces the compiler to
// check every member of every instance, including the ones no call reaches,
// so an image built with it fails on such a dependency even though the
// dependency's own build passes. An ldc2 image must emit only the referenced
// bodies.
@("image.unusedTemplateMemberIsNotAnalysed")
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
    }, sandbox.inSandboxPath("cache"), defaultCompiler, [dependency],
        [sandbox.inSandboxPath("deps")], null, ["-preview=dip1000"],
        [objectPath], optimise: Optimise.no);
    alias Answer = extern(C) int function();
    (cast(Answer) image.resolve("answer"))().should == 42;
}


// An image that refers to a symbol that nothing defines must fail to build,
// instead of building and failing when the library loads or the function is
// called. A failed build leaves nothing in the cache directory.
@("image.undefinedSymbolFailsToBuild")
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    (() {
        try {
            auto image = prepareImage(q{
                extern(C) int image_missing_dependency();
                export extern(C) int answer() { return image_missing_dependency(); }
            }, directory, optimise: Optimise.no);
        } catch (SnakebiteException error) {
            "Dependency image linking failed".shouldBeIn(error.msg);
            "image_missing_dependency".shouldBeIn(error.msg);
            throw error;
        }
    })().shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}


// A dmd binary does not accept the flags of the ldc2 image compile, so an
// image build with it fails in the compile step. A failed build leaves
// nothing in the cache directory.
@("image.compilerOfOtherFamilyFails")
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.sandboxPath;
    (() {
        try {
            auto image = prepareImage(q{
                export extern(C) int answer() { return 42; }
            }, directory, "dmd", optimise: Optimise.no);
        } catch (SnakebiteException error) {
            "Dependency image compilation failed".shouldBeIn(error.msg);
            throw error;
        }
    })().shouldThrow!SnakebiteException;
    dirEntries(directory, SpanMode.shallow).array.length.should == 0;
}
