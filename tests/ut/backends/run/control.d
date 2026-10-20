module ut.backends.run.control;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("assertZeroThrowsAssertError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            int main() {
                try {
                    assert(0, "Oh noes");
                } catch (AssertError error) {
                    return error.msg == "Oh noes" ? 0 : 1;
                }
                return 2;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticForeachSwitchCases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Visibility { public_, private_, protected_, export_, package_ }
            Visibility visibility(string name) {
                switch (name) with (Visibility) {
                default: throw new Exception("unknown");
                case "direct": return public_;
                static foreach (item; ["public", "private", "protected", "export", "package"]) {
                    case item: return mixin(item ~ "_");
                }
                }
            }
            void main() {
                assert(visibility("direct") == Visibility.public_);
                assert(visibility("export") == Visibility.export_);
                assert(visibility("private") == Visibility.private_);
                try { visibility("unknown"); assert(false); }
                catch (Exception) {}
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("stringSwitchInsideForeach." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.traits: PSC = ParameterStorageClass;
            auto flags(in string[] names) @safe pure nothrow {
                auto result = PSC.none;
                foreach (name; names) {
                    final switch (name) with(PSC) {
                    case "in": result |= in_; break;
                    case "out": result |= out_; break;
                    case "ref": result |= ref_; break;
                    case "lazy": result |= lazy_; break;
                    case "scope": result |= scope_; break;
                    case "return": result |= return_; break;
                    }
                }
                return result;
            }
            void main() {
                assert(flags(["return", "scope"]) == (PSC.return_ | PSC.scope_));
                assert(flags(["in", "out", "ref", "lazy"]) ==
                    (PSC.in_ | PSC.out_ | PSC.ref_ | PSC.lazy_));
            }
        });
    }
}


// A discarded __ctfe conditional can assign a nested field of `this`, with a
// call in its alternate branch. This is the shape used by std.sumtype.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE selects the compile-time conditional branch"),
)) {
    @("discardedConditionalAssignmentRunsSelectedBranch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Storage { int value; }
            struct Holder {
                Storage storage;

                this(int value) {
                    __ctfe
                        ? (this.storage.value = value)
                        : (this.storage.value = fallback());
                }

                int fallback() { return 2; }
            }

            void main() {
                auto holder = Holder(1);
                assert(holder.storage.value == 2);
            }
        });
    }
}


// Reading `__ctfe` at run time is not a frontend error. The variable has no
// parent symbol, so asking dmd whether it is static data reports
// "forward referenced" through the global diagnostic list, which another
// thread's frontend call then throws as its own.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE selects the compile-time conditional branch"),
)) {
    @("readingCtfeVariableAtRunTimeReportsNoDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import dmd.errors: diagnostics;
        import std.algorithm: canFind;

        diagnostics = null;
        2.shouldBeRetOf!(backend, q{
            int readsCtfeVariable() {
                bool compileTime = __ctfe;
                return compileTime ? 1 : 2;
            }
        }, "readsCtfeVariable");

        foreach (diagnostic; diagnostics)
            diagnostic.message.canFind("__ctfe").should == false;
    }
}


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

// A case expression can read a function parameter. Evaluate it for each
// switch execution, just like the condition expression.
static foreach (backend; Matrix!()) {
    @("switchEvaluatesDynamicCaseValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int select(int value, const int caseValue) {
                switch (value) {
                case caseValue:
                    return 1;
                default:
                    return 2;
                }
            }

            void main() {
                assert(select(7, 7) == 1);
                assert(select(7, 8) == 2);
                assert(select(8, 8) == 1);
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
static foreach (backend; Matrix!()) {
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

// A `final switch` on a value that is no member of the enum throws a
// `SwitchError`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE cannot interpret a SwitchErrorStatement"),
)) {
    @("finalSwitchOnNonMemberThrowsSwitchError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: SwitchError;

            enum Colour {
                red,
                green,
            }

            int weight(Colour colour) {
                final switch (colour) {
                    case Colour.red:
                        return 10;

                    case Colour.green:
                        return 20;
                }
            }

            int main() {
                try {
                    return weight(cast(Colour) 7);
                } catch (SwitchError) {
                    return 0;
                }
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

// A `return` in a non-last element of an unrolled `foreach` ends every
// path: the remaining elements are dead code, so the function does return
// on every path. `pick!"bar"` matches the last element, so it already
// compiled before this rule existed; it stays here to check that skipping
// dead elements never skips a live last element too.
static foreach (backend; Matrix!()) {
    @("returnInNonLastUnrolledForeachElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;
            int pick(string name)() {
                foreach (candidate; AliasSeq!("foo", "bar")) {
                    static if (candidate == name)
                        return cast(int) candidate.length + 10;
                }
            }
            void main() { assert(pick!"foo" == 13); assert(pick!"bar" == 13); }
        });
    }
}

// A `case` label in a later element of an unrolled `foreach` is still a
// live target: the enclosing `switch`'s own dispatch code can jump to it
// directly, skipping every earlier element. An earlier element that
// returns on every path must not hide it. `std.conv.toImpl` for enums
// has this exact shape: a `switch` whose cases come from a `foreach`
// over the enum's members.
static foreach (backend; Matrix!()) {
    @("caseInUnrolledForeachElementAfterReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;
            string name(int v) {
                switch (v) {
                    foreach (m; AliasSeq!(0, 1)) {
                        case m: return m == 0 ? "zero" : "one";
                    }
                    default:
                }
                return "other";
            }
            void main() {
                assert(name(0) == "zero");
                assert(name(1) == "one");
                assert(name(2) == "other");
            }
        });
    }
}

// As above, but the earlier element ends every path with a `break`
// instead of a `return`: the same reachability rule applies regardless
// of which statement ends the element's paths. The `break` names the
// `switch`'s own label: an unlabelled `break` inside the `foreach`
// targets the `foreach` itself (the nearest enclosing loop), not the
// `switch`, since the loop is still the lexically enclosing breakable
// construct even though dmd unrolls it away at compile time.
static foreach (backend; Matrix!()) {
    @("caseInUnrolledForeachElementAfterBreak." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;
            string name(int v) {
                string r;
                sw: switch (v) {
                    foreach (m; AliasSeq!(0, 1)) {
                        case m: r = m == 0 ? "zero" : "one"; break sw;
                    }
                    default: r = "other"; break sw;
                }
                return r;
            }
            void main() {
                assert(name(0) == "zero");
                assert(name(1) == "one");
                assert(name(2) == "other");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoForward." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() { int x; goto done; x = 9; done: return x + 1; }
            void main() { assert(run() == 1); }
        });
    }
}

// A label after a `return` that ends every earlier path is still a live
// target: a `goto` from outside can land on it, the same as a `case` from
// an enclosing `switch` can land inside a later element of an unrolled
// `foreach`. The block rule (`compileStatements`) must keep this label
// live for the same reason the unrolled `foreach` rule does.
static foreach (backend; Matrix!()) {
    @("gotoPastEarlyReturnToLaterLabel." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int v) {
                if (v == 0) goto skip;
                return 2;
                skip: return 3;
            }
            void main() { assert(f(0) == 3); assert(f(1) == 2); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoBackward." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() { int x; again: ++x; if (x < 3) goto again; return x; }
            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() { int x; try { goto done; } finally { x = 3; } done: return x; }
            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoOutOfSwitch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() { int x; switch (x) { case 0: goto done; default: break; } x = 9; done: return x + 1; }
            void main() { assert(run() == 1); }
        });
    }
}

// A `goto` may target a label in a different `case` of the same `switch`.
static foreach (backend; Matrix!()) {
    @("gotoLabelInOtherSwitchCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                switch (value) {
                    case 1:
                        goto tail;
                    case 2:
                        result += 20;
                        break;
                    case 3:
                    tail:
                        result += 5;
                        break;
                    default:
                        break;
                }
                return result;
            }
            int main() {
                return inner(1) == 5 ? 0 : 1;
            }
        });
    }
}

