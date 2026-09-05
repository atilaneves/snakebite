module ut.backends.call.control_flow;


import ut.backends;


// DMD emits this shape for cleanup code, including the cleanup in the
// benchmark's generated `write` function.
static foreach (backend; Matrix!()) {
    @("tryFinally.runsOnNormalExit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(backend, q{
            int result() {
                int value;
                try {
                    value = 1;
                } finally {
                    value = 2;
                }
                return value;
            }
        }, "result");
    }
}


// The value a `return` inside a `try` carries out must be the one
// computed before the `finally` runs, not whatever the `finally` itself
// leaves lying around in the same local - the shape `cerealed`'s
// `ScopeBuffer.cat` uses to return a slice built before its own
// `scope(exit)` frees the buffer it was built from.
static foreach (backend; Matrix!()) {
    @("tryFinally.returnValueSurvivesFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(backend, q{
            int result() {
                int value = 1;
                try {
                    return value;
                } finally {
                    value = 2;
                }
            }
        }, "result");
    }
}


// The `finally` runs exactly once, and strictly before the caller ever
// observes the `return`ed value - not zero times (skipped), not twice
// (once inlined at the `return`, once more for a "fall through" copy
// that should not exist on this path).
static foreach (backend; Matrix!()) {
    @("tryFinally.runsExactlyOnceBeforeCallerObservesReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        71.shouldBeRetOf!(backend, q{
            int result(ref int cleanups) {
                try {
                    return 7;
                } finally {
                    ++cleanups;
                }
            }

            int cleanupCount() {
                int cleanups;
                const returned = result(cleanups);
                return returned * 10 + cleanups;
            }
        }, "cleanupCount");
    }
}


// A `return` reached through an `if` inside the `try` still runs the
// `finally` on its way out - the `if` is not itself a `try`, so nothing
// about entering it changes which `finally` bodies are pending. `ranFinally`
// is read back by the caller, after `result` itself already returned:
// a `return`ed value on its own cannot tell "the finally ran" apart from
// "the finally was skipped and nobody noticed", when, as here, that value
// does not depend on anything the finally touches.
static foreach (backend; Matrix!()) {
    @("tryFinally.returnInsideIfRunsFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        121.shouldBeRetOf!(backend, q{
            int result(ref int ranFinally) {
                try {
                    if (true)
                        return 12;
                } finally {
                    ranFinally = 1;
                }
                return 0;
            }

            int check() {
                int ranFinally;
                const returned = result(ranFinally);
                return returned * 10 + ranFinally;
            }
        }, "check");
    }
}


// A `return` reached through a loop inside the `try` still runs the
// `finally` on its way out - the same requirement as the `if` case
// above, for a loop instead.
static foreach (backend; Matrix!()) {
    @("tryFinally.returnInsideLoopRunsFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        231.shouldBeRetOf!(backend, q{
            int result(ref int ranFinally) {
                try {
                    for (int i; i < 5; ++i)
                        if (i == 2)
                            return 23;
                } finally {
                    ranFinally = 1;
                }
                return 0;
            }

            int check() {
                int ranFinally;
                const returned = result(ranFinally);
                return returned * 10 + ranFinally;
            }
        }, "check");
    }
}


// A `finally` runs after its own `try`/`finally` statement is left. When
// that statement's `_body` is itself a `try`/`catch`, a `return` from the
// inner `try` leaves the inner `try`/`catch` before the `finally` ever
// runs, so nothing the `finally` throws can reach the inner `catch` - it
// keeps unwinding to whatever catches it further out.
static foreach (backend; Matrix!()) {
    @("tryFinally.finallyThrowIsNotCaughtByInnerCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(backend, q{
            void cleanup(ref int calls) {
                if (calls++ == 0)
                    throw new Exception("cleanup");
            }

            int one() {
                return 1;
            }

            int result(ref int calls) {
                try {
                    try {
                        return one();
                    } catch (Exception e) {
                        return 2;
                    }
                } finally {
                    cleanup(calls);
                }
            }

            int check() {
                int calls;
                try
                    return result(calls);
                catch (Exception e)
                    return 3;
            }
        }, "check");
    }
}


// A `break` out of a `try` body runs the `finally` on its way out, the
// same as a `return` does. The `break` here sits in an `if` with no
// `else`, the shape a lookup loop with an early exit has.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.diverges,
        "a `break` reached only through the taken branch of an `if` " ~
        "with no `else` skips the `finally` silently instead of " ~
        "running it - `finallyRuns` stays 0 instead of reaching 2"),
)) {
    @("tryFinally.breakInsideIfRunsFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(backend, q{
            int result() {
                int finallyRuns;
                for (int i; i < 3; ++i) {
                    try {
                        if (i == 1)
                            break;
                    } finally {
                        ++finallyRuns;
                    }
                }
                return finallyRuns;
            }
        }, "result");
    }
}


