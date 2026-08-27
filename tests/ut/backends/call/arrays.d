module ut.backends.call.arrays;


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.inexpressible, "Can't do this"),
)) {
    @("compare.lessThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4.shouldBeRetOf!(
            backend,
            q{
                int incAppend() {
                    static int[] arr;
                    if(!arr)
                        arr = [0];
                    else {
                        arr ~= arr[$-1] + 1;
                    }
                    return arr[$-1];
                }
                int kindaMain() {
                    int ret;
                    foreach(i; 0 .. 5) {
                        ret = incAppend;
                    }
                    return ret;
                }
            },
            "kindaMain",
        );
    }
}