// A `goto` may jump back to a label in an earlier `case`.
static foreach (backend; Matrix!()) {
    @("gotoBackwardBetweenSwitchCases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                int visits;
                switch (value) {
                    case 1:
                    again:
                        ++visits;
                        result += 1;
                        break;
                    case 2:
                        if (visits < 3)
                            goto again;
                        break;
                    default:
                        break;
                }
                return result * 10 + visits;
            }
            int main() {
                return inner(2) == 11 ? 0 : 1;
            }
        });
    }
}

// A `goto` to a label in a later `case` runs the rest of that case and stops at its `break`.
static foreach (backend; Matrix!()) {
    @("gotoForwardBetweenSwitchCasesAfterLabelRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                switch (value) {
                    case 1:
                        result += 1;
                        goto tail;
                    case 2:
                        result += 100;
                    tail:
                        result += 10;
                        break;
                    case 3:
                        result += 1000;
                        break;
                    default:
                        result += 10000;
                        break;
                }
                return result;
            }
            int main() {
                return inner(1) == 11 ? 0 : 1;
            }
        });
    }
}

// A `goto` may target a label in a nested block of a different `case`.
static foreach (backend; Matrix!()) {
    @("gotoIntoNestedBlockOfOtherSwitchCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                switch (value) {
                    case 1:
                        goto deep;
                    case 2:
                        {
                            result += 20;
                            if (value == 2) {
                            deep:
                                result += 5;
                            }
                            result += 1;
                        }
                        break;
                    default:
                        break;
                }
                return result;
            }
            int main() {
                return inner(1) == 6 ? 0 : 1;
            }
        });
    }
}

// A `goto` from `default` may target a label in a `case`.
static foreach (backend; Matrix!()) {
    @("gotoFromDefaultToLabelInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                switch (value) {
                    case 1:
                    tail:
                        result += 5;
                        break;
                    default:
                        goto tail;
                }
                return result;
            }
            int main() {
                return inner(9) == 5 ? 0 : 1;
            }
        });
    }
}

// A `goto` from a `case` may target a label in `default`.
static foreach (backend; Matrix!()) {
    @("gotoFromCaseToLabelInDefault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                switch (value) {
                    case 1:
                        goto tail;
                    default:
                    tail:
                        result += 7;
                        break;
                }
                return result;
            }
            int main() {
                return inner(1) == 7 ? 0 : 1;
            }
        });
    }
}

// A `goto` out of a nested `switch` may target a label in a `case` of the outer `switch`.
static foreach (backend; Matrix!()) {
    @("gotoFromNestedSwitchToLabelInOuterCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int outer, int nested) {
                int result;
                switch (outer) {
                    case 1:
                        switch (nested) {
                            case 1:
                                goto tail;
                            default:
                                result += 100;
                                break;
                        }
                        result += 1000;
                        break;
                    case 2:
                    tail:
                        result += 5;
                        break;
                    default:
                        break;
                }
                return result;
            }
            int main() {
                return inner(1, 1) == 5 ? 0 : 1;
            }
        });
    }
}

// A `goto` in a loop body may target a label in a `case` of a `switch` in the same loop.
static foreach (backend; Matrix!()) {
    @("gotoToLabelInSwitchCaseInsideLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner() {
                int result;
                foreach (i; 0 .. 3) {
                    switch (i) {
                        case 0:
                            goto tail;
                        case 1:
                            result += 100;
                            break;
                        case 2:
                        tail:
                            result += 5;
                            break;
                        default:
                            break;
                    }
                }
                return result;
            }
            int main() {
                return inner() == 110 ? 0 : 1;
            }
        });
    }
}

// A `goto` may target a label in another `case` of a `final switch`.
static foreach (backend; Matrix!()) {
    @("gotoToLabelInFinalSwitchCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Colour { red, green, blue }
            int inner(Colour colour) {
                int result;
                final switch (colour) {
                    case Colour.red:
                        goto tail;
                    case Colour.green:
                        result += 20;
                        break;
                    case Colour.blue:
                    tail:
                        result += 5;
                        break;
                }
                return result;
            }
            int main() {
                return inner(Colour.red) == 5 ? 0 : 1;
            }
        });
    }
}

// A `break` after a `goto` from outside a `switch` to a label in a `case` leaves only the `switch`.
static foreach (backend; Matrix!()) {
    @("gotoIntoSwitchCaseThenBreakInLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner() {
                int result;
                foreach (i; 0 .. 3) {
                    if (i == 1)
                        goto inside;
                    switch (i) {
                        case 0:
                            result += 1;
                            break;
                        case 5:
                        inside:
                            result += 10;
                            break;
                        default:
                            result += 100;
                            break;
                    }
                    result += 1000;
                }
                return result;
            }
            int main() {
                return inner() == 3111 ? 0 : 1;
            }
        });
    }
}

// A `goto case` after a `goto` from outside a `switch` to a label in a `case` selects a `case` of that `switch`.
static foreach (backend; Matrix!()) {
    @("gotoIntoSwitchCaseThenGotoCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int value) {
                int result;
                if (value == 7)
                    goto inside;
                switch (value) {
                    case 1:
                        result += 1;
                        break;
                    case 2:
                    inside:
                        result += 10;
                        goto case 1;
                    default:
                        result += 100;
                        break;
                }
                return result;
            }
            int main() {
                return inner(7) == 11 ? 0 : 1;
            }
        });
    }
}

// A `goto` in a `case` of an outer `switch` may target a label in a `case` of a nested `switch`.
static foreach (backend; Matrix!()) {
    @("gotoFromOuterSwitchToLabelInNestedCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(int outer, int nested) {
                int result;
                switch (outer) {
                    case 1:
                        goto deep;
                    case 2:
                        switch (nested) {
                            case 1:
                                result += 100;
                                break;
                            case 2:
                            deep:
                                result += 5;
                                break;
                            default:
                                result += 1000;
                                break;
                        }
                        result += 10;
                        break;
                    default:
                        break;
                }
                return result;
            }
            int main() {
                return inner(1, 1) == 15 && inner(2, 1) == 110 ? 0 : 1;
            }
        });
    }
}

// A `goto` to a label in another `case` runs the destructor of a local that it leaves.
static foreach (backend; Matrix!()) {
    @("gotoBetweenSwitchCasesRunsDestructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counted {
                int* count;
                ~this() { ++*count; }
            }
            int inner(int value) {
                int count;
                int result;
                switch (value) {
                    case 1: {
                        auto counted = Counted(&count);
                        goto tail;
                    }
                    case 2:
                    tail:
                        result += 5 + count * 100;
                        break;
                    default:
                        break;
                }
                return result * 10 + count;
            }
            int main() {
                return inner(1) == 1051 ? 0 : 1;
            }
        });
    }
}

// A `goto` may leave a `final switch` for a label after it.
static foreach (backend; Matrix!()) {
    @("gotoOutOfFinalSwitch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Colour { red, green, blue }
            int inner(Colour colour) {
                int result;
                final switch (colour) {
                    case Colour.red:
                        goto done;
                    case Colour.green:
                        result += 20;
                        break;
                    case Colour.blue:
                        result += 5;
                        break;
                }
                result += 100;
            done:
                return result;
            }
            int main() {
                return inner(Colour.red) == 0 && inner(Colour.green) == 120
                    ? 0 : 1;
            }
        });
    }
}

