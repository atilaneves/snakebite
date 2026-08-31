module ut.backends.call.compare;


import ut.backends;


// `1 < 2` is true and `2 < 1` is false. Both orderings are here so a
// comparison that always answers the same way fails one of them, and both
// operands are calls so the answer cannot be folded before a backend runs.
static foreach (backend; Matrix!()) {
    @("compare.lessThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool less() {
                    return small() < big();
                }
            },
            "less",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.lessThan.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool less() {
                    return big() < small();
                }
            },
            "less",
        );
    }
}

// `uint.max < 1u` is false. Read as two's complement the same bits are -1,
// which would make it true.
static foreach (backend; Matrix!()) {
    @("compare.lessThan.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint one() {
                    return 1u;
                }

                bool less() {
                    return top() < one();
                }
            },
            "less",
        );
    }
}

// The three orderings besides `<`. Each is pinned on both sides of its
// boundary and on the boundary itself, so an implementation that answers
// one of them with another - `<=` with `<`, say - fails the equal case.
static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notMore() {
                    return small() <= big();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool notMore() {
                    return one() <= uno();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notMore() {
                    return big() <= small();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool more() {
                    return big() > small();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterThan.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool more() {
                    return one() > uno();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterThan.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool more() {
                    return small() > big();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notLess() {
                    return big() >= small();
                }
            },
            "notLess",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool notLess() {
                    return one() >= uno();
                }
            },
            "notLess",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notLess() {
                    return small() >= big();
                }
            },
            "notLess",
        );
    }
}

// `uint.max > 1u` is true. Read as two's complement the same bits are -1,
// which would make it false.
static foreach (backend; Matrix!()) {
    @("compare.greaterThan.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint one() {
                    return 1u;
                }

                bool more() {
                    return top() > one();
                }
            },
            "more",
        );
    }
}

// `-1 >= 0` is false. Read as an unsigned bit pattern the same bits are
// `uint.max`, which would make it true.
static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -1;
                }

                int zero() {
                    return 0;
                }

                bool notLess() {
                    return negative() >= zero();
                }
            },
            "notLess",
        );
    }
}

// `uint.max <= 1u` is false. Read as two's complement the same bits are -1,
// which would make it true.
static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint one() {
                    return 1u;
                }

                bool notMore() {
                    return top() <= one();
                }
            },
            "notMore",
        );
    }
}

// `-1 < 0` is true. Read as an unsigned bit pattern the same bits are
// `uint.max`, which would make it false.
static foreach (backend; Matrix!()) {
    @("compare.lessThan.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -1;
                }

                int zero() {
                    return 0;
                }

                bool less() {
                    return negative() < zero();
                }
            },
            "less",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.equal.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool eq() {
                    return one() == uno();
                }
            },
            "eq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.equal.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                bool eq() {
                    return one() == two();
                }
            },
            "eq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.notEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                bool neq() {
                    return one() != two();
                }
            },
            "neq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.notEqual.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool neq() {
                    return one() != uno();
                }
            },
            "neq",
        );
    }
}

// Positive and negative zero have different bit patterns but compare equal.
// Calls supply every operand so the frontend cannot fold the comparisons.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("compare.floatingEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                float positiveFloatZero() {
                    return 0.0f;
                }

                float negativeFloatZero() {
                    return -0.0f;
                }

                double oneAndAHalf() {
                    return 1.5;
                }

                double twoAndAHalf() {
                    return 2.5;
                }

                bool compareFloating() {
                    return positiveFloatZero() == negativeFloatZero()
                        && oneAndAHalf() != twoAndAHalf();
                }
            },
            "compareFloating",
        );
    }
}

// Equal contents in distinct allocations prevent pointer equality from
// standing in for D's element equality. The third array differs only in its
// last element, so a length-only comparison also fails.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("compare.dynamicArrayEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                ubyte[] first() {
                    return [17, 31, 47];
                }

                ubyte[] same() {
                    return [17, 31, 47];
                }

                ubyte[] different() {
                    return [17, 31, 48];
                }

                bool compareArrays() {
                    return first() == same() && first() != different();
                }
            },
            "compareArrays",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("logical.and.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool yes() {
                    return true;
                }

                bool si() {
                    return true;
                }

                bool both() {
                    return yes() && si();
                }
            },
            "both",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.and.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                bool yes() {
                    return true;
                }

                bool no() {
                    return false;
                }

                bool both() {
                    return yes() && no();
                }
            },
            "both",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.or.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool no() {
                    return false;
                }

                bool yes() {
                    return true;
                }

                bool either() {
                    return no() || yes();
                }
            },
            "either",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.or.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                bool no() {
                    return false;
                }

                bool nein() {
                    return false;
                }

                bool either() {
                    return no() || nein();
                }
            },
            "either",
        );
    }
}

// D specifies that `&&` evaluates its right side only when the left side is
// true, so `bump` never runs here and `calls` stays at zero. An
// implementation that evaluates both sides answers one instead.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.and.shortCircuits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool no() {
                    return false;
                }

                bool bump() {
                    calls += 1;
                    return true;
                }

                int rightSideRuns() {
                    bool ignored = no() && bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}

// The other half of the pair: with the left side true the right side does
// run, so a backend that never evaluates it fails this one.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.and.evaluatesRightSide." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool yes() {
                    return true;
                }

                bool bump() {
                    calls += 1;
                    return true;
                }

                int rightSideRuns() {
                    bool ignored = yes() && bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}

// `||` evaluates its right side only when the left side is false.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.or.shortCircuits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool yes() {
                    return true;
                }

                bool bump() {
                    calls += 1;
                    return false;
                }

                int rightSideRuns() {
                    bool ignored = yes() || bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}

static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.or.evaluatesRightSide." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool no() {
                    return false;
                }

                bool bump() {
                    calls += 1;
                    return false;
                }

                int rightSideRuns() {
                    bool ignored = no() || bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}
