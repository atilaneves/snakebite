module at.ffi.image;


import ut;
import snakebite.dependencyimage: Optimise, defaultCompiler, prepareImage;
import snakebite.exception: SnakebiteException;
import std.array: array;
import std.conv: text;
import std.file: SpanMode, dirEntries, exists, rmdirRecurse, thisExePath;
import std.path: absolutePath;
import std.process: Config, environment, execute;
import std.string: replace;
import core.thread: Thread;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.project: prepareStartupDependencies, sourceSet;


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


private bool _startupAnalysisReset;
private size_t _startupWorkerCalls;
private Throwable _startupWorkerFailure;

private extern(C) void startupImageWorker() {
    ++_startupWorkerCalls;
    try {
        // The root exists only in the scratch registration, not on an import
        // path. A successful import here would mean image load preceded reset.
        try
            parseSnippet("import startup_analysis_root;");
        catch (Exception)
            _startupAnalysisReset = true;

        auto worker = new Thread({
            try
                parseSnippet("module startup_image_worker_module; enum value = 42;");
            catch (Throwable failure)
                _startupWorkerFailure = failure;
        });
        worker.start;
        worker.join;
    } catch (Throwable failure) {
        _startupWorkerFailure = failure;
    }
}


// Image constructors can wait for frontend work. Use the real startup and
// image-load path: a lock held across load would prevent the join, and a
// reset after load would remove the worker's module. Scratch cannot share
// a process with another test's live frontend session. Bound the entire child
// process so a blocked frontend worker cannot hang the acceptance runner.
@Tags("alone")
@("image.startupAnalysisEndsBeforeImageConstructor")
unittest {
    const sandbox = Sandbox();
    enum childMarker = "SNAKEBITE_STARTUP_IMAGE_PROBE";
    if (environment.get(childMarker) != "1") {
        // The parent owns the child working directory, including files left
        // by a process killed while building or loading the image.
        scope(exit) if (sandbox.sandboxPath.exists)
            sandbox.sandboxPath.rmdirRecurse;
        const result = execute([
            "timeout", "--kill-after=5", "60", thisExePath, "-s",
            "at.ffi.image.image.startupAnalysisEndsBeforeImageConstructor",
        ], [childMarker: "1"], Config.none, size_t.max,
            sandbox.sandboxPath.absolutePath);
        result.status.shouldEqual(0, text("Startup image probe failed (exit ",
            result.status, "): ", result.output));
        return;
    }
    sandbox.writeFile("project/startup_analysis_root.d",
        "module startup_analysis_root; int answer() { return 42; }");
    // Pass the address within this process: no executable export is needed.
    sandbox.writeFile("constructor.c", q{
        #include <stdint.h>
        __attribute__((constructor)) static void on_load(void) {
            void (*action)(void) = (void (*)(void))(uintptr_t)@ACTION@;
            action();
        }
    }.replace("@ACTION@", text(cast(size_t) &startupImageWorker)));
    const objectPath = sandbox.inSandboxPath("constructor.o");
    const compiled = execute(["cc", "-c", "-fPIC",
        sandbox.inSandboxPath("constructor.c"), "-o", objectPath]);
    compiled.status.should == 0;
    const directory = sandbox.inSandboxPath("project");
    auto sources = sourceSet(directory, [], []);
    sources.linkerFiles = [objectPath];
    const image = prepareStartupDependencies(directory, sources, Optimise.no);
    (image !is null).should == true;
    _startupWorkerCalls.should == 1;
    _startupAnalysisReset.should == true;
    if (_startupWorkerFailure !is null)
        throw _startupWorkerFailure;
    parseSnippet("import startup_image_worker_module; static assert(value == 42);");
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
