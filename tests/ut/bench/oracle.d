module ut.bench.oracle;


import bench.oracle: cyclePieces, oracleReport;
import core.time: Duration, msecs;
import snakebite.project: sourceSet;
import std.conv: text;
import std.file: mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: thisProcessID;
import ut;


// A dub project: the touched cycle is dub, the compiler, the linker and
// the run; with nothing to rebuild it is dub and the run.
@("cyclePieces.dub")
unittest {
    const pieces = cyclePieces(172.msecs, 15.msecs, 92.msecs, 2.msecs);

    pieces.overhead.should == 13.msecs;
    pieces.compile.should == 65.msecs;
    pieces.run.should == 67.msecs;
}


// A bare directory: the cycle is the build plus the run, with nothing to
// rebuild it is the run alone, so there is no overhead.
@("cyclePieces.bare")
unittest {
    const pieces = cyclePieces(160.msecs, 2.msecs, 92.msecs, 2.msecs);

    pieces.overhead.should == Duration.zero;
    pieces.compile.should == 66.msecs;
    pieces.run.should == 68.msecs;
}


// Noise on a tiny project can make a difference negative; it reports as
// zero rather than as a negative time.
@("cyclePieces.neverNegative")
unittest {
    const pieces = cyclePieces(10.msecs, 12.msecs, 11.msecs, 13.msecs);

    pieces.overhead.should == Duration.zero;
    pieces.compile.should == Duration.zero;
    pieces.run.should == 13.msecs;
}


// The test runner of the `dub test` row gets the program arguments, as the
// other rows give them to `main`.
@("oracleReport.dub.passesProgramArguments")
unittest {
    const directory =
        buildPath(tempDir, text("snakebite-ut-oracle-", thisProcessID));
    mkdirRecurse(buildPath(directory, "source"));
    scope(exit) directory.rmdirRecurse;
    buildPath(directory, "dub.sdl").write(
        "name \"oraclearguments\"\nconfiguration \"library\" {\n"
        ~ "    targetType \"library\"\n}\n",
    );
    buildPath(directory, "source", "arguments.d").write(
        "module arguments;\n"
        ~ "unittest {\n"
        ~ "    import core.runtime: Runtime;\n"
        ~ "    assert(Runtime.args.length == 2 && Runtime.args[1] == `x`);\n"
        ~ "}\n",
    );

    const report = oracleReport(sourceSet(directory, null, null), directory, 0, 1, ["x"]);

    report.passed.should == true;
}