// The two `finally` bodies of nested `try` statements run innermost
// first when a `return` leaves both, each exactly once, and the value
// returned is the one computed before either ran.
static foreach (backend; Matrix!()) {
    @("tryFinally.nestedReturnRunsInnermostFirst." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        512.shouldBeRetOf!(backend, q{
            int result(ref int trace) {
                int value = 5;
                try {
                    try {
                        return value;
                    } finally {
                        trace = trace * 10 + 1;
                        value = 6;
                    }
                } finally {
                    trace = trace * 10 + 2;
                }
            }

            int check() {
                int trace;
                const returned = result(trace);
                return returned * 100 + trace;
            }
        }, "check");
    }
}


// A `finally` that itself contains a `try`/`finally`, left by a `return`
// from the outer `try` body: both run, inner-of-finally last.
static foreach (backend; Matrix!()) {
    @("tryFinally.finallyWithOwnTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        112.shouldBeRetOf!(backend, q{
            int result(ref int trace) {
                try {
                    return 1;
                } finally {
                    try {
                        trace = trace * 10 + 1;
                    } finally {
                        trace = trace * 10 + 2;
                    }
                }
            }

            int check() {
                int trace;
                const returned = result(trace);
                return returned * 100 + trace;
            }
        }, "check");
    }
}


// A `return` inside an `if` with no `else` inlines the `finally` once
// there; the same `finally` is then compiled again for the fall-through
// exit. The `switch` inside it must dispatch each copy to its own case
// bodies, not the first copy's - a `default:` only, here.
static foreach (backend; Matrix!()) {
    @("tryFinally.switchInFinallyDispatchesOwnCaseWhenCompiledTwice." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7101.shouldBeRetOf!(backend, q{
            int result(ref int trace, bool early, int x) {
                try {
                    if (early)
                        return 7;
                } finally {
                    switch (x) {
                        default: trace = 1;
                    }
                }
                return 0;
            }

            int check() {
                int trace;
                const first = result(trace, true, 5) * 10 + trace;
                trace = 0;
                const second = result(trace, false, 5) * 10 + trace;
                return first * 100 + second;
            }
        }, "check");
    }
}


// As above, with `case` labels and `break`s in the `switch`.
static foreach (backend; Matrix!()) {
    @("tryFinally.switchWithBreaksInFinallyDispatchesOwnCaseWhenCompiledTwice." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7202.shouldBeRetOf!(backend, q{
            int result(ref int trace, bool early, int x) {
                try {
                    if (early)
                        return 7;
                } finally {
                    switch (x) {
                        case 1: trace = 1; break;
                        case 5: trace = 2; break;
                        default: trace = 3; break;
                    }
                }
                return 0;
            }

            int check() {
                int trace;
                const first = result(trace, true, 5) * 10 + trace;
                trace = 0;
                const second = result(trace, false, 5) * 10 + trace;
                return first * 100 + second;
            }
        }, "check");
    }
}


// Nested: try/finally F0 { try/catch C1 { try/finally F1 { try/catch C2
// { return } } } }. A throw from F1 is caught by C1 (F1 sits inside C1's
// body), never by C2. A throw from F0 escapes both.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "once an earlier `return` has already fixed the value this " ~
        "function hands back, statements after the first one in " ~
        "whatever block runs next - here, the catch reached while " ~
        "unwinding through a `finally` - are skipped, so this catch's " ~
        "own `return` never overwrites that value"),
)) {
    @("tryFinally.nestedFinallyCaughtByMiddleCatchOnly." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        21.shouldBeRetOf!(backend, q{
            void boom() {
                throw new Exception("f1");
            }

            int result(ref int trace) {
                try {
                    try {
                        try {
                            try {
                                return 1;
                            } catch (Exception e) {
                                return 9;
                            }
                        } finally {
                            boom();
                        }
                    } catch (Exception e) {
                        trace = trace * 10 + 2;
                        return 2;
                    }
                } finally {
                    trace = trace * 10 + 1;
                }
            }

            int check() {
                int trace;
                const returned = result(trace);
                return returned * 10 + trace % 10 + (trace / 10 == 2 ? 0 : 100);
            }
        }, "check");
    }
}


// A `finally` body compiled twice (inlined at the `return`, and again
// for the fall-through exit) declares its own local: the fall-through
// copy must still run its own assignment to it.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "once a `return` inside the `try` has already fixed the value " ~
        "this function hands back, the `finally` that then runs stops " ~
        "after its first statement, so this local's own assignment " ~
        "never runs"),
)) {
    @("tryFinally.localInFinallyIsSetWhenCompiledTwice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        73.shouldBeRetOf!(backend, q{
            int result(ref int trace, bool early) {
                try {
                    if (early)
                        return 7;
                } finally {
                    int x = 3;
                    trace = x;
                }
                return 0;
            }

            int check() {
                int trace;
                const returned = result(trace, true);
                return returned * 10 + trace;
            }
        }, "check");
    }
}


