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
                bool delegate(out int) fetch;
                this(bool delegate(out int) fetch) {
                    this.fetch = fetch;
                }
                ~this() {}
                int read() {
                    int result;
                    fetch(result);
                    return result;
                }
            }
            void main() {
                auto resource = new Resource((out int value) {
                    value = 42;
                    return true;
                });
                assert(resource.read() == 42);
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

    @("moduleUnittestNestedDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-unittest-context-" ~ thisProcessID.text
                ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            unittest {
                int value = 42;
                auto read = () { return value; };
                assert(read() == 42);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
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

static foreach (backend; Matrix!()) {
    @("staticArrayComparison." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-array-comparison-" ~ thisProcessID.text
                ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            unittest {
                ubyte[4] values = [23, 13, 42, 71];
                assert(values == [23, 13, 42, 71]);
                assert(values != [23, 13, 42, 72]);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "10", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the native Fiber page size"),
)) {
    @("fiberCapturedDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-fiber-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.thread: Fiber;
            unittest {
                int value;
                auto fiber = new Fiber({
                    value = 17;
                    value += 25;
                }, 64 * 1024, 0);
                fiber.call();
                assert(value == 42);
                assert(fiber.state == Fiber.State.TERM);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "10", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the native Fiber page size"),
)) {
    @("fiberYieldingDelegates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-fiber-yield-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.thread: Fiber;
            int threadCount;
            int useStack(int value) {
                int[128] values;
                values[127] = value;
                return values[127];
            }
            unittest {
                int first, second;
                auto a = new Fiber({
                    int local = 17;
                    ++threadCount;
                    first = local;
                    Fiber.yield();
                    first = local + 25;
                });
                auto b = new Fiber({
                    int local = 31;
                    ++threadCount;
                    second = local;
                    Fiber.yield();
                    second = local + 26;
                });
                a.call();
                b.call();
                assert(first == 17 && second == 31);
                assert(threadCount == 2);
                a.call();
                assert(first == 42);
                assert(useStack(73) == 73);
                b.call();
                assert(second == 57);
                assert(a.state == Fiber.State.TERM);
                assert(b.state == Fiber.State.TERM);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "10", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the native Fiber page size"),
)) {
    @("fiberInterfaceRecursion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-fiber-interface-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.thread: Fiber;
            interface Walker { void walk(uint depth); }
            class RecursiveWalker: Walker {
                int count;
                override void walk(uint depth) {
                    ++count;
                    if (depth) {
                        Walker next = this;
                        next.walk(depth - 1);
                    } else {
                        Fiber.yield();
                    }
                }
            }
            unittest {
                auto walker = new RecursiveWalker;
                auto fiber = new Fiber({ walker.walk(6); });
                fiber.call();
                assert(walker.count == 7);
                assert(fiber.state == Fiber.State.HOLD);
                fiber.call();
                assert(fiber.state == Fiber.State.TERM);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "10", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the native Fiber page size"),
)) {
    @("fiberDeepRecursion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-fiber-deep-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.thread: Fiber;
            int finished;
            int descend(int depth) {
                scope(exit) ++finished;
                if (depth == 0) {
                    Fiber.yield();
                    return 3;
                }
                return descend(depth - 1) + depth;
            }
            unittest {
                int result;
                auto fiber = new Fiber({ result = descend(64); });
                fiber.call();
                assert(finished == 0);
                assert(fiber.state == Fiber.State.HOLD);
                fiber.call();
                assert(result == 2083);
                assert(finished == 65);
                assert(fiber.state == Fiber.State.TERM);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "10", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's interpreter stops guest recursion at a fixed depth of 1000"),
)) {
    @("deepRecursion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-deep-recursion-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            int depth(int n) { return n == 0 ? 0 : 1 + depth(n - 1); }
            unittest { assert(depth(100_000) == 100_000); }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else enum name = "bytecode";
            const result = execute([
                "timeout", "60", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot start a native thread"),
)) {
    @("deepRecursionInAGuestThread." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-thread-deep-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.thread: Thread;
            int depth(int n) { return n == 0 ? 0 : 1 + depth(n - 1); }
            unittest {
                int result;
                auto thread = new Thread({ result = depth(100_000); });
                thread.start;
                thread.join;
                assert(result == 100_000);
            }
            void main() {}
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else enum name = "bytecode";
            const result = execute([
                "timeout", "60", buildPath(getcwd, "bin", "sb"),
                "-b", name, directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}


// A call of a compiler intrinsic that no wrapper covers ends the run at
// the call's first decision and names the intrinsic. Compiled D has the
// instruction, and dmd's CTFE gives its own message.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "compiled D inlines the instruction"),
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `__simd`"),
)) {
    @("intrinsicWithoutWrapperNamesItself." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-intrinsic-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.simd;
            void main() {
                float4 a = 1, b = 2;
                float4 c = cast(float4) __simd(XMM.ADDPS, a, b);
            }
        });
        static if (is(backend == Interpreter)) enum name = "interpreter";
        else enum name = "bytecode";
        const result = execute([
            "timeout", "60", buildPath(getcwd, "bin", "sb"),
            "-b", name, directory,
        ]);
        result.status.should.not == 0;
        "no builtin wrapper for `core.simd.__simd`".should.be in result.output;
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: variable `pool` cannot be modified at compile time"),
)) {
    @("taskPoolReduceRunsToCompletion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-task-pool-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "app.d");
        source.write(q{
            module app;
            import std.parallelism;
            import std.range : iota;
            unittest {
                auto s = taskPool.reduce!"a + b"(iota(1, 101));
                assert(s == 5050);
            }
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-unittest", "-main", "-run", source],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "60", buildPath(getcwd, "bin", "sb"),
                "-b", name, "--no-optimise-image", directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}


static foreach (backend; Matrix!()) {
    @("fileIsRelativeToTheDubProject." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-cli-file-path-" ~ thisProcessID.text ~ backend.stringof);
        mkdirRecurse(buildPath(directory, "source"));
        mkdirRecurse(buildPath(directory, "tests", "pkg"));
        scope(exit) directory.rmdirRecurse;
        buildPath(directory, "dub.sdl").write(
            "name \"app\"\nsourcePaths \"source\" \"tests\"\n"
            ~ "importPaths \"source\" \"tests\"\n");
        buildPath(directory, "source", "app.d").write(
            "module app;\nvoid main() {}\n");
        buildPath(directory, "tests", "pkg", "behave.d").write(q{
            module pkg.behave;
            unittest {
                assert(__FILE__ == "tests/pkg/behave.d", __FILE__);
            }
        });
        static if (is(backend == Native))
            const result = execute(["dub", "test"],
                null, Config.none, size_t.max, directory);
        else {
            static if (is(backend == Interpreter)) enum name = "interpreter";
            else static if (is(backend == Bytecode)) enum name = "bytecode";
            else enum name = "ctfe";
            const result = execute([
                "timeout", "60", buildPath(getcwd, "bin", "sb"),
                "-b", name, "--no-optimise-image", directory,
            ]);
        }
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}
