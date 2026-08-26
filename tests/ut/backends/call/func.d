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
