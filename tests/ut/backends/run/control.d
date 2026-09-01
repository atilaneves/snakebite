module ut.backends.run.control;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// An ordinary switch selects one case, falls through until `break`, and
// takes `default` when no case matches.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("switchDispatchesAndFallsThrough." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int matched;
                int fellThrough;

                foreach (value; [0u, 1u, 3u]) {
                    switch (value) {
                    case 0:
                        matched += 10;
                        break;
                    case 1:
                        matched += 20;
                        break;
                    default:
                        fellThrough += value;
                        break;
                    }
                }

                assert(matched == 30);
                assert(fellThrough == 3);

                switch (4) {
                case 0:
                    assert(false);
                default:
                    break;
                }
            }
        });
    }
}

// A string switch is lowered by dmd to a call to druntime's `__switch`, so
// the interpreter must route that call through the normal native boundary.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("switchOnStringUsesDruntime." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int score(string value) {
                switch (value) {
                case "red":
                    return 10;
                case "green":
                    return 20;
                default:
                    return 0;
                }
            }

            void main() {
                assert(score("red") == 10);
                assert(score("green") == 20);
                assert(score("blue") == 0);
            }
        });
    }
}


// `goto` to a label inside the same catch skips the statements between,
// so they have no effect.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
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
    BytecodeUnconfirmed,
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
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
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

// A case range and a case list each select one shared case body.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("switchSupportsCaseRangesAndLists." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int classify(int value) {
                switch (value) {
                case 0: .. case 3:
                    return 10;
                case 5, 7:
                    return 20;
                default:
                    return 30;
                }
            }

            void main() {
                assert(classify(0) == 10);
                assert(classify(3) == 10);
                assert(classify(5) == 20);
                assert(classify(7) == 20);
                assert(classify(4) == 30);
            }
        });
    }
}

// `foreach` over an `AliasSeq` unrolls into one statement per element
// at compile time, one per element's own type. Mixed element types
// with no common type rule out an ordinary array, whose single
// element type would need one shared type for all the values. Within
// each unrolled statement, `continue` skips the rest of that
// statement's own body and moves to the next element's, while `break`
// skips every remaining element's statement entirely, exactly like an
// ordinary loop body.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
                int third = helperInt(3);
                long fourth = helperLong(5);
                int fifth = helperInt(9);
                int sum, visited;

                foreach (value;
                    AliasSeq!(first, second, third, fourth, fifth)) {
                    static if (is(typeof(value) == string))
                        continue;
                    else static if (is(typeof(value) == long))
                        break;
                    else
                        sum += value;

                    ++visited;
                }

                assert(sum == 6, "sum");
                assert(visited == 2, "visited");
            }
        });
    }
}
