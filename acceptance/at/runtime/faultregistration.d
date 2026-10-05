module at.runtime.faultregistration;

import core.memory: GC;
import core.thread: Thread;
import core.time: msecs;
import snakebite.backends.backend: Program, run;
import snakebite.backends.guestmodules: GuestModules;
import snakebite.dependencyimage: defaultCompiler;
import snakebite.frontend.compiler: parseSnippet;
import std.file: exists;
import std.process: execute;
import ut.backends;

// A live thread keeps the registration of its ended program. The handshake
// keeps that thread alive until the count is checked. Use the serial CI group
// so threads from other tests cannot keep this registration alive.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run module destructors"),
)) {
    @("registrationHeldByThreadIsLeftToTheEndOfTheProcess." ~ backend.stringof)
    // `alone` selects the serial group after the master test migration.
    // Keep `timing` until that CI selection is present on this branch too.
    @Tags(backend.stringof, "timing", "alone")
    unittest {
        GC.collect;
        const sandbox = Sandbox();
        const before = GuestModules.held.leftToExit;
        static if (is(backend == Native)) {
            programStatus!backend(sandbox, q{
                import core.thread: Thread;
                import core.time: msecs;
                shared static ~this() {
                    new Thread({ Thread.sleep(50.msecs); }).start;
                }
                void main() {}
            }).should == 0;
            GuestModules.held.leftToExit.should == before;
        } else {
            const readyPath = sandbox.inSandboxPath("ready");
            const releasePath = sandbox.inSandboxPath("release");
            const donePath = sandbox.inSandboxPath("done");
            const code =
                "enum readyPath = `" ~ readyPath ~ "`;\n"
                ~ "enum releasePath = `" ~ releasePath ~ "`;\n"
                ~ "enum donePath = `" ~ donePath ~ "`;\n"
                ~ q{
                    import core.thread: Thread;
                    import core.time: msecs;
                    import std.file: exists, write;

                    shared static ~this() {
                        auto worker = new Thread({
                            write(readyPath, "ready");
                            foreach (_; 0 .. 5_000) {
                                if (exists(releasePath)) {
                                    write(donePath, "done");
                                    return;
                                }
                                Thread.sleep(1.msecs);
                            }
                        });
                        worker.start;
                        foreach (_; 0 .. 5_000) {
                            if (exists(readyPath))
                                return;
                            Thread.sleep(1.msecs);
                        }
                    }

                    void main() {}
                };

            scope(exit) {
                sandbox.writeFile("release");
                if (exists(readyPath))
                    waitForSandboxFile(sandbox, "done");
            }
            programStatus!backend(sandbox, code).should == 0;
            waitForSandboxFile(sandbox, "ready");
            GuestModules.held.leftToExit.should == before + 1;
        }
    }
}

private int programStatus(Backend)(in Sandbox sandbox, in string code) {
    static if (is(Backend == Native)) {
        sandbox.writeFile("guest.d", code);
        const executable = sandbox.inSandboxPath("guest");
        const built = execute([defaultCompiler,
            sandbox.inSandboxPath("guest.d"), "-of=" ~ executable]);
        built.status.should == 0;
        return execute([executable]).status;
    } else {
        auto program = Program([parseSnippet(code)]);
        return run(new Backend(program), program);
    }
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
