module ut.process;


import ut;


// Every host executable links `snakebite.process`; `bin/ut` and `bin/at`
// both run this test, so both prove druntime read its options.
@("hostRuntimeOptions")
unittest {
    import core.gc.config: config;

    config.cleanup.should == "none";
    config.gc.should == "snakebite";
    config.heapSizeFactor.should == 4;
}


// dmd's `dmd.root.rmem` defines druntime's allocation hooks in every host
// executable. A guest that resolves one by name must get druntime's own,
// as compiled D does, never dmd's copy in the host.
@("hostExportsNoAllocationHooks")
unittest {
    import core.sys.linux.dlfcn: Dl_info, RTLD_DEFAULT, dladdr, dlsym;
    import std.string: fromStringz;

    static string objectOf(const void* address) {
        Dl_info info;
        return dladdr(address, &info) == 0 ? null : info.dli_fname.fromStringz.idup;
    }

    const host = objectOf(cast(const void*) &objectOf);
    foreach (hook; ["_d_allocmemory", "_d_newclass", "_d_allocclass",
            "_d_newitemT", "_d_newitemiT"]) {
        const address = dlsym(RTLD_DEFAULT, (hook ~ '\0').ptr);
        if (address !is null)
            objectOf(address).should.not == host;
    }
}