// A `goto` may jump over a `final switch` that it is not in.
static foreach (backend; Matrix!()) {
    @("gotoOverFinalSwitch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Colour { red, green, blue }
            int inner(Colour colour, bool skip) {
                int result;
                if (skip)
                    goto done;
                final switch (colour) {
                    case Colour.red:
                        result += 1;
                        break;
                    case Colour.green:
                        result += 20;
                        break;
                    case Colour.blue:
                        result += 5;
                        break;
                }
            done:
                return result;
            }
            int main() {
                return inner(Colour.red, true) == 0
                    && inner(Colour.green, false) == 20 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoInsideFinallyScope." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int x;
                try {
                    goto inside;
                inside:
                    x = 2;
                }
                finally {
                    x += 1;
                }
                return x;
            }

            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoCaseKeepsFinallyPending." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int x;
                try {
                    switch (x) {
                    case 0:
                        goto case 1;
                    case 1:
                        x = 3;
                        break;
                    default:
                        break;
                    }
                }
                finally {
                    x += 1;
                }
                return x;
            }

            void main() { assert(run() == 4); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoLeavesNestedFinallyScopes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int x;
                try {
                    try {
                        goto done;
                    }
                    finally {
                        x += 1;
                    }
                }
                finally {
                    x += 2;
                }
            done:
                return x;
            }

            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoCaseLeavesFinallyScope." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int x;
                switch (0) {
                case 0:
                    try {
                        goto case 1;
                    }
                    finally {
                        x += 1;
                    }
                case 1:
                    x += 2;
                    break;
                default:
                    break;
                }
                return x;
            }

            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoDefaultLeavesFinallyScope." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int x;
                switch (0) {
                case 0:
                    try {
                        goto default;
                    }
                    finally {
                        x += 1;
                    }
                default:
                    x += 2;
                    break;
                }
                return x;
            }

            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoLoopResumesFor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int hits;
                for (int i; i < 3; ++i) {
                    if (i == 0)
                        goto inside;
                inside:
                    ++hits;
                }
                return hits;
            }

            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("reviewGotoLoopResumesDo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int hits;
                int i;
                do {
                    if (i == 0)
                        goto inside;
                inside:
                    ++hits;
                    ++i;
                } while (i < 3);
                return hits;
            }

            void main() { assert(run() == 3); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot catch a runtime exception"),
)) {
    @("reviewGotoResumesTryCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                try {
                    goto inside;
                inside:
                    throw new Exception("caught");
                }
                catch (Exception) {
                    return 1;
                }
                return 0;
            }

            void main() { assert(run() == 1); }
        });
    }
}

// `static foreach` at statement scope - unlike a runtime `foreach` over a
// tuple - flattens its elements directly into the enclosing block instead
// of keeping its own `UnrolledLoopStatement`: a `static if` with no
// `else` that resolves false leaves a `null` entry in the block's own
// statement list, not an empty one. `reachable` must not call `comeFrom`
// on that `null` entry; the shape below is unit-threaded's own
// `mockStruct.opDispatch`, the function commit 99ebb75f's own fix was
// written for.
static foreach (backend; Matrix!()) {
    @("staticForeachElidedBranchLeavesNullStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;
            struct Mock {
                auto opDispatch(string funcName)() {
                    static foreach (name; AliasSeq!("length", "greet", "list")) {
                        static if (name == funcName) {
                            return name;
                        }
                    }
                    assert(0);
                }
            }
            void main() {
                Mock m;
                assert(m.opDispatch!"length" == "length");
                assert(m.opDispatch!"greet" == "greet");
                assert(m.opDispatch!"list" == "list");
            }
        });
    }
}

// A condition of type `noreturn` runs, and its throw leaves the `if`.
static foreach (backend; Matrix!()) {
    @("noreturnConditionRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            noreturn fail() { throw new Exception("stop"); }

            int main() {
                try {
                    if (fail())
                        return 1;
                    return 2;
                } catch (Exception exception)
                    return exception.msg == "stop" ? 0 : 3;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("functionEndAfterBackwardGotoAfterIfReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int x) { lbl: x++; if (x > 3) return x; goto lbl; }
            void main() { assert(f(0) == 4); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("functionEndAfterGotoThenIfReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int x) { lbl: if (x > 3) return x; x++; goto lbl; }
            void main() { assert(f(0) == 4); }
        });
    }
}

// dmd's block-exit analysis reads a constant-true condition as "the
// `if` body always runs", so it accepts this function with no `return`
// after the `if`.
static foreach (backend; Matrix!()) {
    @("functionEndAfterConstantTrueIfReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int x) { if (true) return x; }
            void main() { assert(f(5) == 5); }
        });
    }
}

// A call to a `noreturn` function ends the path for dmd's block-exit
// analysis, so no `return` is necessary after it.
static foreach (backend; Matrix!()) {
    @("functionEndAfterNoreturnCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            noreturn die() { throw new Exception("no"); }
            int f(int x) { if (x > 3) return x; die(); }
            void main() { assert(f(5) == 5); }
        });
    }
}


// A `case` label in an `if (__ctfe)` block is a run-time jump target: the
// `switch` enters the block at the label, although the `if` itself never
// does at run time. dmd rejects only a `goto` into the block.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on a `case` in an "
            ~ "`if (__ctfe)` block; ldc compiles it and the program "
            ~ "exits with status 0"),
    Omit!(Ctfe, Because.inexpressible, "`__ctfe` is true in CTFE"),
)) {
    @("caseLabelInCtfeBlockIsARuntimeTarget." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int pick(int value) {
                switch (value) {
                    case 0:
                        return 10;
                    default:
                        if (__ctfe) {
                            case 1:
                                int[2] values = [5, 6];
                                int[2] copy = values;
                                int[] slice = copy[];
                                auto words = cast(uint[]) slice;
                                auto bytes = cast(ubyte[]) slice;
                                slice.length = 0;
                                assert(words.length == 2 && bytes.length == 8);
                                assert(slice.length == 0 && copy[1] == 6);
                                return 11;
                        }
                        return 12;
                }
            }

            void main() {
                assert(pick(0) == 10);
                assert(pick(1) == 11);
                assert(pick(5) == 12);
            }
        });
    }
}


// The same for a `default` label: a value that matches no `case` enters
// the `if (__ctfe)` block at the label.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator makes a program that never ends "
            ~ "for a `default` in an `if (__ctfe)` block; ldc compiles it "
            ~ "and the program exits with status 0"),
    Omit!(Ctfe, Because.inexpressible, "`__ctfe` is true in CTFE"),
)) {
    @("defaultLabelInCtfeBlockIsARuntimeTarget." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int pick(int value) {
                switch (value) {
                    case 0:
                        return 10;
                    case 1:
                        if (__ctfe) {
                            default:
                                return 11;
                        }
                        return 12;
                }
            }

            void main() {
                assert(pick(0) == 10);
                assert(pick(1) == 12);
                assert(pick(7) == 11);
            }
        });
    }
}


// The parser gives a `catch` a statement without a scope, and dmd's
// semantic analysis of a `catch` does not rewrite a scope guard that is the
// whole handler. dmd's glue layer generates no code for that guard.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a scope guard"
            ~ " that semantic analysis did not rewrite"),
)) {
    @("scopeGuardAsCatchHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int count;
            void bump() { count++; }
            int main() {
                try
                    throw new Exception("");
                catch (Exception)
                    scope(exit) bump();
                return count;
            }
        });
    }
}