// As above, with a loop in the `finally` instead of a local declaration.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "once a `return` inside the `try` has already fixed the value " ~
        "this function hands back, the `finally` that then runs stops " ~
        "after its first statement, so this loop never iterates"),
)) {
    @("tryFinally.loopInFinallyRunsWhenCompiledTwice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7303.shouldBeRetOf!(backend, q{
            int result(ref int trace, bool early) {
                try {
                    if (early)
                        return 7;
                } finally {
                    for (int i; i < 3; ++i)
                        ++trace;
                }
                return 0;
            }

            int check() {
                int trace;
                const first = result(trace, true) * 10 + trace;
                trace = 0;
                const second = result(trace, false) * 10 + trace;
                return first * 100 + second;
            }
        }, "check");
    }
}


// The value a `return` carries out is computed before the `finally`
// runs, even when computing it is a call whose result depends on state
// the `finally` then changes.
static foreach (backend; Matrix!()) {
    @("tryFinally.returnCallResultBeforeFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            int twice(int x) {
                return x * 2;
            }

            int result() {
                int value = 21;
                try {
                    return twice(value);
                } finally {
                    value = 0;
                }
            }
        }, "result");
    }
}


// `scope(exit)` is a `try`/`finally` in disguise: a `return` inside it
// runs the guard before the caller sees the value.
static foreach (backend; Matrix!()) {
    @("tryFinally.scopeExitRunsOnReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        71.shouldBeRetOf!(backend, q{
            int result(ref int cleanups) {
                scope(exit) ++cleanups;
                return 7;
            }

            int check() {
                int cleanups;
                const returned = result(cleanups);
                return returned * 10 + cleanups;
            }
        }, "check");
    }
}


static foreach (backend; Matrix!()) {
    @("tryFinally.scopeExitRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    3.shouldBeRetOf!(
        backend,
        q{
            int result() {
                int value;
                {
                    scope(exit) value = 3;
                    value = 2;
                }
                return value;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot mutate a module-level variable at run time"),
)) {
    @("tryFinally.scopeExitRunsDuringReturnAndThrow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    23.shouldBeRetOf!(
        backend,
        q{
            int value;

            int returns() {
                scope(exit) value = 2;
                return 7;
            }

            bool passes() {
                return false;
            }

            int result() {
                returns();
                try {
                    scope(exit) value = value * 10 + 3;
                    assert(passes());
                } catch (Throwable) {
                }
                return value;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!(Omit!(Bytecode, Because.unconfirmed))) {
    @("tryFinally.scopeExitRunsDuringContinue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    3.shouldBeRetOf!(
        backend,
        q{
            int result() {
                int exits;
                for (int i; i < 3; ++i) {
                    scope(exit) ++exits;
                    continue;
                }
                return exits;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!()) {
    @("loop.doWhileBreaksAndContinues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    8.shouldBeRetOf!(
        backend,
        q{
            int result() {
                int i;
                int sum;

                do {
                    ++i;

                    if (i == 2)
                        continue;

                    if (i == 5)
                        break;

                    sum += i;
                } while (i < 6);

                return sum;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!()) {
    @("loop.labelledBreakExitsOuterLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    2.shouldBeRetOf!(
        backend,
        q{
            int result() {
                int count;

            outer:
                for (int i; i < 2; ++i) {
                    for (int j; j < 2; ++j) {
                        ++count;
                        if (i == 0 && j == 1)
                            break outer;
                    }
                }

                return count;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!()) {
    @("loop.labelledContinueRepeatsOuterLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    6.shouldBeRetOf!(
        backend,
        q{
            int result() {
                int count;

            outer:
                for (int i; i < 3; ++i) {
                    for (int j; j < 4; ++j) {
                        if (j == i + 1)
                            continue outer;

                        ++count;
                    }
                }

                return count;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!()) {
    @("unrolledLoop.staticForeachRunsInOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    123.shouldBeRetOf!(
        backend,
        q{
            int result() {
                int value;
                static foreach (digit; [1, 2, 3])
                    value = value * 10 + digit;
                return value;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!()) {
    @("if.taken." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    int ret = 0;
                    if (one() < two())
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("if.notTaken." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    int ret = 0;
                    if (two() < one())
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("if.elseTaken." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        20.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    int ret = 0;
                    if (two() < one())
                        ret += 10;
                    else
                        ret += 20;
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("if.localInBranch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A local declared inside a branch is still a local of the
        // enclosing function: its storage must exist for the branch to
        // declare it in and to read it back.
        10.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    int ret = 0;
                    if (one() < two()) {
                        int n = 10;
                        ret += n;
                    }
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("if.notOperator." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int zero() {
                    return 0;
                }

                int result() {
                    int ret = 0;
                    if (!zero())
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("if.truthyInt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int result() {
                    int ret = 0;
                    if (one())
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("if.falsyInt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int zero() {
                    return 0;
                }

                int result() {
                    int ret = 0;
                    if (zero())
                        ret += 10;
                    return ret;
                }
            },
            "result",
        );
    }
}

// Both branches return, so nothing follows the whole `if` - it is the
// function's own last statement, with no trailing statement for a
// compiler to fall through to on either path.
static foreach (backend; Matrix!()) {
    @("if.bothBranchesReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int pick() {
                    if (one() == 1)
                        return 10;
                    else
                        return 20;
                }
            },
            "pick",
        );
    }
}
