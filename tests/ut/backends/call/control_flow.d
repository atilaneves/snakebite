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
        "the bytecode compiler only rejects/inlines a `finally` for an " ~
        "exit that leaves `_finished` set; an `if` with no `else` resets " ~
        "`_finished` on its fall-through path, so a `break` reached only " ~
        "through the taken branch skips the `finally` silently instead " ~
        "of running it - `finallyRuns` stays 0 instead of reaching 2"),
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
