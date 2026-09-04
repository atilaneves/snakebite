module ut.backends.run.exceptions;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Bytecode, Because.unconfirmed,
        "the native constructor call no longer crashes, but the thrown " ~
        "class still fails to match `catch (Exception)` by base type"),
)) {
    @("catchMatchesGuestClassByBaseType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Expected : Exception {
                this() {
                    super(null);
                }
            }

            class Other : Exception {
                this() {
                    super(null);
                }
            }

            void main() {
                int value = 1;

                try {
                    throw new Expected;
                } catch (Other) {
                    value = 100;
                } catch (Exception) {
                    value = 9;
                }

                assert(value == 9);
            }
        });
    }
}


// `catch` matches a thrown class against the declared type by walking the
// base-class chain, not by exact type, so a `catch` naming a base class
// catches a derived exception while a `catch` naming a sibling class does
// not.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed,
        "DMD's native constructor ABI needs stack-word support"),
    Omit!(Bytecode, Because.unconfirmed,
        "the native constructor call no longer crashes, but the guest " ~
        "still exits with status 1 instead of 0"),
)) {
    @("catchMatchesThrownClassByBaseType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Expected : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            class Other : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            void main() {
                int value = 1;

                try {
                    throw new Expected("expected");
                } catch (Other) {
                    value = 100;
                } catch (Exception caught) {
                    value += cast(int) caught.msg.length;
                }

                assert(value == 9);
            }
        });
    }
}

// `throw` is an expression, so it can be a branch of a ternary whose other
// branch has a value.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed,
        "DMD's native constructor ABI needs stack-word support"),
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
