module ut.backends.call.assign;


import ut.backends;


// `2 += 5` leaves 7. The addend is behind a call so the answer cannot be
// folded before a backend runs.
static foreach (backend; Matrix!()) {
    @("assign.addAssign.local." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 2;
                    sum += five();
                    return sum;
                }
            },
            "total",
        );
    }
}

// Applied twice, so a backend that wrote the addend over the target instead
// of adding to it would disagree: the answer differs from the last addend.
static foreach (backend; Matrix!()) {
    @("assign.addAssign.accumulates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        30.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int total() {
                    int sum = 0;
                    sum += ten();
                    sum += ten();
                    sum += ten();
                    return sum;
                }
            },
            "total",
        );
    }
}

// `sum += n` evaluates to the new sum. Every other test here uses `+=` as a
// statement, where that value is discarded.
static foreach (backend; Matrix!()) {
    @("assign.addAssign.isAnExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 0;
                    return (sum += five());
                }
            },
            "total",
        );
    }
}

// A plain `=` replaces the target instead of adding to it: `+=` here would
// leave 7. The initialiser is not the answer either, so a backend that
// dropped the assignment would disagree as well.
static foreach (backend; Matrix!()) {
    @("assign.plain.overwrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 2;
                    sum = five();
                    return sum;
                }
            },
            "total",
        );
    }
}

// `sum = n` evaluates to the assigned value and leaves it in `sum`. Both
// halves are added up, so a backend that yielded the old value and one that
// never wrote `sum` each return 5 rather than 10.
static foreach (backend; Matrix!()) {
    @("assign.plain.isAnExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 0;
                    int got = (sum = five());
                    got += sum;
                    return got;
                }
            },
            "total",
        );
    }
}

// The last assignment wins. Each value differs, so a backend that added
// instead of replacing returns 60, and one that kept the first returns 10.
static foreach (backend; Matrix!()) {
    @("assign.plain.lastWins." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        30.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int twenty() {
                    return 20;
                }

                int thirty() {
                    return 30;
                }

                int total() {
                    int sum = 0;
                    sum = ten();
                    sum = twenty();
                    sum = thirty();
                    return sum;
                }
            },
            "total",
        );
    }
}
