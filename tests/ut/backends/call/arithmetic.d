module ut.backends.call.arithmetic;


import ut.backends;


// Every operand is a call so dmd cannot fold the arithmetic away before a
// backend ever runs it. The operands differ from each other and from the
// answer, so an implementation that returns one of them fails.
static foreach (backend; Matrix!()) {
    @("arithmetic.add." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int sum() {
                    return three() + four();
                }
            },
            "sum",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.subtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-1).shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int difference() {
                    return three() - four();
                }
            },
            "difference",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.multiply." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int product() {
                    return three() * four();
                }
            },
            "product",
        );
    }
}

// `uint` arithmetic wraps at its own width instead of answering with the
// wider value the host computed it in.
static foreach (backend; Matrix!()) {
    @("arithmetic.multiplyWrapsAtTargetWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (uint.max - 1).shouldBeRetOf!(
            backend,
            q{
                uint big() {
                    return uint.max;
                }

                uint two() {
                    return 2;
                }

                uint product() {
                    return big() * two();
                }
            },
            "product",
        );
    }
}

// Both answers of the condition are here: a ternary that always takes the
// same branch fails one of them.
static foreach (backend; Matrix!()) {
    @("arithmetic.ternary.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                bool yes() {
                    return true;
                }

                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int chosen() {
                    return yes() ? three() : four();
                }
            },
            "chosen",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.ternary.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4.shouldBeRetOf!(
            backend,
            q{
                bool no() {
                    return false;
                }

                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int chosen() {
                    return no() ? three() : four();
                }
            },
            "chosen",
        );
    }
}
