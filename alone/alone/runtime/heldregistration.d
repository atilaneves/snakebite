module alone.runtime.heldregistration;

import core.memory: GC;
import core.thread: Thread;
import core.time: msecs;
import snakebite.program: Program;
import snakebite.run.program: run;
import snakebite.run.modules: GuestModules;
import snakebite.frontend.compiler: parseSnippet;
import std.file: exists;
import ut.backends;

static foreach (backend; Matrix!(
    Omit!(
        Native,
        Because.inexpressible,
        "the Native arm runs no guest program in the test process, so no registration exists",
    ),
    Omit!(
        Ctfe,
        Because.inexpressible,
        "CTFE cannot run module destructors",
    ),
)) {
    // A live thread keeps the registration of its ended program, so the
    // count of registrations that wait for the end of the process rises by
    // one. The handshake keeps that thread alive until the count is checked.
    // A thread that another test starts would keep its own registration and
    // change the count. The program runs on the test's own thread: druntime
    // warns at the end of the process about a DSO that a joined thread
    // registered.
    @("registrationHeldByThreadIsLeftToTheEndOfTheProcess." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GC.collect;
        const sandbox = Sandbox();
        const before = GuestModules.held.leftToExit;
        const readyPath = sandbox.inSandboxPath("ready");
        const code = heldByWorkerCode(sandbox);

        scope(exit) {
            sandbox.writeFile("release");
            if (exists(readyPath))
                waitForSandboxFile(sandbox, "done");
        }
        programStatus!backend(code).should == 0;
        waitForSandboxFile(sandbox, "ready");
        GuestModules.held.leftToExit.should == before + 1;
    }

    // The registration belongs to the process, not to the thread that ran the
    // program, so a thread that did not run the program sees it in the count
    // too.
    @("registrationLeftToTheEndOfTheProcessIsHeldForOtherThreads." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GC.collect;
        const sandbox = Sandbox();
        const before = GuestModules.held.leftToExit;
        const readyPath = sandbox.inSandboxPath("ready");
        const code = heldByWorkerCode(sandbox);

        scope(exit) {
            sandbox.writeFile("release");
            if (exists(readyPath))
                waitForSandboxFile(sandbox, "done");
        }

        programStatus!backend(code).should == 0;
        waitForSandboxFile(sandbox, "ready");
        ptrdiff_t seen;
        auto reader = new Thread({ seen = GuestModules.held.leftToExit; });
        reader.start;
        reader.join;
        seen.should == before + 1;
    }
}

// Guest code whose shared destructor starts a thread that stays alive until
// the `release` file exists, then writes `done`.
private string heldByWorkerCode(in Sandbox sandbox) {
    return "enum readyPath = `" ~ sandbox.inSandboxPath("ready") ~ "`;\n"
        ~ "enum releasePath = `" ~ sandbox.inSandboxPath("release") ~ "`;\n"
        ~ "enum donePath = `" ~ sandbox.inSandboxPath("done") ~ "`;\n"
        ~ q{
            import core.thread: Thread;
            import core.time: msecs;
            import std.file: exists, write;

            shared static ~this() {
                new Thread({
                    write(readyPath, "ready");
                    foreach (_; 0 .. 5_000) {
                        if (exists(releasePath)) {
                            write(donePath, "done");
                            return;
                        }
                        Thread.sleep(1.msecs);
                    }
                }).start;
                foreach (_; 0 .. 5_000) {
                    if (exists(readyPath))
                        return;
                    Thread.sleep(1.msecs);
                }
            }

            void main() {}
        };
}

private int programStatus(Backend)(in string code) {
    auto program = Program([parseSnippet(code)]);
    auto backend = ownedBackend!Backend(program);
    return run(
        backend.startData,
        backend.compilationStatistics,
        ["snakebite"],
    );
}

private void waitForSandboxFile(Sandbox sandbox, in string fileName) {
    const path = sandbox.inSandboxPath(fileName);
    foreach (_; 0 .. 5_000) {
        if (exists(path))
            return;
        Thread.sleep(1.msecs);
    }
    throw new Exception("timed out waiting for `" ~ path ~ "`");
}
