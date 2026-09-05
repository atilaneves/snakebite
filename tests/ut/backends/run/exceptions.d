module ut.backends.run.exceptions;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
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


// A guest class over a native class further from `Object` than
// `Throwable`, `Exception` or `Error` themselves (`RangeError`, a native
// class `core.exception` declares) must still carry that native
// grandparent's own identity in its ancestor chain, the same as one
// directly over `Exception` does: `catch` matches by walking a chain of
// real `TypeInfo_Class` objects, so collapsing the guest class's native
// base to a nearer well-known ancestor (`Error`) instead of the native
// class actually named would make a `catch` naming that native class
// silently stop matching.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("catchMatchesNativeGrandparentClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            class GuestRangeError : RangeError {
                this() {
                    super();
                }
            }

            void main() {
                int value = 1;

                try {
                    throw new GuestRangeError;
                } catch (RangeError) {
                    value = 9;
                }

                assert(value == 9);
            }
        });
    }
}


// A `catch` naming a guest class two levels up the hierarchy still matches:
// the middle guest class's own runtime type must appear in the thrown
// leaf's base chain, not be skipped in favour of jumping straight to the
// native `Exception` it eventually derives from.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("catchMatchesGuestGrandchildClassByBaseType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Root : Exception {
                this() {
                    super(null);
                }
            }

            class Leaf : Root {
                this() {
                    super();
                }
            }

            void main() {
                int value = 1;

                try {
                    throw new Leaf;
                } catch (Root) {
                    value = 9;
                } catch (Exception) {
                    value = 100;
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
        "catch matching is correct, but the guest exception's own `msg` " ~
        "field reads as garbage - a native constructor call passing " ~
        "more than six integer ABI words is unconfirmed"),
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
