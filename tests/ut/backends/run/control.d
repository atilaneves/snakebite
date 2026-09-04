module ut.backends.run.control;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// An ordinary switch selects one case, falls through until `break`, and
// takes `default` when no case matches.
// `fellThrough += value;` sums an `int` with the `uint` a `foreach` over
// `[0u, 1u, 3u]` hands out. dmd's semantic pass represents that compound
// assignment's own target as `cast(uint) fellThrough` (confirmed with
// `dmd -vcg-ast`), not a bare `VarExp` - `compileCompoundAssign` unwraps
// that cast and operates at its promoted width.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// A `do` body always runs once, so a body that returns on every path
// makes the whole loop return on every path; the condition is never
// reached.
static foreach (backend; Matrix!()) {
    @("doBodyThatAlwaysReturnsEndsFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int x) {
                do {
                    return x + 1;
                } while (x > 0);
            }

            void main() {
                assert(f(1) == 2);
            }
        });
    }
}

// A plain `break` inside a `for` loop leaves the loop, running nothing
// after it in the same iteration and none of the loop's own remaining
// iterations.
static foreach (backend; Matrix!()) {
    @("breakExitsForLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int sum;

                for (int i; i < 10; ++i) {
                    if (i == 5)
                        break;

                    sum += i;
                }

                assert(sum == 10);
            }
        });
    }
}

// A labelled `break` leaves the loop its label names, not just the
// innermost one it is written inside.
static foreach (backend; Matrix!()) {
    @("labelledBreakExitsOuterLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int count;

                outer:
                for (int i; i < 2; ++i) {
                    for (int j; j < 2; ++j) {
                        ++count;
                        if (i == 0 && j == 1)
                            break outer;
                    }
                }

                assert(count == 2);
            }
        });
    }
}

// A labelled `continue` moves the loop its label names to its next
// iteration, skipping the rest of every loop nested inside it too.
static foreach (backend; Matrix!()) {
    @("labelledContinueRepeatsOuterLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int count;

                outer:
                for (int i; i < 3; ++i) {
                    for (int j; j < 4; ++j) {
                        if (j == i + 1)
                            continue outer;

                        ++count;
                    }
                }

                assert(count == 6);
            }
        });
    }
}

// `continue` in an unrolled `foreach` ends the current element's
// statement, so an `else` paired with the `if` that continued must not
// run for that element.
static foreach (backend; Matrix!()) {
    @("continueInUnrolledForeachSkipsElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;

            void main() {
                int sum;

                foreach (value; AliasSeq!(1, 2, 3)) {
                    if (value == 2)
                        continue;
                    else
                        sum += value;
                }

                assert(sum == 4);
            }
        });
    }
}

// `continue` in a `case` of a `switch` inside an unrolled `foreach`
// leaves the whole `switch` for the current element; it must not fall
// through into the next case.
static foreach (backend; Matrix!()) {
    @("continueInSwitchInUnrolledForeachLeavesSwitch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;

            void main() {
                int sum;

                foreach (value; AliasSeq!(1, 2)) {
                    switch (value) {
                    case 1:
                        continue;
                    default:
                        sum += 10;
                    }
                }

                assert(sum == 10);
            }
        });
    }
}

// `continue` in a `try` body inside an unrolled `foreach` leaves the
// `try` normally; no exception was thrown, so no `catch` handler runs.
static foreach (backend; Matrix!()) {
    @("continueInTryInUnrolledForeachSkipsCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;

            void main() {
                int sum;

                foreach (value; AliasSeq!(1, 2)) {
                    try {
                        sum += value;
                        continue;
                    } catch (Exception) {
                        sum += 100;
                    }
                }

                assert(sum == 3);
            }
        });
    }
}

// `continue` as the last statement of an unrolled `foreach` body only
// ends the current element; the statement after the loop still runs.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "returns the wrong value after a trailing continue"),
)) {
    @("continueAtEndOfUnrolledForeachFallsOut." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;

            int total() {
                int sum;

                foreach (value; AliasSeq!(1, 2)) {
                    sum += value;
                    continue;
                }

                return sum;
            }

            void main() {
                assert(total == 3);
            }
        });
    }
}

// A label names the loop it is written on, not the first breakable
// construct compiled inside it - here a `switch` in the `for` init.
static foreach (backend; Matrix!()) {
    @("labelledBreakIgnoresSwitchInForInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int count;
                int i;

                outer:
                for ({ switch (i) { default: break; } } i < 2; ++i) {
                    for (int j; j < 2; ++j) {
                        ++count;
                        if (i == 0 && j == 1)
                            break outer;
                    }
                }

                assert(count == 2);
            }
        });
    }
}

// `final switch` dispatches to the case matching the value at run time,
// each case running its own body rather than falling into another's.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
