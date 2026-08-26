module ut.backends.call.assign;


import ut.backends;


// `sum += n` is an `AddAssignExp`: dmd keeps compound assignment as its own
// node rather than rewriting it into `sum = sum + n`, because the left side
// must only be evaluated once. The addend is behind a call so that dmd's
// semantic pass cannot fold the whole expression to a literal.
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

// `AddAssignExp` is itself an expression, not just a statement: `sum += n`
// evaluates to the sum, the same as `sum = sum + n` would. Every other test
// here uses `+=` as a statement, so the value it writes to its own place is
// never read; `return (sum += five());` is what pins that it is.
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
