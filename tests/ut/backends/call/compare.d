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

// The interpreter answers `<` and refuses the other three comparisons, so
// that a missing one is a refusal rather than a wrong answer. Compiled D
// answers them all, which is why this is pinned for the interpreter alone.
@("compare.lessOrEqual.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int small() { return 1; }
        int big() { return 2; }
        bool notMore() { return small() <= big(); }
    });
    auto function_ = findFunction(module_, "notMore");

    bool result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}

@("compare.greaterThan.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int small() { return 1; }
        int big() { return 2; }
        bool more() { return big() > small(); }
    });
    auto function_ = findFunction(module_, "more");

    bool result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}

@("compare.greaterOrEqual.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int small() { return 1; }
        int big() { return 2; }
        bool notLess() { return big() >= small(); }
    });
    auto function_ = findFunction(module_, "notLess");

    bool result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}
