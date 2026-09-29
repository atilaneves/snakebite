module at.process;


// Every snakebite executable sets up the one process runtime
// (`snakebite.process`): the guest shares its druntime, so a guest reads
// the same GC configuration the host set. `--lowmem` puts the frontend's
// memory back in the GC heap, where a guest sees the AST as used bytes.


import ut;
import std.path: absolutePath;
import std.process: execute, pipeProcess, Redirect, wait;


// A guest program that checks the process GC configuration. The AST of
// a program that imports Phobos is tens of megabytes; the guest's own
// data is well under one.
private enum probe = q{
    import core.gc.config: config;
    import core.memory: GC;
    import std.stdio: writeln;

    void main() {
        enum frontendBytes = 16 << 20;
        version (Lowmem)
            assert(GC.stats.usedSize > frontendBytes);
        else
            assert(GC.stats.usedSize < frontendBytes);
        assert(config.gc == "snakebite");
        assert(config.cleanup == "none");
        assert(config.heapSizeFactor == 4);
    }
};


static foreach (lowmem; [false, true]) {
    @("options.sb." ~ (lowmem ? "lowmem" : "default"))
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("probe.d", probe);

        const result = execute(["bin/sb".absolutePath, "-b", "bytecode"]
            ~ lowmemArguments(lowmem) ~ sandbox.sandboxPath);
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }

    @("options.bench." ~ (lowmem ? "lowmem" : "default"))
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("probe.d", probe);

        const result = execute(["bin/bench".absolutePath, "-b", "bytecode",
            "-r", "1", "-w", "0"] ~ lowmemArguments(lowmem)
            ~ sandbox.sandboxPath);
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }

    @("options.repl." ~ (lowmem ? "lowmem" : "default"))
    unittest {
        import std.algorithm.iteration: splitter;
        import std.array: array;
        import std.conv: to;
        import std.string: strip;

        auto repl = pipeProcess(
            ["bin/sb-repl".absolutePath] ~ (lowmem ? ["--lowmem"] : []),
            Redirect.stdin | Redirect.stdout,
        );
        repl.stdin.write(
            "import core.gc.config: config;\n"
            ~ "import core.memory: GC;\n"
            ~ "import std.stdio;\n"
            ~ "config.gc\n"
            ~ "config.cleanup\n"
            ~ "GC.stats.usedSize\n");
        repl.stdin.close;
        string output;
        foreach (line; repl.stdout.byLine)
            output ~= line ~ "\n";
        wait(repl.pid).should == 0;

        const lines = output.strip.splitter("\n").array;
        lines[$ - 3].should == "snakebite";
        lines[$ - 2].should == "none";
        const used = lines[$ - 1].to!size_t;
        (used > 16 << 20).should == lowmem;
    }
}


private string[] lowmemArguments(in bool lowmem) {
    return lowmem ? ["--lowmem", "--version=Lowmem"] : [];
}
