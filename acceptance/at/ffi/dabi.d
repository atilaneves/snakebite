module at.ffi.dabi;


import ut.backends;


// `bin/at` is built with ldc2, which keeps the C order for `extern(D)`
// parameters and puts the hidden return pointer before `this`; dmd, which
// builds `bin/ut`, does neither. These callees are built by ldc2, so a guest
// call to them uses ldc2's own `extern(D)` convention.
pragma(mangle, "snakebite_at_extern_d_nine_words")
private extern(D) int snakebite_at_nineWords(
    string a, string b, string c, string d, int e,
) {
    return cast(int) (a.length * 10_000 + b.length * 1000 + c.length * 100
        + d.length * 10) + e;
}


private struct Triple {
    long first;
    long second;
    long third;
}


private struct Host {
    long base;

    pragma(mangle, "snakebite_at_extern_d_method_triple")
    extern(D) Triple make(long step) {
        return Triple(base, base + step, base + 2 * step);
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("externD.parameterOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Nine ABI words spill two of the four strings to the stack, so
        // both the register order and the stack order of the parameters
        // reach the callee.
        23_415.shouldBeRetOf!(
            backend,
            q{
                struct Ffi {
                    static:
                    pragma(mangle, "snakebite_at_extern_d_nine_words")
                    extern(D) int nineWords(
                        string a, string b, string c, string d, int e,
                    );
                }

                int answer() {
                    return Ffi.nineWords("aa", "bbb", "cccc", "d", 5);
                }
            },
            "answer",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
)) {
    @("externD.methodReturningLargeAggregate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A three-word result needs a hidden return pointer next to `this`.
        11_121L.shouldBeRetOf!(
            backend,
            q{
                struct Triple {
                    long first;
                    long second;
                    long third;
                }

                struct Host {
                    long base;

                    pragma(mangle, "snakebite_at_extern_d_method_triple")
                    extern(D) Triple make(long step);
                }

                long answer() {
                    Host host;
                    host.base = 1;
                    const triple = host.make(10);
                    return triple.first * 10_000 + triple.second * 100
                        + triple.third;
                }
            },
            "answer",
        );
    }
}
