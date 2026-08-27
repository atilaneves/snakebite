module ut.backends.run.enums;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `with` on an enum type brings its members into scope, so they resolve
// unqualified.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("withStatementScopesEnumMembers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Mode {
                off = 2,
                on = 5,
            }

            int selectedTotal(int seed) {
                int total = seed;

                with (Mode) {
                    total += cast(int) on;
                    total += cast(int) off;
                }

                return total;
            }

            void main() {
                assert(selectedTotal(3) == 10);
            }
        });
    }
}

