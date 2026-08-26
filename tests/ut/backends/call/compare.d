module ut.backends.call.compare;


import ut.backends;


// `a < b` is a `CmpExp`. Both operands are calls because dmd folds a
// literal-only expression during semantic analysis, leaving nothing for
// the backend to compare. Both orderings are tested so a comparison that
// always answers the same way still fails one of the two cases.
//
// `small` and `big` are declared before use because the native oracle
// nests them in a local delegate scope, where a sibling declared later
// is not visible.
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

// A signed comparison reads the operands' bit pattern as two's complement,
// so `uint.max` (all bits set) would come out less than `1u` if read that
// way. The interpreter's `CmpExp` branches on `expression.e1.type.isUnsigned`
// specifically to avoid that; this pins the unsigned reading as the correct
// one.
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

// `<=`, `>` and `>=` arrive at the interpreter as the same `CmpExp` node as
// `<`, distinguished only by `expression.op`. It refuses every one of them
// deliberately: nothing needs them yet, and answering with `<`'s own logic
// would be a silently wrong answer rather than a refusal. Native and Ctfe
// both answer these fine, so the refusal is pinned as an Interpreter-only
// divergence, the same way arithmetic.d pins Ctfe's float-precision one.
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
        .shouldThrowWithMessage(
            "interpreter cannot evaluate a `lessOrEqual` expression: "
            ~ "`small() <= big()`");
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
        .shouldThrowWithMessage(
            "interpreter cannot evaluate a `greaterThan` expression: "
            ~ "`big() > small()`");
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
        .shouldThrowWithMessage(
            "interpreter cannot evaluate a `greaterOrEqual` expression: "
            ~ "`big() >= small()`");
}
