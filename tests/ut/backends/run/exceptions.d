module ut.backends.run.exceptions;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!()) {
    @("conditionalScopeExitAtFunctionEnd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int make(ref int value, bool cleanup, bool fail) {
                scope(exit) {
                    if (cleanup) value += 1;
                }
                if (fail) throw new Exception("failure");
                return 42;
            }

            void main() {
                foreach (cleanup; [false, true]) {
                    int value;
                    assert(make(value, cleanup, false) == 42);
                    assert(value == (cleanup ? 1 : 0));

                    bool caught;
                    try {
                        make(value, cleanup, true);
                    } catch (Exception exception) {
                        caught = exception.msg == "failure";
                    }
                    assert(caught);
                    assert(value == (cleanup ? 2 : 0));
                }
            }
        });
    }
}


static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// `catch (Exception)` matches a thrown native `Exception` with no guest
// subclass in its chain at all.
static foreach (backend; Matrix!()) {
    @("catchMatchesBareNativeException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                bool threw = false;

                try {
                    throw new Exception("boom");
                } catch (Exception e) {
                    threw = true;
                }

                assert(threw);
            }
        });
    }
}

// `throw` is an expression, so it can be a branch of a ternary whose other
// branch has a value.
static foreach (backend; Matrix!()) {
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


// The non-throwing arm can be first. The compiler must keep its return path
// while the other arm ends in a throw.
static foreach (backend; Matrix!()) {
    @("throwAsExpressionInTernaryFalseArm." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int choose(bool shouldThrow) {
                return shouldThrow
                    ? 9
                    : throw new Exception("false");
            }

            void main() {
                assert(choose(true) == 9);

                bool caught;
                try {
                    choose(false);
                } catch (Exception exception) {
                    caught = exception.msg == "false";
                }
                assert(caught);
            }
        });
    }
}


// When both arms throw, no path falls through the expression's caller, and
// either thrown object must still reach the enclosing catch.
static foreach (backend; Matrix!()) {
    @("bothTernaryArmsThrow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int fail(bool left) {
                return left
                    ? throw new Exception("left")
                    : throw new Exception("right");
            }

            void main() {
                bool caughtLeft;
                try {
                    fail(true);
                } catch (Exception exception) {
                    caughtLeft = exception.msg == "left";
                }
                assert(caughtLeft);

                bool caughtRight;
                try {
                    fail(false);
                } catch (Exception exception) {
                    caughtRight = exception.msg == "right";
                }
                assert(caughtRight);
            }
        });
    }
}


// A native callee (phobos, called through FFI, no guest frame in between)
// throws a native `Exception`; the guest's `catch (Exception)` matches it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call `getenv`"),
)) {
    @("catchMatchesExceptionThrownByNativeCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.process: environment;

            void main() {
                bool threw = false;
                try {
                    auto value = environment["snakebite_definitely_unset_xyz"];
                } catch (Exception e) {
                    threw = true;
                }
                assert(threw);
            }
        });
    }
}

// The same native-callee throw, caught as `Throwable`: the thrown value's
// own classinfo is the real linked `Exception` one.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call `getenv`"),
)) {
    @("nativeCalleeThrowCarriesLinkedClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.process: environment;

            void main() {
                bool threw = false;
                try {
                    auto value = environment["snakebite_definitely_unset_xyz"];
                } catch (Throwable t) {
                    threw = t.classinfo is Exception.classinfo;
                }
                assert(threw);
            }
        });
    }
}
