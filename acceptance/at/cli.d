module at.cli;


import ut.backends;
import std.conv: text;
import std.file: getcwd, mkdir, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: Config, execute, thisProcessID;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run class finalizers"),
)) {
    @("classDestructorAtShutdown." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-destructor-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.stdc.stdio: puts;
            class Resource {
                ~this() { puts("resource finalized"); }
            }
            void allocate() { auto resource = new Resource; }
            void main() { allocate(); }
        });
        static if (is(backend == Native))
            // DMD writes object files in its working directory, even with -run.
            const result = execute(["dmd", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter))
                enum name = "interpreter";
            else static if (is(backend == Bytecode))
                enum name = "bytecode";
            else
                enum name = "ctfe";
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b", name,
                directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }

    @("classInvariantAtShutdown." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-invariant-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            class Base {
                invariant { assert(true); }
            }
            class Resource: Base {
                ~this() {}
            }
            void main() {
                auto resource = new Resource;
                destroy(resource);
            }
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter))
                enum name = "interpreter";
            else static if (is(backend == Bytecode))
                enum name = "bytecode";
            else
                enum name = "ctfe";
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b", name,
                directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}


static foreach (backend; Matrix!()) {
    @("versionOptions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-version-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "version_probe.d");
        source.write(q{
            version (AutomemAsan) {} else static assert(false);
            version (Extra) {} else static assert(false);
            int main() { return 42; }
        });
        static if (is(backend == Native)) {
            const versions = ["-version=AutomemAsan", "-version=Extra"];
            const result = execute(["dmd"] ~ versions ~ ["-run", source],
                null, Config.none, size_t.max, directory);
        } else {
            const versions = ["--version=AutomemAsan", "--version=Extra"];
            static if (is(backend == Interpreter))
                enum name = "interpreter";
            else static if (is(backend == Bytecode))
                enum name = "bytecode";
            else
                enum name = "ctfe";
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b", name,
            ] ~ versions ~ [directory]);
        }
        if (result.status != 42)
            fail(result.output, __FILE__, __LINE__);
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "Imported function bodies lose version flags during deferred CTFE analysis"),
)) {
    @("dubVersionOptions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-dub-version-" ~ thisProcessID.text ~ backend.stringof);
        const app = buildPath(directory, "app");
        const dependency = buildPath(directory, "dependency");
        buildPath(app, "source").mkdirRecurse;
        buildPath(dependency, "source").mkdirRecurse;
        scope(exit) directory.rmdirRecurse;
        buildPath(app, "dub.sdl").write(q{
            name "version-app"
            targetType "library"
            dependency "version-dependency" path="../dependency"
        });
        buildPath(dependency, "dub.sdl").write(q{
            name "version-dependency"
            targetType "staticLibrary"
        });
        buildPath(app, "source", "app.d").write(q{
            module app;
            import dependency;
            version (AutomemAsan) {} else static assert(false);
            unittest { assert(answer() == 42); }
        });
        buildPath(dependency, "source", "dependency.d").write(q{
            module dependency;
            int answer() {
                version (AutomemAsan) return 42;
                else return 17;
            }
        });
        static if (is(backend == Native))
            const result = execute([
                "dub", "test", "--compiler=dmd", "--d-version=AutomemAsan",
            ], null, Config.none, size_t.max, app);
        else {
            static if (is(backend == Interpreter))
                enum name = "interpreter";
            else static if (is(backend == Bytecode))
                enum name = "bytecode";
            else
                enum name = "ctfe";
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b", name,
                "--version=AutomemAsan", app,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE rejects calls with host arguments"),
)) {
    @("programArgumentsAfterSeparator." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            int main(string[] args) {
                assert(args.length == 8);
                assert(args[0].length > 0);
                assert(args[1 .. $] == [
                    "-d", "--help", "-b", "ctfe", "test name", "--", "",
                ]);
                return 42;
            }
        });
        const arguments = [
            "-d", "--help", "-b", "ctfe", "test name", "--", "",
        ];
        static if (is(backend == Native))
            const result = execute(["dmd", "-run", source] ~ arguments,
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter))
                enum name = "interpreter";
            else static if (is(backend == Bytecode))
                enum name = "bytecode";
            else
                enum name = "ctfe";
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b", name, directory, "--",
            ] ~ arguments);
        }
        if (result.status != 42)
            fail(text("Expected exit status 42, got ", result.status,
                ": ", result.output), __FILE__, __LINE__);
    }
}
