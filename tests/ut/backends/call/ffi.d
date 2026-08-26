module ut.backends.call.ffi;


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.unconfirmed,
        "needs pointers, casts, slicing and slice assignment first"),
)) {
    @("malloc.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(2).shouldBeRetOf!(
            backend,
            q{
                ubyte allocArray() {
                    import core.stdc.stdlib: malloc, free;
                    enum length = 3;
                    auto ptr = cast(ubyte*) malloc(length);
                    auto slc = ptr[0 .. length];
                    slc[] = [0, 1, 2];
                    auto ret = ptr[2];
                    free(ptr);
                    return ret;
                }
            },
            "allocArray",
        );
    }

    @("malloc.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(5).shouldBeRetOf!(
            backend,
            q{
                ubyte allocArray() {
                    import core.stdc.stdlib: malloc, free;
                    enum length = 3;
                    auto ptr = cast(ubyte*) malloc(length);
                    auto slc = ptr[0 .. length];
                    slc[] = [3, 4, 5];
                    auto ret = ptr[2];
                    free(ptr);
                    return ret;
                }
            },
            "allocArray",
        );
    }
}
