module ut.backends.call.aa;


import ut.backends;


static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("aa.index.static.nestedFunctionLookup." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                auto aa = ["foo": 1, "bar": 42];
                int lookup(string key) {
                    return aa[key];
                }
            },
            "lookup",
            "bar",
        );
    }
}
