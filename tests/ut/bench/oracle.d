module ut.bench.oracle;


import bench.oracle: cyclePieces;
import core.time: Duration, msecs;
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
