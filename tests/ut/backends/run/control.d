module ut.backends.run.control;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `goto` to a label inside the same catch skips the statements between,
// so they have no effect.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("gotoSkipsToLabelInCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int seed(int value) {
                return value;
            }

            void main() {
                int total;
                int entered;

                for (int i = 0; i < seed(1); ++i) {
                    try {
                        ++entered;
                        throw new Exception("expected");
                    } catch (Exception) {
                        goto resumed;

                        total += seed(99);

                    resumed:
                        break;
                    }
                }

                assert(entered == 1);
                assert(total == 0);
            }
        });
    }
}

// `goto case` and `goto default` jump to another case body and keep
// running from there, so every body on the path contributes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("gotoCaseAndDefaultFallThrough." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 1;
                int result;

                switch (value) {
                    case 1:
                        result += 10;
                        goto case 2;

                    case 2:
                        result += 20;
                        goto default;

                    default:
                        result += 30;
                        break;
                }

                assert(result == 60);
            }
        });
    }
}

// `continue` in a `do`-`while` transfers control to the trailing
// condition check, not back to the start of the body.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("continueInDoWhileJumpsToCondition." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int i;
                int sum;

                do {
                    ++i;

                    if (i == 6)
                        continue;

                    sum += i;
                } while (i < 6);

                assert(sum == 15);
            }
        });
    }
}

// `final switch` dispatches to the case matching the value at run time,
// each case running its own body rather than falling into another's.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("finalSwitchDispatchesEveryEnumMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Colour {
                red,
                green,
                blue,
            }

            Colour pick(int n) {
                return n == 0
                    ? Colour.red
                    : n == 1 ? Colour.green : Colour.blue;
            }

            int weight(Colour colour) {
                final switch (colour) {
                    case Colour.red:
                        return 10;

                    case Colour.green:
                        return 20;

                    case Colour.blue:
                        return 30;
                }
            }

            void main() {
                assert(weight(pick(0)) == 10);
                assert(weight(pick(1)) == 20);
                assert(weight(pick(2)) == 30);
            }
        });
    }
}

// `foreach` over an `AliasSeq` unrolls into one statement per element at
// compile time, one per element's own type, so `break`/`continue` inside
// it control which of those per-element statements run, exactly like an
// ordinary loop body. Mixed element types with no common type rule out
// an ordinary array, whose single element type would need one shared
// type for all three values.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("breakAndContinueInUnrolledForeach." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;

            int helperInt(int value) {
                return value + 1;
            }

            long helperLong(long value) {
                return value + 1;
            }

            void main() {
                int first = helperInt(1);
                string second = "skip";
                long third = helperLong(5);
                int sum;

                foreach (value; AliasSeq!(first, second, third)) {
                    static if (is(typeof(value) == string))
                        continue;
                    else static if (is(typeof(value) == long))
                        break;
                    else
                        sum += value;
                }

                assert(sum == 2);
            }
        });
    }
}

