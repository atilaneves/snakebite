module ut.backends.call.func;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("ret.int." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    return 42;
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ret.double." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        33.3.shouldBeRetOf!(
            backend,
            q{
                double answer() {
                    return 33.3;
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("call." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.1.shouldBeRetOf!(
            backend,
            q{
                // `thrice` first: the native oracle mixes this snippet's
                // functions into a local delegate scope, and nested D
                // functions (unlike module-scope ones) do not see a sibling
                // declared later in the same scope. The guest side parses
                // this as a whole module, where declaration order does not
                // affect name resolution, so this ordering does not change
                // what is being tested.
                double thrice(double d) {
                    return d;
                }

                double func() {
                    return thrice(11.1);
                }
            },
            "func",
        );
    }
}
