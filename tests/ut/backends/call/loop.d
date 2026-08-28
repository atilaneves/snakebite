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

static foreach (backend; Matrix!()) {
    @("loop.forContinueAppliesToNearestLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        366.shouldBeRetOf!(
            backend,
            q{
                int sum() {
                    int total;
                    for (int i = 0; i < 3; ++i) {
                        for (int j = 0; j < 3; ++j) {
                            if (j == 1)
                                continue;
                            total += i * 10 + j;
                        }
                        total += 100;
                    }
                    return total;
                }
            },
            "sum",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("loop.foreachRefInitialisesArrayForNestedReads." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        20UL.shouldBeRetOf!(
            backend,
            q{
                ulong sum() {
                    auto values = new uint[](4);
                    foreach (i, ref value; values)
                        value = cast(uint) (i + 1);

                    ulong total;
                    foreach (_; 0 .. 2)
                        foreach (value; values)
                            total += value;
                    return total;
                }
            },
            "sum",
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

// `step` is declared inside the loop body, not hoisted out the way a
// `for`'s own initialiser is - so this pins a local frame slot getting
// reserved for a declaration a backend only ever reaches by walking into
// the body of a statement it already knows how to run, not by walking a
// separate, narrower list of statement kinds a local can be found in.
// 0 + 1 + 2 is 3; a `step` stuck at its first value or never added in
// would give a different answer.
static foreach (backend; Matrix!()) {
    @("loop.localInBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int sum() {
                    int total = 0;
                    for (int i = 0; i < 3; ++i) {
                        int step = i;
                        total += step;
                    }
                    return total;
                }
            },
            "sum",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("loop.commaInitialiser." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Two expressions where a `for` initialiser wants one is a comma
        // expression, the same node dmd builds when it lowers one source
        // expression into several.
        13.shouldBeRetOf!(
            backend,
            q{
                int both() {
                    int i;
                    int j;
                    for(i = 0, j = 10; i < 3; i = i + 1) {
                    }
                    return i + j;
                }
            },
            "both",
        );
    }
}