// dmd does not lower an append in an `if (__ctfe)` block. A `case` label
// in the block makes the statements after the label a run-time target, but
// the append before the label stays dead code at run time.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0 and ldc 1.43.0 fail with an internal error on an "
            ~ "append in an `if (__ctfe)` block that has a `case` label"),
    Omit!(Ctfe, Because.inexpressible, "`__ctfe` is true in CTFE"),
)) {
    @("deadAppendBeforeCaseLabelInCtfeBlock." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int pick(int value) {
                int[] array;
                int result;
                switch (value) {
                    case 0:
                        if (__ctfe) {
                            array ~= 7;
                            case 1:
                                result = 5;
                        }
                        break;
                    default:
                }
                return result + cast(int) array.length;
            }

            int main() {
                return pick(1) == 5 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `if` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsIfBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                if (count == 0) scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `else` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsElseBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                if (count == 1) {} else scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `for` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsForBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                for (int i = 0; i < 1; i++) scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `while` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsWhileBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                int i;
                while (i++ < 1) scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `do` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsDoBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                int i;
                do scope(exit) bump(); while (i++ < 0);
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `foreach` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsForeachBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                foreach (i; 0 .. 1) scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `with` body, not in a compound or scope statement.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a scope guard"
            ~ " that semantic analysis did not rewrite"),
)) {
    @("scopeGuardAsWithBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                S s;
                with (s) scope(exit) bump();
                return count == 0 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `synchronized` body, not in a compound or scope statement.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine cannot call `_d_monitorenter`"),
)) {
    @("scopeGuardAsSynchronizedBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                auto object = new Object;
                synchronized (object) scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the last statement of a `case`, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsCaseBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                switch (1) {
                    case 1: scope(exit) bump(); break;
                    default:
                }
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the last statement of a `default`, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsDefaultBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                switch (2) {
                    case 1: break;
                    default: scope(exit) bump();
                }
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the statement of a label, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsLabelledStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                L: scope(exit) bump();
                return count == 0 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `try` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsTryBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                try scope(exit) bump(); catch (Exception) {}
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `finally` body, not in a compound or scope statement.
static foreach (backend; Matrix!()) {
    @("scopeGuardAsFinallyBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                try {} finally scope(exit) bump();
                return count == 1 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `catch` handler, not in a compound or scope statement.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a scope guard"
            ~ " that semantic analysis did not rewrite"),
)) {
    @("scopeGuardAsSuccessCatchHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                try
                    throw new Exception("");
                catch (Exception)
                    scope(success) bump();
                return count == 0 ? 0 : 1;
            }
        });
    }
}


// A scope guard that is the whole `catch` handler, not in a compound or scope statement.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a scope guard"
            ~ " that semantic analysis did not rewrite"),
)) {
    @("scopeGuardAsFailureCatchHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; }
            int main() {
                int count;
                void bump() { count++; }
                try {
                    try
                        throw new Exception("");
                    catch (Exception)
                        scope(failure) bump();
                } catch (Exception) {}
                return count == 0 ? 0 : 1;
            }
        });
    }
}


// dmd runs `scope(success)` only when the body leaves normally. A throw
// from the operand of `return` leaves the body abnormally, so the guard
// must not run and the throw must reach the caller, whatever the call
// modifies before it throws.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnOfThrowingCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int inner(ref string s) {
                if (s.length == 0 || s[0] == 'b')
                    throw new Exception("inner");
                s = s[1 .. $];
                return 5;
            }

            int outer(string value) {
                scope(success) {
                    if (value.length != 0)
                        throw new Exception("rest");
                }
                return inner(value);
            }

            int t(string s) {
                try
                    return outer(s);
                catch (Exception)
                    return -999;
            }

            int main() {
                return t("7") == 5 && t("b") == -999
                    && t("") == -999 && t("1x") == -999 ? 0 : 1;
            }
        });
    }
}


// Each branch of an `if`/`else` that returns leaves the guard's scope
// by its own `return`.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int fine() {
                    log ~= "fine,";
                    return 3;
                }
                int f(int mode) {
                    scope(success) log ~= "S,";
                    if (mode == 0)
                        return boom();
                    else if (mode == 1)
                        return fine();
                    else
                        return 9;
                }
                int g(int mode) {
                    try
                        return f(mode);
                    catch (Exception)
                        return -1;
                }

                if (g(0) != -1 || g(1) != 3 || g(2) != 9)
                    return 2;
                return log == "boom,fine,S,S," ? 0 : 1;
            }
        });
    }
}


// A `return` in a `case` leaves the scope that holds the `switch`.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnInSwitchCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int fine() {
                    log ~= "fine,";
                    return 3;
                }
                int f(int mode) {
                    scope(success) log ~= "S,";
                    switch (mode) {
                        case 0:
                            return boom();
                        case 1:
                            return fine();
                        default:
                            return 9;
                    }
                }
                int g(int mode) {
                    try
                        return f(mode);
                    catch (Exception)
                        return -1;
                }

                if (g(0) != -1 || g(1) != 3 || g(2) != 9)
                    return 2;
                return log == "boom,fine,S,S," ? 0 : 1;
            }
        });
    }
}


// `break` and `continue` leave the guard of the loop body normally. A
// `return` of a throwing call in the same body leaves it abnormally.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnInLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f(int stop) {
                    for (int i = 0; i < 5; i++) {
                        scope(success) log ~= "S,";
                        if (i == 0)
                            continue;
                        if (i == 1)
                            break;
                    }
                    for (int i = 0; i < 5; i++) {
                        scope(success) log ~= "T,";
                        if (i == stop)
                            return boom();
                    }
                    return 0;
                }
                int g(int stop) {
                    try
                        return f(stop);
                    catch (Exception)
                        return -1;
                }

                if (g(1) != -1)
                    return 2;
                return log == "S,S,T,boom," ? 0 : 1;
            }
        });
    }
}


// A `catch` that does not match lets the throw pass the guard that is
// outside of the `try`. A `catch` that matches turns the `return` into a
// normal exit of the guard's scope.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnInTryCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f(bool matching) {
                    scope(success) log ~= "S,";
                    try {
                        return boom();
                    } catch (Error) {
                        return 1;
                    } catch (Exception) {
                        if (matching)
                            return 4;
                        throw new Exception("again");
                    }
                }
                int g(bool matching) {
                    try
                        return f(matching);
                    catch (Exception)
                        return -1;
                }

                if (g(true) != 4 || g(false) != -1)
                    return 2;
                return log == "boom,S,boom," ? 0 : 1;
            }
        });
    }
}


// A handler that completes lets the function go on after the `try`: the
// `return` whose operand threw must not be pending any more.
static foreach (backend; Matrix!()) {
    @("returnOfThrowingCallCaughtThenFunctionContinues."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f() {
                    try {
                        return boom();
                    } catch (Exception) {
                        log ~= "c,";
                    }
                    log ~= "after,";
                    return 7;
                }

                if (f() != 7)
                    return 2;
                return log == "boom,c,after," ? 0 : 1;
            }
        });
    }
}


// A handler that does `continue` starts the next iteration, and the
// function returns after the loop.
static foreach (backend; Matrix!()) {
    @("returnOfThrowingCallCaughtThenContinue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f() {
                    foreach (i; 0 .. 3) {
                        try {
                            return boom();
                        } catch (Exception) {
                            log ~= "c,";
                            continue;
                        }
                    }
                    return 7;
                }

                if (f() != 7)
                    return 2;
                return log == "boom,c,boom,c,boom,c," ? 0 : 1;
            }
        });
    }
}


// A `finally` runs when the `return` operand throws, and the guard
// outside the `try` does not run.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnInTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f() {
                    scope(success) log ~= "S,";
                    try {
                        return boom();
                    } finally {
                        log ~= "F,";
                    }
                }
                int g() {
                    try
                        return f();
                    catch (Exception)
                        return -1;
                }

                if (g() != -1)
                    return 2;
                return log == "boom,F," ? 0 : 1;
            }
        });
    }
}


// The guard is the first statement and the throwing `return` is the last
// statement of the function body.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnAsLastStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f() {
                    log ~= "a,";
                    scope(success) log ~= "S,";
                    log ~= "b,";
                    return boom();
                }
                int g() {
                    try
                        return f();
                    catch (Exception)
                        return -1;
                }

                if (g() != -1)
                    return 2;
                return log == "a,b,boom," ? 0 : 1;
            }
        });
    }
}


// Both guards skip when the operand throws. Both run, the inner one first,
// when it does not.
static foreach (backend; Matrix!()) {
    @("scopeSuccessNestedGuards." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int fine() {
                    log ~= "fine,";
                    return 3;
                }
                int f(bool throws) {
                    scope(success) log ~= "outer,";
                    {
                        scope(success) log ~= "inner,";
                        return throws ? boom() : fine();
                    }
                }
                int g(bool throws) {
                    try
                        return f(throws);
                    catch (Exception)
                        return -1;
                }

                if (g(true) != -1 || g(false) != 3)
                    return 2;
                return log == "boom,fine,inner,outer," ? 0 : 1;
            }
        });
    }
}


