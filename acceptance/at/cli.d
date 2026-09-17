module at.cli;


import ut.backends;
import std.conv: text;
import std.file: getcwd, mkdir, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: execute, thisProcessID;


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
            const result = execute(["dmd", "-run", source] ~ arguments);
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
            fail(result.output, __FILE__, __LINE__);
    }
}
