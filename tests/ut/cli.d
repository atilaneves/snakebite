module ut.cli;


import snakebite.driver.cli: parseArgs;
import snakebite.backends: BackendName;
import std.algorithm.searching: startsWith;
import ut;


@("versionOptions")
unittest {
    const result = parseArgs([
        "sb", "--version=AutomemAsan", "--version=Extra", "project",
        "--", "-version=GuestOnly",
    ]);

    result.status.should == 0;
    result.options.versions.should == ["AutomemAsan", "Extra"];
    result.options.programArguments.should == ["-version=GuestOnly"];
}


@("loadRefusesLowmem")
unittest {
    const result = parseArgs([
        "sb", "-b", "bytecode", "--load=program.sbc", "--lowmem",
    ]);

    result.status.should == 1;
    result.diagnostic.startsWith(
        "--load takes none of the options that describe a compile")
        .should == true;
}


@("buildProjectOfDubProject")
unittest {
    const result = parseArgs(["sb", "--build=project", "examples/rt-simple"]);

    result.status.should == 0;
    result.options.projectDirectory.should == "examples/rt-simple";
}


// The values of a compile come from the dub recipe: `--build=project` takes
// no option that changes the compile, no directory without a dub recipe,
// and neither `--save` nor `--load`. Only the bytecode backend has it.
@("buildProjectRefusals")
unittest {
    const string[][] refused = [
        ["--save=program.sbc", "project"],
        ["--load=program.sbc"],
        ["-b", "interpreter", "project"],
        ["-I", "imports", "project"],
        ["-J", "strings", "project"],
        ["--version=Extra", "project"],
        ["--no-optimise-image", "project"],
        ["--jit-perf-map", "project"],
        ["examples/empty"],
    ];
    foreach (arguments; refused) {
        const result = parseArgs(["sb", "--build=project"] ~ arguments);
        result.status.should == 1;
        result.diagnostic.startsWith("--build=project").should == true;
    }
}


@("programArgumentsAfterSeparator")
unittest {
    const result = parseArgs([
        "sb", "-b", "bytecode", "project", "--", "-d", "--help",
        "-b", "ctfe", "test name", "--", "",
    ]);

    result.status.should == 0;
    result.options.showHelp.should == false;
    result.options.backend.should == BackendName.bytecode;
    result.options.projectDirectory.should == "project";
    result.options.programArguments.should == [
        "-d", "--help", "-b", "ctfe", "test name", "--", "",
    ];
}


@("emptyProgramArgumentsAfterSeparator")
unittest {
    const result = parseArgs(["sb", "project", "--"]);

    result.status.should == 0;
    result.options.projectDirectory.should == "project";
    result.options.programArguments.length.should == 0;
}

@("jitPerfMapOption")
unittest {
    const defaults = parseArgs(["sb", "project"]);
    defaults.status.should == 0;
    defaults.options.jitPerfMap.should == false;

    const enabled = parseArgs(["sb", "--jit-perf-map", "project"]);
    enabled.status.should == 0;
    enabled.options.jitPerfMap.should == true;

    const guest = parseArgs(["sb", "project", "--", "--jit-perf-map"]);
    guest.status.should == 0;
    guest.options.jitPerfMap.should == false;
    guest.options.programArguments.should == ["--jit-perf-map"];
}


@("separatorDoesNotSupplyProjectDirectory")
unittest {
    const result = parseArgs(["sb", "--", "project", "-d"]);

    result.status.should == 1;
    result.diagnostic.startsWith("expected one project directory").should == true;
}


unittest {
    const result = parseArgs(["sb", "examples/rt-simple"]);

    result.status.should == 0;
    result.options.projectDirectory.should == "examples/rt-simple";
    result.options.backend.should == BackendName.bytecode;
}


unittest {
    const result = parseArgs([
        "sb", "-b", "bytecode", "-I", "imports", "-J", "strings", "project",
    ]);

    result.status.should == 0;
    result.options.backend.should == BackendName.bytecode;
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