// A throwing `return` runs `scope(failure)` and `scope(exit)` guards in
// reverse order of declaration and skips `scope(success)`. A normal
// `return` runs `scope(success)` and `scope(exit)` the same way.
static foreach (backend; Matrix!()) {
    @("scopeGuardsOfEachKindOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int fine() {
                    log ~= "fine,";
                    return 3;
                }
                int f(bool throws) {
                    scope(exit) log ~= "E1,";
                    scope(success) log ~= "S,";
                    scope(failure) log ~= "Fa,";
                    scope(exit) log ~= "E2,";
                    return throws ? boom() : fine();
                }
                int g(bool throws) {
                    try
                        return f(throws);
                    catch (Exception)
                        return -1;
                }

                if (g(true) != -1 || g(false) != 3)
                    return 2;
                return log == "boom,E2,Fa,E1,fine,E2,S,E1," ? 0 : 1;
            }
        });
    }
}


// A `return` of a call to a `void` function that throws leaves the
// guard's scope abnormally.
static foreach (backend; Matrix!()) {
    @("scopeSuccessInVoidFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                void thrower() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                void quiet() {
                    log ~= "quiet,";
                }
                void f(bool throws) {
                    scope(success) log ~= "S,";
                    return throws ? thrower() : quiet();
                }
                bool g(bool throws) {
                    try {
                        f(throws);
                        return false;
                    } catch (Exception) {
                        return true;
                    }
                }

                if (!g(true) || g(false))
                    return 2;
                return log == "boom,quiet,S," ? 0 : 1;
            }
        });
    }
}


// The destructor of the returned value runs once, and no guard runs after
// a throw from the call that makes the value.
static foreach (backend; Matrix!()) {
    @("scopeSuccessReturnOfStructWithDestructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                struct S {
                    int x;
                    ~this() {
                        log ~= "d,";
                    }
                }
                S make(bool throws) {
                    if (throws) {
                        log ~= "boom,";
                        throw new Exception("boom");
                    }
                    return S(5);
                }
                S f(bool throws) {
                    scope(success) log ~= "S,";
                    return make(throws);
                }
                int g(bool throws) {
                    try {
                        auto s = f(throws);
                        return s.x;
                    } catch (Exception)
                        return -1;
                }

                if (g(true) != -1 || g(false) != 5)
                    return 2;
                return log == "boom,S,d," ? 0 : 1;
            }
        });
    }
}


// A throw from the body of `scope(success)` replaces the return value and
// reaches the caller. A `scope(exit)` that was declared before it still
// runs.
static foreach (backend; Matrix!()) {
    @("scopeSuccessBodyThrows." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int fine() {
                    log ~= "fine,";
                    return 3;
                }
                int f() {
                    scope(exit) log ~= "E,";
                    scope(success) {
                        log ~= "S,";
                        throw new Exception("guard");
                    }
                    return fine();
                }
                string g() {
                    try {
                        f();
                        return "none";
                    } catch (Exception exception) {
                        return exception.msg;
                    }
                }

                if (g() != "guard")
                    return 2;
                return log == "fine,S,E," ? 0 : 1;
            }
        });
    }
}


// A throw from a `scope(exit)` guard after a `return` replaces the return
// value, and the guard declared before it runs.
static foreach (backend; Matrix!()) {
    @("scopeExitBodyThrowsAfterReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int fine() {
                    log ~= "fine,";
                    return 3;
                }
                int f() {
                    scope(exit) log ~= "E1,";
                    scope(exit) throw new Exception("guard");
                    return fine();
                }
                string g() {
                    try {
                        f();
                        return "none";
                    } catch (Exception exception) {
                        return exception.msg;
                    }
                }

                if (g() != "guard")
                    return 2;
                return log == "fine,E1," ? 0 : 1;
            }
        });
    }
}


// A throw from a `scope(failure)` guard replaces the throw that made it
// run.
static foreach (backend; Matrix!()) {
    @("scopeFailureBodyThrowsAfterThrowingReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f() {
                    scope(failure) {
                        log ~= "Fa,";
                        throw new Exception("guard");
                    }
                    return boom();
                }
                string g() {
                    try {
                        f();
                        return "none";
                    } catch (Exception exception) {
                        return exception.msg;
                    }
                }

                if (g() != "guard")
                    return 2;
                return log == "boom,Fa," ? 0 : 1;
            }
        });
    }
}


// A `catch` handler that does something and then rethrows is how dmd
// lowers `scope(success)` and `scope(failure)`. The rethrow must run after
// a `return` whose operand threw.
static foreach (backend; Matrix!()) {
    @("rethrowFromCatchAfterThrowingReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int boom() {
                    log ~= "boom,";
                    throw new Exception("boom");
                }
                int f() {
                    try {
                        return boom();
                    } catch (Throwable thrown) {
                        log ~= "caught,";
                        throw thrown;
                    }
                }
                int g() {
                    try
                        return f();
                    catch (Exception)
                        return -1;
                }

                if (g() != -1)
                    return 2;
                return log == "boom,caught," ? 0 : 1;
            }
        });
    }
}


// `std.conv.to!int` of a text that is not a number throws. Phobos reaches
// that throw through a `scope(success)` guard and a `return` of the call.
static foreach (backend; Matrix!()) {
    @("scopeSuccessGuardOfToIntThrowsConvException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.conv: ConvException, to;

            int main() {
                try {
                    "b".to!int;
                } catch (ConvException) {
                    return 0;
                }
                return 1;
            }
        });
    }
}

// A literal comparison folds to `assert(false)` at semantic time, and
// that still throws.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("failedLiteralComparisonAssertThrows." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            int main() {
                try {
                    assert(1 == 2);
                } catch (AssertError) {
                    return 0;
                }
                return 2;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE refuses to slice a null pointer"),
)) {
    @("sliceWithNullPointerAndNonzeroLengthIsTruthy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int[] nullPointer = (cast(int*) null)[0 .. 1];
                const viaOperand = nullPointer && true;
                const viaCondition = nullPointer ? 1 : 0;
                return viaOperand && viaCondition ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter leaves the class reference itself as the "
        ~ "value of `reference && true`, so the result is not a `bool`"),
)) {
    @("classReferenceIsTruthyOperandOfLogicalAnd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Thing {
            }

            int main() {
                Thing present = new Thing;
                Thing absent = null;
                const both = present && true;
                const neither = absent && true;
                return both && !neither ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("sliceIsTruthyOperandOfLogicalOr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int[] present = [1];
                int[] absent = null;
                const either = present || false;
                const neither = absent || false;
                return either && !neither ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's interpreter: cannot cast a delegate to bool at compile time"),
)) {
    @("delegateIsTruthyOperandOfLogicalAnd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int delegate() present = () => 1;
                int delegate() absent = null;
                const both = present && true;
                const neither = absent && true;
                return both && !neither ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's interpreter: cannot cast an associative array to bool at "
        ~ "compile time"),
)) {
    @("associativeArrayIsTruthyOperandOfLogicalAnd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int[int] present = [1: 2];
                int[int] absent = null;
                const both = present && true;
                const neither = absent && true;
                return both && !neither ? 0 : 1;
            }
        });
    }
}


// Every `Omit!(Native, ...)` below this line that names dmd bug 23996: dmd
// crashes on a `case` in an `if (__ctfe)` block, so there is no dmd result.
// ldc compiles a heap `new` (its program gives 3) and an array cast, but
// crashes or reports an internal error for an append, a string switch, a
// length assignment and an array construction in the block. The guests throw
// an `Error` for the constructs dmd leaves unlowered, which no compiler does.
//
// A `case` in an `if (__ctfe)` block is a jump target at run time, so
// the block compiles even though it never runs through its `if`. dmd leaves
// the statements of that block unlowered: a heap `new` has no
// `_d_newitemT` call there.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on a `case` in an "
            ~ "`if (__ctfe)` block (dmd bug 23996)"),
)) {
    @("heapNewInsideCtfeBlockWithCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int x) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            auto p = new int(3);
                            return *p;
                    }
                    default:
                        return 0;
                }
            }
            int main() {
                return f(0);
            }
        });
    }
}


