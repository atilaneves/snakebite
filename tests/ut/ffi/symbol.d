module ut.ffi.symbol;


import ut;
import snakebite.ffi: Resolver;


@("resolved.once")
unittest {
    Resolver resolver;

    foreach (_; 0 .. 100)
        assert(resolver.resolve("abs") !is null);

    resolver.lookups.should == 1;
}


@("missing.resolved.once")
unittest {
    Resolver resolver;

    foreach (_; 0 .. 100)
        assert(resolver.resolve(
            "snakebite_symbol_that_does_not_exist",
        ) is null);

    resolver.lookups.should == 1;
}
