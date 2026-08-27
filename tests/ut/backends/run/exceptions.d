module ut.backends.run.exceptions;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `throw` is an expression, so it can be a branch of a ternary whose other
// branch has a value.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("throwAsExpressionInTernary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string makeMessage(int value) {
                return value == 7 ? "expected" : "other";
            }

            int choose(int value, bool shouldThrow) {
                return shouldThrow
                    ? throw new Exception(makeMessage(value))
                    : value + 1;
            }

            void main() {
                int seed;
                int normal = choose(seed + 7, seed != 0);

                assert(normal == 8);

                int length;

                try {
                    choose(normal - 1, normal == 8);
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }

                assert(length == 8);
            }
        });
    }
}