// What the guest gets when run-time code enters the body of an
// `if (__ctfe)` block through a `case` label and reaches a construct that
// dmd left without a lowering: an `Error` it can catch.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on a `case` in an "
            ~ "`if (__ctfe)` block (dmd bug 23996)"),
    Omit!(Ctfe, Because.inexpressible, "`__ctfe` is true in CTFE"),
)) {
    @("heapNewInsideCtfeBlockThrowsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeStatusOf!(backend, q{
            int cleaned;
            int callee() { auto p = new int(3); return *p; }
            void failing() { throw new Exception("callee"); }
            int f(int x) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            if (callee() != 3) return 2;
                            try failing();
                            catch (Exception) {}
                            auto p = new int(3);
                            return *p;
                    }
                    default:
                        return 0;
                }
            }
            int main() {
                try {
                    try return f(1);
                    catch (Exception) { return 2; }
                    finally { ++cleaned; }
                } catch (Error error) {
                    return cleaned == 1 && callee() == 3 && f(0) == 0
                        && error.msg == "heap new in the body of an "
                        ~ "if (__ctfe) block: dmd compiles that body for "
                        ~ "compile time only" ? 7 : 1;
                }
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on a `case` in an "
            ~ "`if (__ctfe)` block (dmd bug 23996)"),
    Omit!(Ctfe, Because.inexpressible, "`__ctfe` is true in CTFE"),
)) {
    @("appendInsideCtfeBlockThrowsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeStatusOf!(backend, q{
            int f(int x) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            int[] a;
                            a ~= 1;
                            return cast(int) a.length;
                    }
                    default:
                        return 0;
                }
            }
            int main() {
                try
                    return f(1);
                catch (Error)
                    return 7;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on a `case` in an "
            ~ "`if (__ctfe)` block (dmd bug 23996)"),
)) {
    @("stringSwitchInsideCtfeBlockIsNotCompiledWhenNotEntered." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f(int x, string s) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            switch (s) {
                                case "a": return 1;
                                case "b": return 2;
                                default: return 3;
                            }
                    }
                    default:
                        return 0;
                }
            }
            int main() {
                return f(0, "a");
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on a `case` in an "
            ~ "`if (__ctfe)` block (dmd bug 23996)"),
    Omit!(Ctfe, Because.inexpressible, "`__ctfe` is true in CTFE"),
)) {
    @("stringSwitchInsideCtfeBlockThrowsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeStatusOf!(backend, q{
            enum E : string { a = "a", b = "b" }
            int f(int x, E s) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            final switch (s) {
                                case E.a: return 1;
                                case E.b: return 2;
                            }
                    }
                    default:
                        return 0;
                }
            }
            int main() {
                try
                    return f(1, E.b);
                catch (Error error)
                    return error.msg == "string switch in the body of an "
                        ~ "if (__ctfe) block: dmd compiles that body for "
                        ~ "compile time only" ? 7 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0 crashes on a case inside if (__ctfe) (dmd bug 23996)"),
    Omit!(Ctfe, Because.inexpressible, "__ctfe is true in CTFE"),
)) {
    @("lengthAssignmentInsideCtfeBlockThrowsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeStatusOf!(backend, q{
            int f(int x, size_t n) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            int[] a;
                            a.length = n;
                            return cast(int) a.length;
                    }
                    default: return 0;
                }
            }
            int main() {
                try
                    return f(1, 3);
                catch (Error error)
                    return error.msg == "array length assignment in the body "
                        ~ "of an if (__ctfe) block: dmd compiles that body for "
                        ~ "compile time only" ? 7 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0 crashes on a case inside if (__ctfe) (dmd bug 23996)"),
    Omit!(Ctfe, Because.inexpressible, "__ctfe is true in CTFE"),
)) {
    @("arrayConstructionInsideCtfeBlockThrowsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeStatusOf!(backend, q{
            int copies;
            struct S { int x; this(this) { ++copies; } }
            int f(int x) {
                S[2] a;
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            S[2] b = a;
                            return copies;
                        case 2:
                            S[2] c = a[0];
                            return copies;
                    }
                    default: return 0;
                }
            }
            int check(int x) {
                try
                    return f(x);
                catch (Error error)
                    return error.msg == "array construction in the body "
                        ~ "of an if (__ctfe) block: dmd compiles that body for "
                        ~ "compile time only" ? 7 : 1;
            }
            int main() {
                return f(0) == 0 && check(1) == 7 && check(2) == 7 ? 7 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0 crashes on a case inside if (__ctfe) (dmd bug 23996)"),
    Omit!(Ctfe, Because.inexpressible, "__ctfe is true in CTFE"),
)) {
    @("arrayCastInsideCtfeBlockThrowsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeStatusOf!(backend, q{
            int f(int x) {
                ubyte[3] storage;
                ubyte[] a = storage[];
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            auto b = cast(uint[]) a;
                            return cast(int) b.length;
                    }
                    default: return 0;
                }
            }
            int main() {
                try
                    return f(1);
                catch (Error error)
                    return error.msg == "array cast in the body "
                        ~ "of an if (__ctfe) block: dmd compiles that body for "
                        ~ "compile time only" ? 7 : 1;
            }
        });
    }
}

// A condition with no temporary splits at `&&`, `||` and `!`. A comparison of
// a `real` is not a register scalar of the interpreter's tree, so the
// operands that hold one run as conditions of their own.
static foreach (backend; Matrix!()) {
    @("logicalConditionsWithAWideOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                real wide = 2.5L;
                int calls;
                bool bump() { ++calls; return true; }
                int taken;
                foreach (i; 0 .. 6) {
                    if (i > 0 && wide > i && !(i == 2))
                        taken += 10;
                    if (!(wide < i) || i == 5)
                        taken += 1;
                    if (i > 3 || wide > 1.5L && bump())
                        taken += 100;
                    while (i < 0 || wide < i - 0.5L) {
                        taken += 1000;
                        break;
                    }
                }
                return taken == 2614 && calls == 4 ? 0 : 1;
            }
        });
    }
}

// `foreach (ref element; ...)` declares a `ref` variable that holds the
// address of the element, so writes through it change the array.
static foreach (backend; Matrix!()) {
    @("foreachRefBindsTheElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Cell { int a; double b; }
            int main() {
                Cell[4] cells;
                foreach (i, ref cell; cells) {
                    cell.a = cast(int) i;
                    cell.b = i * 0.5;
                }
                long[] dynamic = [1, 2, 3];
                foreach (ref element; dynamic)
                    element *= 2;
                foreach_reverse (ref element; dynamic)
                    element += 1;
                double total = 0;
                foreach (ref cell; cells)
                    total += cell.a + cell.b;
                return dynamic == [3, 5, 7] && total == 9.0 ? 0 : 1;
            }
        });
    }
}

// A conditional expression runs only the arm that its condition selects,
// whether it yields a scalar, a slice, an lvalue or nothing.
static foreach (backend; Matrix!()) {
    @("conditionalExpressionForms." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair { int a; int b; }
            void bump(ref int x) { ++x; }
            int pick(int n, bool even) { return even ? n * 2 : -n; }
            int[] shorter(int[] a, int[] b) { return a.length < b.length ? a : b; }
            double mix(bool even) { return even ? 0.5 : 2.5; }
            int main() {
                int x, y;
                Pair p1 = Pair(1, 2);
                Pair p2 = Pair(3, 4);
                int[] s1 = [1, 2];
                int[] s2 = [3];
                int total;
                foreach (i; 0 .. 4) {
                    const even = i % 2 == 0;
                    total += even ? 10 : 1;
                    total += cast(int) (mix(even) * 2);
                    const bool flag = even ? i > 0 : true;
                    total += flag ? 100 : 0;
                    total += (even ? s1 : s2).length;
                    total += (even ? p1 : p2).b;
                    total += pick(i, even) + shorter(s1, s2).length;
                    bump(even ? x : y);
                    even ? x++ : y++;
                    even ? bump(x) : bump(y);
                    int* target = even ? &x : &y;
                    *target += 100;
                    total += *(even ? &p1.a : &p2.a);
                }
                return total == 364 && x == 206 && y == 206 ? 0 : 1;
            }
        });
    }
}

