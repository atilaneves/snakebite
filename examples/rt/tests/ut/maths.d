module ut.maths;


import ut;


unittest {
    2.twice.should == 4;
}

unittest {
    3.twice.should == 6;
}

@ShouldFail
unittest {
    4.twice.should == 42;
}
