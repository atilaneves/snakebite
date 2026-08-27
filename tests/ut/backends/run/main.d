module ut.backends.run.main;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("ret.int.42." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
             backend,
             q{
                 int main() {
                     return 42;
                 }
             }
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ret.int.77." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        77.shouldBeStatusOf!(
             backend,
             q{
                 int main() {
                     return 77;
                 }
             }
        );
    }
}

// `version (D_BetterC)` is not predefined by the frontend, so a real build
// picks the `else` branch's `main`, same as `dmd -unittest` would for dub's
// generated `dub_test_root.d` (its D_BetterC branch is dead code here). This
// pins that `findFunction` resolves the condition instead of always
// descending into a version declaration's syntactic first branch.
static foreach (backend; Matrix!()) {
    @("ret.int.betterCBranchNotTaken." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
             backend,
             q{
                 version (D_BetterC) {
                     int main() {
                         return 1;
                     }
                 } else {
                     int main() {
                         return 42;
                     }
                 }
             }
        );
    }
}

// A failed assertion leaves `main` as a `Throwable` and the process fails,
// which is the contract `run` reports as a status.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("failedAssertExitsNonZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                assert(1 == 2);
            }
        });
    }
}

// No `main` at all is not an error: the status is 0.
static foreach (backend; Matrix!()) {
    @("noMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
             backend,
             q{
                 int notMain() {
                     return 42;
                 }
             }
        );
    }
}
