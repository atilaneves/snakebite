module ut.projectoptions;


import snakebite.projectoptions: parseProjectOptions, ProjectOptions;
import ut;


// The caller's own options are parsed in the same pass, and nothing after
// `--` is parsed or removed.
@("parseProjectOptions.splitsAtSeparator")
unittest {
    ProjectOptions options;
    uint runs;
    auto args = [
        "tool", "-I", "src", "-r", "3", "project",
        "--", "-r", "9", "-I", "x",
    ];

    parseProjectOptions(args, options, "r", "Runs.", &runs);

    args.should == ["tool", "project"];
    runs.should == 3;
    options.importPaths.should == ["src"];
    options.programArguments.should == ["-r", "9", "-I", "x"];
}
