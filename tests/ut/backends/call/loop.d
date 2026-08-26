module ut.backends.call.loop;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("loop.forRunsBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A `1` condition means the loop always runs, like `while (true)`,
        // so nothing after it is needed for `seven` to return a value.
        7L.shouldBeRetOf!(
            backend,
            q{
                long seven() {
                    for (long i = 0; 1; )
                        return 7;
                }
            },
            "seven",
        );
    }
}

// Three iterations add up to 3. A body run once, or an `i` that never
// increments, gives a different answer or no answer at all. `one` is behind
// a call so the total cannot be folded before a backend runs.
static foreach (backend; Matrix!()) {
    @("loop.forRepeatsAndTerminates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int count() {
                    int n = 0;
                    for (int i = 0; i < 3; ++i)
                        n += one();
                    return n;
                }
            },
            "count",
        );
    }
}
