module at.runtime.startup;


import ut.backends;
import std.algorithm: canFind;
import std.conv: text;
import std.file: getcwd, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: Config, execute, thisProcessID;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read static constructor counters"),
)) {
    @("moduleConstructorsRunOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("constructors", [q{
            module probe;
            __gshared int sharedCalls;
            int threadCalls;
            shared static this() {
                ++sharedCalls;
            }
            static this() {
                assert(sharedCalls == 1);
                ++threadCalls;
            }
            unittest {
                assert(sharedCalls == 1);
                assert(threadCalls == 1);
            }
        }], [], 0, ["1 modules passed unittests"], []);
    }
}


static foreach (backend; Matrix!()) {
    @("templateMixinTests." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("mixin", [q{
            module probe;
            mixin template Tests() {
                unittest { assert(false, "mixin unittest ran"); }
            }
            mixin Tests!();
        }], [], 1, ["mixin unittest ran", "1/1 modules FAILED unittests"],
            ["All unit tests have been run successfully."]);
    }

    @("defaultTestRunner." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("default", [q{
            module probe;
            unittest { assert(2 + 2 == 4); }
        }], [], 0, ["1 modules passed unittests"],
            ["All unit tests have been run successfully."]);
    }

    @("defaultRunnerContinuesAfterFailedModule." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("continue", [q{
            module probe;
            unittest { assert(false, "first module failed"); }
        }, q{
            module second;
            unittest { assert(false, "second module failed"); }
        }], [], 1, ["first module failed", "second module failed",
            "2/2 modules FAILED unittests"],
            ["All unit tests have been run successfully."]);
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE cannot modify druntime test hooks"),
)) {
    @("runnerOutputDoesNotHideHostSummary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("streams", [q{
            module probe;
            import core.runtime: Runtime, UnitTestResult;
            import std.stdio: File, stdout, stderr;
            shared static this() {
                Runtime.extendedModuleUnitTester = () {
                    stdout = File("/dev/null", "w");
                    stderr = File("/dev/null", "w");
                    return UnitTestResult(1, 1, false, false);
                };
            }
        }], [], 0, is(backend == Native) ? [] : ["frontend time:", "run time:"], []);
    }

    @("extendedTestRunnerArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("extended", [q{
            module probe;
            import core.runtime: Runtime, UnitTestResult;
            import std.stdio: writeln;
            shared static this() {
                Runtime.extendedModuleUnitTester = () {
                    assert(Runtime.args[1 .. $] == ["-d", "selected test"]);
                    writeln("custom runner called");
                    return UnitTestResult(1, 1, false, false);
                };
            }
            unittest { assert(false, "custom runner must select tests"); }
        }], ["-d", "selected test"], 0, ["custom runner called"],
            ["All unit tests have been run successfully."]);
    }

    @("failedTestRunnerSkipsMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        checkStartup!backend("failed", [q{
            module probe;
            import core.runtime: Runtime, UnitTestResult;
            shared static this() {
                Runtime.extendedModuleUnitTester = () {
                    return UnitTestResult(2, 1, true, true);
                };
            }
        }], [], 1, ["1/2 modules FAILED unittests"],
            ["All unit tests have been run successfully."]);
    }

}


private void checkStartup(Backend)(
    in string name, in string[] sources, in string[] arguments,
    in int status, in string[] present, in string[] absent,
) {
    const directory = buildPath(tempDir,
        text("snakebite-startup-", thisProcessID, "-", name, "-", Backend.stringof));
    directory.buildPath("source").mkdirRecurse;
    scope(exit) directory.rmdirRecurse;
    directory.buildPath("dub.sdl").write(
        "name \"startup-probe\"\ntargetType \"library\"\n"
        ~ "configuration \"unittest\" {\n}\n");
    foreach (i, source; sources)
        directory.buildPath("source", i == 0 ? "probe.d" : "second.d").write(source);

    static if (is(Backend == Native))
        const result = execute(["dub", "test", "--compiler=dmd", "--"]
            ~ arguments, null, Config.none, size_t.max, directory);
    else {
        import snakebite.backends: backendIdentity;
        const result = execute([
            buildPath(getcwd, "bin", "sb"), "-b",
            backendIdentity!Backend.text, directory, "--",
        ] ~ arguments);
    }
    const expectedStatus = is(Backend == Native) && status == 1 ? 2 : status;
    if (result.status != expectedStatus)
        fail(text("Expected status ", expectedStatus, ", got ", result.status,
            "\n", result.output), __FILE__, __LINE__);
    foreach (message; present)
        if (!result.output.canFind(message))
            fail(text("Missing: ", message, "\n", result.output), __FILE__, __LINE__);
    foreach (message; absent)
        if (result.output.canFind(message))
            fail(text("Unexpected: ", message, "\n", result.output), __FILE__, __LINE__);
}