// `return` of a struct or static array value writes it into the place that
// the caller gave. Each field of a literal is a scalar, a slice, a bit
// field, a nested value, or an element that the literal repeats.
static foreach (backend; Matrix!()) {
    @("returnOfAggregateValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Inner { int x; double y; }
            struct Outer {
                Inner inner;
                int[] slice;
                bool flag;
                ubyte small;
                int[2] pair;
                long wide = 9;
            }
            struct Bits { int a; uint low : 3; uint high : 5; ubyte tail; }
            struct Plain { int a = 1; int b = 2; }

            Outer make(int n, int[] s) {
                return Outer(Inner(n, n * 0.5), s, n > 1, cast(ubyte) n,
                    [n, n + 1]);
            }
            Outer pick(bool first, Inner chosen) {
                return first
                    ? Outer(chosen, null, true, 1, [1, 2], 3)
                    : Outer(Inner(9, 9.5), [7], false, 2, [3, 4]);
            }
            Bits bits(int n) { return Bits(n, n & 7, n >> 3, 5); }
            Plain plain(bool zero) { return zero ? Plain() : Plain(5, 6); }
            Inner copy(ref Inner source) { return source; }
            Plain at(Plain[] values, int i) { return values[i]; }
            int[3] filled(int n) { return [n, n + 1, n + 2]; }
            int[2] constant() { return [1, 2]; }

            int main() {
                int outerLocal = 100;
                struct Nested { int a; int get() { return a + outerLocal; } }
                Nested nested(int a) { return Nested(a); }

                const o = make(3, [4, 5]);
                if (o.inner != Inner(3, 1.5) || o.slice != [4, 5] || !o.flag
                        || o.small != 3 || o.pair != [3, 4] || o.wide != 9)
                    return 1;
                const p = pick(true, Inner(7, 8.5));
                if (p.inner != Inner(7, 8.5) || p.slice.length != 0
                        || p.pair != [1, 2] || p.wide != 3)
                    return 2;
                const q = pick(false, Inner(0, 0));
                if (q.inner != Inner(9, 9.5) || q.slice != [7] || q.flag
                        || q.wide != 9)
                    return 3;
                const b = bits(37);
                if (b.a != 37 || b.low != 5 || b.high != 4 || b.tail != 5)
                    return 4;
                Inner source = Inner(11, 12.5);
                Plain[2] two = [Plain(8, 9), Plain(10, 11)];
                if (plain(true) != Plain(1, 2) || plain(false) != Plain(5, 6)
                        || copy(source) != source || at(two[], 1) != Plain(10, 11)
                        || filled(4) != [4, 5, 6] || constant() != [1, 2])
                    return 5;
                make(1, null);
                return nested(5).get() == 105 ? 0 : 6;
            }
        });
    }
}

// A function that returns `ref` gives the address of its operand, and the
// constructor of a struct returns `this` that way.
static foreach (backend; Matrix!()) {
    @("returnOfReferences." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        69.shouldBeStatusOf!(backend, q{
            struct Counter {
                int n;
                long w;
                ref int get() { return n; }
                ref long wide() { return w; }
                this(int start) { n = start; }
            }
            ref int pickRef(ref int a, ref int b, bool first) {
                return first ? a : b;
            }
            int main() {
                int t;
                Counter c = Counter(3);
                foreach (i; 0 .. 3) {
                    c.get() += 4;
                    c.wide() += 5;
                    int x = 1, y = 2;
                    pickRef(x, y, i == 1) += 10;
                    t += x + y;
                }
                return t + c.n + cast(int) c.w;
            }
        });
    }
}

// A switch selects the case of its value whether the case values are close
// together or far apart, and at the ends of the range of the type of its
// operand. A value between, below or above the case values takes `default`.
static foreach (backend; Matrix!()) {
    @("switchSelectsAmongCloseAndDistantCaseValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int close(int value) {
                switch (value) {
                    case -2: return 1;
                    case 0: return 2;
                    case 1: return 3;
                    case 3: return 4;
                    case 4: return 5;
                    case 6: return 6;
                    default: return 0;
                }
            }

            int distant(long value) {
                switch (value) {
                    case long.min: return 1;
                    case -1_000_000: return 2;
                    case 7: return 3;
                    case 1L << 40: return 4;
                    case long.max: return 5;
                    default: return 0;
                }
            }

            int unsigned(ulong value) {
                switch (value) {
                    case 0: return 1;
                    case 1UL << 63: return 2;
                    case ulong.max: return 3;
                    default: return 0;
                }
            }

            void main() {
                assert(close(-3) == 0);
                assert(close(-2) == 1);
                assert(close(-1) == 0);
                assert(close(0) == 2);
                assert(close(1) == 3);
                assert(close(2) == 0);
                assert(close(4) == 5);
                assert(close(6) == 6);
                assert(close(7) == 0);
                assert(close(int.min) == 0);

                assert(distant(long.min) == 1);
                assert(distant(long.min + 1) == 0);
                assert(distant(-1_000_000) == 2);
                assert(distant(7) == 3);
                assert(distant(8) == 0);
                assert(distant(1L << 40) == 4);
                assert(distant(long.max) == 5);
                assert(distant(long.max - 1) == 0);

                assert(unsigned(0) == 1);
                assert(unsigned(1UL << 63) == 2);
                assert(unsigned(ulong.max) == 3);
                assert(unsigned(ulong.max - 1) == 0);
            }
        });
    }
}

// A switch on a character selects the case of its code unit or code point.
static foreach (backend; Matrix!()) {
    @("switchOnCharactersSelectsTheCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int narrow(char c) {
                switch (c) {
                    case 'a': .. case 'z': return 1;
                    case '0': .. case '9': return 2;
                    case '\xff': return 3;
                    default: return 0;
                }
            }

            int wide(dchar c) {
                switch (c) {
                    case 'é': return 1;
                    case '€': return 2;
                    case '\U0010FFFF': return 3;
                    default: return 0;
                }
            }

            void main() {
                assert(narrow('q') == 1);
                assert(narrow('7') == 2);
                assert(narrow('\xff') == 3);
                assert(narrow(' ') == 0);
                assert(wide('é') == 1);
                assert(wide('€') == 2);
                assert(wide('\U0010FFFF') == 3);
                assert(wide('e') == 0);
            }
        });
    }
}

// `goto case;` with no value enters the statements of the next case.
static foreach (backend; Matrix!()) {
    @("gotoCaseWithNoValueEntersTheNextCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int value) {
                int result;
                switch (value) {
                    case 0:
                        result += 1;
                        goto case;
                    case 1:
                        result += 10;
                        break;
                    default:
                        result += 100;
                }
                return result;
            }

            void main() {
                assert(run(0) == 11);
                assert(run(1) == 10);
                assert(run(2) == 100);
            }
        });
    }
}

// A `goto case` in the `else` branch of an `if` leaves the branch and the
// case for the target case.
static foreach (backend; Matrix!()) {
    @("gotoCaseFromElseBranch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int value, bool first) {
                int result;
                switch (value) {
                    case 0:
                        if (first)
                            result += 1;
                        else
                            goto case 2;
                        result += 10;
                        break;
                    case 1:
                        result += 100;
                        break;
                    case 2:
                        result += 1000;
                        break;
                    default:
                }
                return result;
            }

            void main() {
                assert(run(0, true) == 11);
                assert(run(0, false) == 1000);
            }
        });
    }
}

