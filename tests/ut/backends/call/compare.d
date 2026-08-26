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
