module ut.flags;


import core.sys.posix.signal: SIGILL;
import snakebite.dependencyimage: defaultCompiler;
import std.file: getcwd;
import std.path: buildPath;
import std.process: Config, execute;
import ut;
import ut.backends;


// Compiler flags change what a program means, so each test here runs a
// whole project: the oracle is the same unittest, compiled with the same
// flags by the compiler snakebite was built with, and the backends are
// `bin/sb` on a dub project whose recipe names the flags. A halt ends the
// process, so no run can happen inside `bin/ut`.
private struct Outcome {
    int status;
    string output;
}


private alias NoCtfe = Omit!(Ctfe, Because.inexpressible,
    "the program logs through the native `fputs`, which CTFE cannot call");


private enum prelude = q{
    module app;
    import core.stdc.stdio: fputs, stderr;
    @trusted void log(string text) { fputs(text.ptr, stderr); }
};


private Outcome unittestsOf(Backend)(in string[] flags, in string source) {
    const sandbox = Sandbox();
    const code = prelude ~ source;

    static if (is(Backend == Native)) {
        sandbox.writeFile("native/app.d", code);
        const directory = sandbox.inSandboxPath("native");
        const compiled = execute(
            [defaultCompiler, "-unittest", "-main", "-of=" ~ buildPath(directory, "app")]
                ~ flags ~ [buildPath(directory, "app.d")]);
        compiled.status.shouldEqual(0, compiled.output);
        const result = execute([buildPath(directory, "app")]);
    } else {
        string recipe = "name \"app\"\ntargetType \"library\"\n";
        foreach (flag; flags)
            recipe ~= "dflags \"" ~ flag ~ "\"\n";
        sandbox.writeFile("outside/.keep");
        sandbox.writeFile("app/dub.sdl", recipe);
        sandbox.writeFile("app/source/app.d", code);
        enum backendName = is(Backend == Bytecode) ? "bytecode" : "interpreter";
        const result = execute(
            [buildPath(getcwd, "bin", "sb"), "--backend=" ~ backendName,
                "--no-optimise-image", sandbox.inSandboxPath("app")],
            null,
            Config.none,
            size_t.max,
            sandbox.inSandboxPath("outside"),
        );
    }

    return Outcome(result.status, result.output);
}


// A halt kills the process with SIGILL (`ud2`), so the log ends where the
// halt happened.
private void shouldHaltAfterStart(in Outcome outcome) {
    outcome.status.should == -SIGILL;
    "start".should.be in outcome.output;
    "after".should.not.be in outcome.output;
}


private void shouldPassAfterStart(in Outcome outcome) {
    outcome.status.should == 0;
    "start".should.be in outcome.output;
    "after".should.be in outcome.output;
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("checkactionHalt.failedAssertHaltsTheProcess." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-checkaction=halt"], q{
            unittest {
                int x = 1;
                log("start\n");
                assert(x == 2);
                log("after\n");
            }
        }).shouldHaltAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("checkactionHalt.failedAssertOnClassSkipsItsInvariant." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        // The halt form of `assert(e)` is `e || halt`: it never reaches the
        // invariant call that the default form makes after the test passes.
        unittestsOf!backend(["-checkaction=halt"], q{
            class C {
                int x = 1;
                invariant { assert(x > 0); }
            }
            unittest {
                auto c = new C;
                c.x = -1;
                log("start\n");
                assert(c);
                log("after\n");
            }
        }).shouldPassAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("checkactionHalt.finalSwitchOnNonMemberHalts." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-checkaction=halt"], q{
            enum E { a, b }
            unittest {
                E e = cast(E) 7;
                log("start\n");
                final switch (e) { case E.a: break; case E.b: break; }
                log("after\n");
            }
        }).shouldHaltAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("checkactionHalt.indexOutOfBoundsHalts." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-checkaction=halt"], q{
            unittest {
                int[4] storage = [1, 2, 3, 4];
                int[] slice = storage[0 .. 2];
                log("start\n");
                auto value = slice[3];
                log("after\n");
            }
        }).shouldHaltAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("checkactionHalt.sliceOutOfBoundsHalts." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-checkaction=halt"], q{
            unittest {
                int[4] storage = [1, 2, 3, 4];
                int[] slice = storage[0 .. 2];
                log("start\n");
                auto value = slice[0 .. 3];
                log("after\n");
            }
        }).shouldHaltAfterStart;
    }
}


