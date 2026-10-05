module at.stackrelease;


// `bin/sb-repl` is built with `-release`, as is this binary, so only a
// test here sees what a release build does; `bin/ut` is a debug build.
// A leaked frame stack is a reservation of address space, so the virtual
// size of a REPL process that evaluated many cells shows it. The process is
// a child of its own, so no other test changes its numbers.


import ut;
import std.algorithm.iteration: filter;
import std.array: array, split;
import std.conv: to;
import std.path: absolutePath;
import std.process: pipeProcess, Redirect, wait;
import std.string: startsWith, strip;


// The REPL buffers its output until it ends, so the guest reads its own
// virtual size, before and after the cells that it evaluates in between.
private enum imports =
    "import std.file: readText;\n"
    ~ "import std.string: splitLines, startsWith;\n"
    ~ "import std.algorithm: find;\n";
private enum virtualSize =
    `readText("/proc/self/status").splitLines`
    ~ `.find!(l => l.startsWith("VmSize:"))[0]` ~ "\n";


static foreach (backend; ["interpreter", "bytecode"]) {
    @("stackrelease.repl.cellsDoNotAccumulateAddressSpace." ~ backend)
    unittest {
        enum cells = 200;
        auto repl = pipeProcess(
            ["bin/sb-repl".absolutePath, "-b", backend],
            Redirect.stdin | Redirect.stdout,
        );
        repl.stdin.write(imports ~ virtualSize);
        foreach (_; 0 .. cells)
            repl.stdin.write("1 + 1\n");
        repl.stdin.write(virtualSize);
        repl.stdin.close;
        const lines = repl.stdout.byLineCopy.array;
        wait(repl.pid).should == 0;

        const sizes = lines.filter!(l => l.startsWith("VmSize:")).array;
        sizes.length.should == 2;
        const grownKiB = virtualKiB(sizes[1]) - virtualKiB(sizes[0]);

        // A leaked frame stack reserves a gibibyte. A cell may use some
        // address space for other data, but not a quarter of that.
        enum limitKiB = cells * (256UL << 10);
        (grownKiB < limitKiB).should == true;
    }
}


private size_t virtualKiB(in string line) {
    return line["VmSize:".length .. $].strip.split(' ')[0].to!size_t;
}
