module ut.backends.call.comma;


import ut.backends;


// D rejects a comma expression whose result is used, so the only way to
// write one in source is as a statement, with the result discarded. Both
// sides are added into the answer so that a backend running only one of
// them disagrees.
static foreach (backend; Matrix!()) {
    @("comma.bothSidesRun." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        212.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int a = 1;
                    int b = 2;
                    a += 1, b += 10;
                    return a * 100 + b;
                }
            },
            "result",
        );
    }
}
