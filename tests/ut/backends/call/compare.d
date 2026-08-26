module ut.backends.call.compare;


import ut.backends;


// `a < b` is a `CmpExp`. Both operands sit behind a call because dmd folds
// an expression whose operands are all literals during semantic analysis,
// which would leave the backend with nothing to compare. The two cases
// differ in which side is larger: one alone would also pass against a
// comparison that always answered the same way.
//
// `small` and `big` come first because the native oracle mixes these
// declarations into a local delegate scope, and a nested D function does
// not see a sibling declared later in the same scope. The guest side parses
// the snippet as a whole module, where declaration order does not affect
// name resolution.
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
