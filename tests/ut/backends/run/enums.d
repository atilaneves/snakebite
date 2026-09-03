module ut.backends.run.enums;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `with` on an enum type brings its members into scope, so they resolve
// unqualified.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed, "no WithStatement support"),
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

// An enum declared inside a function body has no run-time effect of its
// own: semantic analysis has already resolved its members to constants,
// so casting bytes to the enum type and comparing against its members
// exercises only that folding, not the declaration statement.
static foreach (backend; Matrix!()) {
    @("localEnumDeclarationIsANoOp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                enum Direction : ubyte {
                    north = 0,
                    south = 1,
                }

                ubyte[] raw = [0, 1];
                size_t index;

                Direction first = cast(Direction) raw[index++];
                Direction second = cast(Direction) raw[index++];

                assert(first == Direction.north);
                assert(second == Direction.south);
            }
        });
    }
}