// `dmd -unittest -release` keeps `assert`: unittest mode turns assertions
// on before `-release` turns them off.
static foreach (backend; Matrix!(NoCtfe)) {
    @("release.assertStaysOnInUnittests." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        const outcome = unittestsOf!backend(["-release"], q{
            unittest {
                int x = 1;
                log("start\n");
                assert(x == 2);
                log("after\n");
            }
        });
        outcome.status.should == 1;
        "AssertError".should.be in outcome.output;
        "after".should.not.be in outcome.output;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.preconditionIsNotChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-release"], q{
            int positive(int x) in (x > 0) { return x; }
            unittest {
                log("start\n");
                positive(-1);
                log("after\n");
            }
        }).shouldPassAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.postconditionIsNotChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-release"], q{
            int positive(int x) out (result; result > 0) { return x; }
            unittest {
                log("start\n");
                positive(-1);
                log("after\n");
            }
        }).shouldPassAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.invariantIsNotChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-release"], q{
            class C {
                int x = 1;
                invariant { assert(x > 0); }
                void set(int value) { x = value; }
            }
            unittest {
                auto c = new C;
                log("start\n");
                c.set(-1);
                log("after\n");
            }
        }).shouldPassAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.assertOnClassDoesNotCheckItsInvariant." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-release"], q{
            class C {
                int x = 1;
                invariant { assert(x > 0); }
            }
            unittest {
                auto c = new C;
                c.x = -1;
                log("start\n");
                assert(c);
                log("after\n");
            }
        }).shouldPassAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.contractVersionsAreUndefined." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        const outcome = unittestsOf!backend(["-release"], q{
            unittest {
                version (D_PreConditions) log("pre\n"); else log("nopre\n");
                version (D_PostConditions) log("post\n"); else log("nopost\n");
                version (D_Invariants) log("inv\n"); else log("noinv\n");
                version (assert) log("assert\n"); else log("noassert\n");
            }
        });
        outcome.status.should == 0;
        "nopre".should.be in outcome.output;
        "nopost".should.be in outcome.output;
        "noinv".should.be in outcome.output;
        "\nassert".should.be in outcome.output;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.finalSwitchOnNonMemberHalts." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        unittestsOf!backend(["-release"], q{
            enum E { a, b }
            @system unittest {
                E e = cast(E) 7;
                log("start\n");
                final switch (e) { case E.a: break; case E.b: break; }
                log("after\n");
            }
        }).shouldHaltAfterStart;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.indexOutOfBoundsInSafeCodeIsChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        const outcome = unittestsOf!backend(["-release"], q{
            @safe unittest {
                int[4] storage = [1, 2, 3, 4];
                int[] slice = storage[0 .. 2];
                log("start\n");
                auto value = slice[3];
                log("after\n");
            }
        });
        outcome.status.should == 1;
        "ArrayIndexError".should.be in outcome.output;
        "after".should.not.be in outcome.output;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.indexOutOfBoundsInSystemCodeIsNotChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        // The slice stops at 2 but the storage behind it has a fourth
        // element, so the unchecked read is well defined.
        const outcome = unittestsOf!backend(["-release"], q{
            @system unittest {
                int[4] storage = [1, 2, 3, 4];
                int[] slice = storage[0 .. 2];
                log("start\n");
                if (slice[3] == 4)
                    log("after\n");
            }
        });
        outcome.status.should == 0;
        "after".should.be in outcome.output;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.sliceOutOfBoundsInSafeCodeIsChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        const outcome = unittestsOf!backend(["-release"], q{
            @safe unittest {
                int[4] storage = [1, 2, 3, 4];
                int[] slice = storage[0 .. 2];
                log("start\n");
                auto value = slice[0 .. 3];
                log("after\n");
            }
        });
        outcome.status.should == 1;
        "ArraySliceError".should.be in outcome.output;
        "after".should.not.be in outcome.output;
    }
}


static foreach (backend; Matrix!(NoCtfe)) {
    @("release.sliceOutOfBoundsInSystemCodeIsNotChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        const outcome = unittestsOf!backend(["-release"], q{
            @system unittest {
                int[4] storage = [1, 2, 3, 4];
                int[] slice = storage[0 .. 2];
                log("start\n");
                if (slice[0 .. 3].length == 3)
                    log("after\n");
            }
        });
        outcome.status.should == 0;
        "after".should.be in outcome.output;
    }
}