// A `goto case` in a `catch` handler leaves the handler for the target
// case.
static foreach (backend; Matrix!()) {
    @("gotoCaseFromCatchHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void fail(bool really) {
                if (really)
                    throw new Exception("fail");
            }

            int run(bool really) {
                int result;
                switch (0) {
                    case 0:
                        try {
                            fail(really);
                            result += 1;
                        } catch (Exception) {
                            result += 10;
                            goto case 1;
                        }
                        break;
                    case 1:
                        result += 100;
                        break;
                    default:
                }
                return result;
            }

            void main() {
                assert(run(false) == 1);
                assert(run(true) == 110);
            }
        });
    }
}

// A `goto case` in a loop in a case leaves the loop for the target case.
static foreach (backend; Matrix!()) {
    @("gotoCaseFromLoopInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int result;
                switch (0) {
                    case 0:
                        for (int i = 0; i < 10; ++i) {
                            result += 1;
                            if (i == 2)
                                goto case 1;
                        }
                        result += 1000;
                        break;
                    case 1:
                        result += 100;
                        break;
                    default:
                }
                return result;
            }

            void main() {
                assert(run() == 103);
            }
        });
    }
}

// A `goto case` as the last statement of a switch enters an earlier case:
// the switch runs on until a case leaves it.
static foreach (backend; Matrix!()) {
    @("gotoCaseAsLastStatementEntersAnEarlierCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int value) {
                int steps;
                int visits;
                switch (value) {
                    case 0:
                        ++steps;
                        if (steps == 3)
                            break;
                        goto case 1;
                    case 1:
                        visits += 10;
                        goto case 0;
                    default:
                        goto case 0;
                }
                return steps + visits;
            }

            void main() {
                assert(run(0) == 23);
                assert(run(1) == 33);
                assert(run(5) == 23);
            }
        });
    }
}

// A `continue` with the label of a loop, in a case of a switch in the loop,
// leaves the switch and starts the next iteration of the loop.
static foreach (backend; Matrix!()) {
    @("labelledContinueFromCaseStartsNextIteration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int result;
                outer: for (int i = 0; i < 4; ++i) {
                    for (int j = 0; j < 4; ++j) {
                        switch (j) {
                            case 1:
                                continue outer;
                            default:
                                result += 1;
                        }
                        result += 10;
                    }
                    result += 1000;
                }
                return result;
            }

            void main() {
                assert(run() == 44);
            }
        });
    }
}

// A `break` with the label of a loop, in a case of a switch in the loop,
// leaves the switch and the loop.
static foreach (backend; Matrix!()) {
    @("labelledBreakFromCaseLeavesTheLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run() {
                int result;
                outer: foreach (i; 0 .. 4) {
                    foreach (j; 0 .. 4) {
                        switch (i + j) {
                            case 4:
                                break outer;
                            default:
                                result += 1;
                        }
                        result += 10;
                    }
                }
                return result;
            }

            void main() {
                assert(run() == 77);
            }
        });
    }
}

// The variables that a case declares are destroyed when the statements of
// the case end, whether the case leaves the switch or falls through, and a
// `scope(exit)` in the case runs then too.
static foreach (backend; Matrix!()) {
    @("caseLocalsAndScopeExitEndWithTheCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Logged {
                string* log;
                char name;
                ~this() { *log ~= name; }
            }

            string run(int value) {
                string log;
                switch (value) {
                    case 0:
                        auto a = Logged(&log, 'a');
                        scope (exit) log ~= 'x';
                        log ~= '0';
                        break;
                    case 1:
                        auto b = Logged(&log, 'b');
                        log ~= '1';
                        goto case;
                    case 2:
                        log ~= '2';
                        break;
                    default:
                }
                return log;
            }

            void main() {
                assert(run(0) == "0xa");
                assert(run(1) == "1b2");
                assert(run(2) == "2");
            }
        });
    }
}

// Duff's device: the cases of a `switch` are labels inside the body of a
// `do` loop. The switch jumps into the body at the case of the remainder,
// and the loop goes on from there.
static foreach (backend; Matrix!()) {
    @("duffsDeviceEntersTheLoopBodyAtTheCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int copy(int count) {
                int[20] from, to;
                foreach (i, ref one; from)
                    one = cast(int) i + 1;
                int* source = from.ptr;
                int* target = to.ptr;
                int rounds = (count + 3) / 4;
                switch (count % 4) {
                    case 0: do { *target++ = *source++; goto case;
                    case 3:      *target++ = *source++; goto case;
                    case 2:      *target++ = *source++; goto case;
                    case 1:      *target++ = *source++;
                            } while (--rounds > 0);
                            break;
                    default:
                        assert(0);
                }
                int sum;
                foreach (i, one; to)
                    sum += one * cast(int) (i + 1);
                return sum;
            }

            void main() {
                assert(copy(1) == 1);
                assert(copy(2) == 5);
                assert(copy(3) == 14);
                assert(copy(5) == 55);
                assert(copy(10) == 385);
            }
        });
    }
}

// A `case` inside a block: the switch enters the block at the label. The
// variable that the block declares after the label is destroyed when the
// block ends, also when a `break` leaves the switch from inside it.
static foreach (backend; Matrix!()) {
    @("caseInsideBlockDestroysTheBlockLocals." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Logged {
                string* log;
                char name;
                ~this() { *log ~= name; }
            }

            string run(int value) {
                string log;
                switch (value) {
                    case 0:
                        log ~= '0';
                        goto case 1;
                    default:
                        {
                            case 1:
                            auto a = Logged(&log, 'a');
                            log ~= '1';
                            if (value == 1)
                                break;
                            log ~= '2';
                        }
                        log ~= '3';
                        break;
                }
                return log;
            }

            void main() {
                assert(run(0) == "012a3");
                assert(run(1) == "1a");
                assert(run(2) == "12a3");
            }
        });
    }
}

// dmd rejects a `case` inside a `try`, which is not at the `try` level of
// its switch. A `case` in a loop body before a `try`/`finally` is not: the
// `finally` body runs when a `break` or a `continue` leaves the `try` of a
// loop that the switch entered at the label.
static foreach (backend; Matrix!()) {
    @("caseInsideLoopBeforeTryFinallyRunsTheFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string run(int value) {
                string log;
                int i;
                switch (value) {
                    case 0:
                        log ~= 'a';
                        for (i = 0; i < 3; ++i) {
                            log ~= 'b';
                            case 1:
                            try {
                                log ~= 'c';
                                if (i == 1)
                                    continue;
                                if (value == 1)
                                    break;
                            } finally {
                                log ~= 'f';
                            }
                            log ~= 'd';
                        }
                        break;
                    default:
                        log ~= 'z';
                }
                return log;
            }

            void main() {
                assert(run(0) == "abcfdbcfbcfd");
                assert(run(1) == "cf");
                assert(run(2) == "z");
            }
        });
    }
}

// A `goto case` to a `case` inside an `if` whose condition is false: the
// jump enters the `if` at the label without testing the condition.
static foreach (backend; Matrix!()) {
    @("gotoCaseEntersANestedCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int value) {
                int result;
                switch (value) {
                    case 0:
                        result = 1;
                        goto case 2;
                    case 1:
                        if (value > 100) {
                            case 2:
                            result = result * 10 + 2;
                        }
                        break;
                    default:
                        result = 9;
                }
                return result;
            }

            void main() {
                assert(run(0) == 12);
                assert(run(1) == 0);
                assert(run(2) == 2);
                assert(run(3) == 9);
            }
        });
    }
}

// A `case` inside a `catch` handler with no variable: the switch enters
// the handler at the label, outside the `try`, with nothing thrown.
static foreach (backend; Matrix!()) {
    @("caseInsideCatchHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int value) {
                int result;
                switch (value) {
                    case 0:
                        try
                            result = 1;
                        catch (Exception) {
                            case 1:
                            result += 5;
                        }
                        break;
                    default:
                        result = 9;
                }
                return result;
            }

            void main() {
                assert(run(0) == 1);
                assert(run(1) == 5);
                assert(run(2) == 9);
            }
        });
    }
}
