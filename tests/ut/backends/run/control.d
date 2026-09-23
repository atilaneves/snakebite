module ut.backends.run.control;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;

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
