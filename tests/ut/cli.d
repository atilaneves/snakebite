module ut.cli;


import snakebite.cli: parseArgs;
import std.algorithm.searching: startsWith;
import ut;


unittest {
    const result = parseArgs(["sb", "examples/rt-simple"]);

    result.status.should == 0;
    result.options.projectDirectory.should == "examples/rt-simple";
    result.options.backend.should == "interpreter";
}


unittest {
    const result = parseArgs([
        "sb", "-b", "bytecode", "-I", "imports", "-J", "strings", "project",
    ]);

    result.status.should == 0;
    result.options.backend.should == "bytecode";
    result.options.importPaths.should == ["imports"];
    result.options.stringImportPaths.should == ["strings"];
    result.options.projectDirectory.should == "project";
}


unittest {
    const result = parseArgs(["sb"]);

    result.status.should == 1;
    result.diagnostic.startsWith("expected one project directory").should == true;
}


unittest {
    const result = parseArgs(["sb", "first", "second"]);

    result.status.should == 1;
    result.diagnostic.startsWith("expected one project directory").should == true;
}


unittest {
    const result = parseArgs(["sb", "-b", "unknown", "project"]);

    result.status.should == 1;
    result.diagnostic.startsWith("unknown backend: unknown").should == true;
}


unittest {
    const result = parseArgs(["sb", "--help"]);

    result.status.should == 0;
    result.options.showHelp.should == true;
    result.diagnostic.startsWith("Usage: sb ").should == true;
}
