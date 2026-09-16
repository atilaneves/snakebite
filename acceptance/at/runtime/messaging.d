module at.runtime.messaging;


import ut.backends;
import std.algorithm: canFind;
import std.conv: text;
import std.file: getcwd, mkdir, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: execute, thisProcessID;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run threads or file IO"),
)) {
    @("writerReceivesStringWithMultipleHandlers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir,
            "snakebite-writer-" ~ thisProcessID.text ~ backend.stringof);
        directory.mkdir;
        scope(exit) directory.rmdirRecurse;
        const source = buildPath(directory, "probe.d");
        source.write(q{
            import core.time: seconds;
            import std.concurrency;
            import std.stdio: stdout, write;

            struct Flush {}

            void writer(Tid parent) {
                const received = receiveTimeout(2.seconds,
                    (string message, Tid origin) {
                        assert(origin == parent);
                        write(message);
                        stdout.flush;
                        parent.send(true);
                    },
                    (Flush message, Tid origin) { assert(false); },
                );
                assert(received);
            }

            void main(string[] args) {
                assert(args.length == 1);
                auto thread = spawn(&writer, thisTid);
                thread.send("worker output\n", thisTid);
                bool finished;
                assert(receiveTimeout(3.seconds,
                    (bool success) { finished = success; },
                ));
                assert(finished);
            }
        });
        static if (is(backend == Native))
            const result = execute(["dmd", "-run", source]);
        else {
            static if (is(backend == Interpreter))
                enum name = "interpreter";
            else
                enum name = "bytecode";
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b", name, directory,
            ]);
        }
        if (result.status != 0 || !result.output.canFind("worker output\n"))
            fail(result.output, __FILE__, __LINE__);
    }
}
