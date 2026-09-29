module ut.process;


import ut;


// Every host executable links `snakebite.process`; `bin/ut` and `bin/at`
// both run this test, so both prove druntime read its options.
@("hostRuntimeOptions")
unittest {
    import core.gc.config: config;

    config.cleanup.should == "none";
}
