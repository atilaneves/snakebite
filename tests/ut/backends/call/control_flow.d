module ut.backends.call.control_flow;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// Compiled D needs a callee to compile, not to run. A call that the program
// never executes must not reject the program, even when the callee holds a
// native call the FFI call barrier cannot classify (an aggregate return
// that carries a `real`).
static foreach (backend; Matrix!()) {
    @("unexecutedUnclassifiableNativeCallCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                real value;
            }

            pragma(mangle, "labs")
            extern(C) Wide labs(long);

            void nativeBody() {
                labs(-1);
            }

            void choose(bool execute) {
                if (execute)
                    nativeBody();
            }

            void main() {
                choose(false);
            }
        });
    }
}


// Floating conditions use D's value semantics: both signed zeros are false,
// every nonzero value is true, and NaN is true because it is not zero.
static foreach (backend; Matrix!()) {
    @("condition.floatingTruth.float." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(backend, q{
            int classify(float value) {
                int result;
                if (value)
                    result = 1;
                return result;
            }

            int cases() {
                return classify(0.0f)
                    + classify(-0.0f) * 2
                    + classify(1.5f) * 4
                    + classify(float.nan) * 8;
            }
        }, "cases");
    }
}

static foreach (backend; Matrix!()) {
    @("condition.floatingTruth.double." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(backend, q{
            int classify(double value) {
                int result;
                if (value)
                    result = 1;
                return result;
            }

            int cases() {
                return classify(0.0)
                    + classify(-0.0) * 2
                    + classify(1.5) * 4
                    + classify(double.nan) * 8;
            }
        }, "cases");
    }
}

static foreach (backend; Matrix!()) {
    @("condition.floatingTruth.real." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(backend, q{
            int classify(real value) {
                int result;
                if (value)
                    result = 1;
                return result;
            }

            int cases() {
                return classify(0.0L)
                    + classify(-0.0L) * 2
                    + classify(1.5L) * 4
                    + classify(real.nan) * 8;
            }
        }, "cases");
    }
}


// An imaginary condition shares the same one-word nonzero test a real
// one gets, just over the imaginary value's own bytes (`TypeFacts.
// Truth.of`'s `isFloat` case, sized to the operand rather than dispatched
// on its type).
static foreach (backend; Matrix!()) {
    @("condition.floatingTruth.imaginary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                idouble zero = 0.0i;
                idouble nonzero = 3.0i;
                if (zero) assert(false);
                if (nonzero) {} else assert(false);
            }
        });
    }
}


// A complex condition is true when either component is nonzero - `cast
// (bool)` and `if` share the one `Truth` rule (`nativelayout.d`'s own
// doc comment on `Truth.of`'s `Tcomplex*` case).
static foreach (backend; Matrix!()) {
    @("condition.floatingTruth.complex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cdouble zero = 0.0 + 0.0i;
                cdouble realOnly = 1.0 + 0.0i;
                cdouble imaginaryOnly = 0.0 + 1.0i;
                if (zero) assert(false);
                if (realOnly) {} else assert(false);
                if (imaginaryOnly) {} else assert(false);
            }
        });
    }
}


// `typeof(null)` has only ever the one value - always zero bits, so
// `if (x)` on it is always false, but it must still be a condition a
// backend can evaluate at all rather than reject outright.
static foreach (backend; Matrix!()) {
    @("condition.nullTypeIsAlwaysFalse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                typeof(null) x;
                if (x) assert(false);
                assert(!cast(bool) x);
            }
        });
    }
}


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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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


static foreach (backend; Matrix!()) {
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


static foreach (backend; Matrix!()) {
    @("tryFinally.nestedThrowRunsCleanupOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        123.shouldBeRetOf!(backend, q{
            int result() {
                int trace;
                try {
                    try {
                        try {
                            throw new Exception("body");
                        } finally {
                            trace = trace * 10 + 1;
                        }
                    } finally {
                        trace = trace * 10 + 2;
                        throw new Exception("cleanup");
                    }
                } catch (Exception e) {
                    trace = trace * 10 + 3;
                }
                return trace;
            }
        }, "result");
    }
}


static foreach (backend; Matrix!()) {
    @("tryFinally.loopExitsKeepEnclosingCleanupPending." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        112.shouldBeRetOf!(backend, q{
            int result() {
                int trace;
                try {
                    outer: for (int i; i < 2; ++i) {
                        try {
                            for (int j; j < 2; ++j) {
                                if (j == 0)
                                    continue;
                                break;
                            }
                            continue outer;
                        } finally {
                            trace = trace * 10 + 1;
                        }
                    }
                } finally {
                    trace = trace * 10 + 2;
                }
                return trace;
            }
        }, "result");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "a goto inside finally returns 0 instead of running cleanup"),
)) {
    @("tryFinally.gotoWithinCleanupRunsOnBothExits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        22.shouldBeRetOf!(backend, q{
            int cleanup(bool fail) {
                int trace;
                try {
                    try {
                        if (fail)
                            throw new Exception("body");
                    } finally {
                        goto done;
                        trace = 9;
                    done:
                        trace += 2;
                    }
                } catch (Exception e) {
                }
                return trace;
            }

            int result() {
                return cleanup(false) * 10 + cleanup(true);
            }
        }, "result");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "a goto inside finally returns 0 instead of running cleanup"),
)) {
    @("tryFinally.forwardGotoInEachCleanupCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        22.shouldBeRetOf!(backend, q{
            int result() {
                int trace;
                for (int i; i < 2; ++i) {
                    try {
                        if (i == 99) break;
                    } finally {
                        goto done;
                        trace = 9;
                    done:
                        trace = trace * 10 + 2;
                    }
                }
                return trace;
            }
        }, "result");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "backward goto in cleanup is not supported by CTFE"),
)) {
    @("tryFinally.backwardGotoInCleanupRunsOnBothExits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        22.shouldBeRetOf!(backend, q{
            int cleanup(bool fail) {
                int count;
                try {
                    try {
                        if (fail)
                            throw new Exception("body");
                    } finally {
                    again:
                        ++count;
                        if (count < 2)
                            goto again;
                    }
                } catch (Exception) {
                }
                return count;
            }

            int result() {
                return cleanup(false) * 10 + cleanup(true);
            }
        }, "result");
    }
}


static foreach (backend; Matrix!()) {
    @("tryFinally.throwingCleanupPreservesOriginalException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(backend, q{
            bool result() {
                auto original = new Exception("body");
                auto cleanup = new Exception("cleanup");
                try {
                    try {
                        throw original;
                    } finally {
                        throw cleanup;
                    }
                } catch (Exception e) {
                    return e is original;
                }
                return false;
            }
        }, "result");
    }
}


static foreach (backend; Matrix!()) {
    @("tryFinally.throwingCleanupChainsExceptions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum code = q{
            Throwable[] caughtExceptions() {
                auto original = new Exception("body");
                auto cleanup = new Exception("cleanup");
                try {
                    try {
                        throw original;
                    } finally {
                        throw cleanup;
                    }
                } catch (Exception e) {
                    return [e, original, cleanup];
                }
                return null;
            }
            bool result() {
                auto values = caughtExceptions();
                return values.length == 3 && values[0] is values[1]
                    && values[0].next is values[2];
            }
        };
        static if (is(backend == Native) || is(backend == Ctfe))
            true.shouldBeRetOf!(backend, code, "result");
        else {
            auto module_ = parseSnippet(code);
            auto backend_ = Owned!backend(Program([module_]));
            Throwable[] values;
            backend_.call(findFunction(module_, "caughtExceptions"), &values, []);
            values.length.should == 3;
            (values[0] is values[1]).should == true;
            (values[0].next is values[2]).should == true;
        }
    }
}

static foreach (backend; Matrix!()) {
    @("tryFinally.cleanupErrorReplacesBodyException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            bool result() {
                try {
                    try {
                        throw new Exception("body");
                    } finally {
                        throw new AssertError("cleanup");
                    }
                } catch (AssertError) {
                    return true;
                } catch (Exception) {
                    return false;
                }
                return false;
            }
        }, "result");
    }
}


// A `scope(exit)` before a `return` and a `scope(failure)` after it, in one
// function.
static foreach (backend; Matrix!()) {
    @("tryFinally.scopeExitThenReturnThenScopeFailure." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        51.shouldBeRetOf!(backend, q{
            int result(ref int trace, bool early) {
                scope(exit) trace += 1;
                if (early)
                    return 5;
                scope(failure) trace += 10;
                return 6;
            }

            int check() {
                int trace;
                const returned = result(trace, true);
                return returned * 10 + trace;
            }
        }, "check");
    }
}


// A `finally` that throws replaces the value a `return` in its `try` body
// carried out.
static foreach (backend; Matrix!()) {
    @("tryFinally.finallyThrowsAfterReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            int inner() {
                try {
                    return 1;
                } finally {
                    throw new Exception("from finally");
                }
            }

            int check() {
                try {
                    return inner();
                } catch (Exception e) {
                    return 42;
                }
            }
        }, "check");
    }
}


// A `throw` caught inside the `try` body does not count as an exit of the
// `finally`'s statement.
static foreach (backend; Matrix!()) {
    @("tryFinally.caughtThrowInBodyThenReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        31.shouldBeRetOf!(backend, q{
            int result(ref int trace) {
                try {
                    try {
                        throw new Exception("inner");
                    } catch (Exception e) {
                        return 3;
                    }
                } finally {
                    ++trace;
                }
            }

            int check() {
                int trace;
                const returned = result(trace);
                return returned * 10 + trace;
            }
        }, "check");
    }
}


// `break`s of a `switch` inside a `finally`, one of them in an `if` with no
// `else`.
static foreach (backend; Matrix!()) {
    @("tryFinally.switchBreakInFinallyIfWithoutElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        21.shouldBeRetOf!(backend, q{
            int result() {
                int n;
                for (int i; i < 2; ++i) {
                    try {
                        n += 10;
                    } finally {
                        switch (i) {
                            case 0:
                                if (n > 0)
                                    break;
                                n += 100;
                                break;
                            default:
                                n += 1;
                        }
                    }
                }
                return n;
            }
        }, "result");
    }
}


// A `scope(exit)` guard runs on a normal return from a function with an
// `out` contract.
static foreach (backend; Matrix!()) {
    @("scopeGuard.exitRunsOnReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int fine() { log ~= "fine,"; return 3; }
                int f() out (r; r > 0) {
                    scope(exit) log ~= "E,";
                    return fine();
                }
                if (f() != 3) return 2;
                return log == "fine,E," ? 0 : log == "fine," ? 3 : 5;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("scopeGuard.successRunsOnReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int fine() { log ~= "fine,"; return 3; }
                int f() out (r; r > 0) {
                    scope(success) log ~= "S,";
                    return fine();
                }
                if (f() != 3) return 2;
                return log == "fine,S," ? 0 : log == "fine," ? 3 : 5;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("scopeGuard.exitRunsOnReturnWithInvariant." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                string log;
                int x = 1;
                invariant { assert(x > 0); }
                int fine() { log ~= "fine,"; return 3; }
                int f() {
                    scope(exit) log ~= "E,";
                    return fine();
                }
            }

            int main() {
                auto c = new C;
                if (c.f() != 3) return 2;
                return c.log == "fine,E," ? 0 : c.log == "fine," ? 3 : 5;
            }
        });
    }
}


// The `out` contract runs after a `scope(exit)` guard of a `void` function.
static foreach (backend; Matrix!()) {
    @("scopeGuard.exitRunsOnVoidReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                void f() out { log ~= "O,"; } do {
                    scope(exit) log ~= "E,";
                    log ~= "b,";
                }
                f();
                return log == "b,E,O," ? 0 : 3;
            }
        });
    }
}

// A `return` inside a nested block runs the guard once.
static foreach (backend; Matrix!()) {
    @("scopeGuard.exitRunsOnNestedReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int f(bool c) out (r; r > 0) {
                    scope(exit) log ~= "E,";
                    if (c) {
                        { return 3; }
                    }
                    return 4;
                }
                if (f(true) != 3) return 2;
                return log == "E," ? 0 : 3;
            }
        });
    }
}

// A `scope(failure)` guard stays silent on a normal return.
static foreach (backend; Matrix!()) {
    @("scopeGuard.failureSkippedOnReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int f() out (r; r > 0) {
                    scope(failure) log ~= "F,";
                    scope(exit) log ~= "E,";
                    return 3;
                }
                if (f() != 3) return 2;
                return log == "E," ? 0 : 3;
            }
        });
    }
}

// A `finally` runs on a normal return in a function with an `out` contract.
static foreach (backend; Matrix!()) {
    @("finally.runsOnReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int f() out (r; r > 0) {
                    try {
                        return 3;
                    } finally {
                        log ~= "F,";
                    }
                }
                if (f() != 3) return 2;
                return log == "F," ? 0 : 3;
            }
        });
    }
}

// A local's destructor runs on a normal return in a function with an `out` contract.
static foreach (backend; Matrix!()) {
    @("destructor.localRunsOnReturnWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                struct S { string* log; ~this() { *log ~= "D,"; } }
                int f() out (r; r > 0) {
                    S s = S(&log);
                    return 3;
                }
                if (f() != 3) return 2;
                return log == "D," ? 0 : 3;
            }
        });
    }
}

// Several guards run in reverse order before the return.
static foreach (backend; Matrix!()) {
    @("scopeGuard.exitOrderWithOutContract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                string log;
                int f() out (r; r > 0) {
                    scope(exit) log ~= "1,";
                    scope(exit) log ~= "2,";
                    return 3;
                }
                if (f() != 3) return 2;
                return log == "2,1," ? 0 : 3;
            }
        });
    }
}

// A virtual method that fails an `assert`: the `AssertError` reaches the
// caller's `catch`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("virtualMethodAssertReachesCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            class Counter {
                int value;
                void bump() {
                    assert(value >= 0);
                    value += 1;
                }
            }

            int result() {
                auto counter = new Counter;
                counter.value = -1;
                try {
                    counter.bump();
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}

// A value parameter's destructor runs once at the function end, however a `goto` moves within the body.
static foreach (backend; Matrix!()) {
    @("tryFinally.userGotoRunsParameterDestructorOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int* count; ~this() { ++*count; } }
            int loop(S s) {
                int i;
            again:
                if (++i < 3) goto again;
                return i;
            }
            int main() {
                int count;
                const r = loop(S(&count));
                if (r != 3) return 1;
                return count == 1 ? 0 : 10 + count;
            }
        });
    }
}

// An `out` contract makes dmd send `return` through a label; the value parameter's destructor still runs once.
static foreach (backend; Matrix!()) {
    @("tryFinally.returnWithOutContractRunsParameterDestructorOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int* count; ~this() { ++*count; } }
            int f(S s) out (r; r > 0) { return 3; }
            int main() {
                int count;
                if (f(S(&count)) != 3) return 1;
                return count == 1 ? 0 : 10 + count;
            }
        });
    }
}

// An invariant makes dmd send `return` through a label; the value parameter's destructor still runs once.
static foreach (backend; Matrix!()) {
    @("tryFinally.returnWithInvariantRunsParameterDestructorOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int* count; ~this() { ++*count; } }
            class C {
                int x = 1;
                invariant { assert(x > 0); }
                int f(S s) { return 3; }
            }
            int main() {
                int count;
                auto c = new C;
                if (c.f(S(&count)) != 3) return 1;
                return count == 1 ? 0 : 10 + count;
            }
        });
    }
}

// dmd replaces the cleanup of a returned local (NRVO) after it resolves jumps; a `goto` in its scope must not run that destructor.
static foreach (backend; Matrix!()) {
    @("tryFinally.userGotoInNrvoScope." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int* count; int v; ~this() { ++*count; } }
            S make(int* count) {
                S s = S(count);
                int i;
            again:
                if (++i < 3) goto again;
                s.v = i;
                return s;
            }
            int main() {
                int count;
                {
                    auto s = make(&count);
                    if (s.v != 3) return 1;
                    if (count != 0) return 10 + count;
                }
                return count == 1 ? 0 : 20 + count;
            }
        });
    }
}

// `goto case` and `goto default` do not run a value parameter's destructor early.
static foreach (backend; Matrix!()) {
    @("tryFinally.gotoCaseRunsParameterDestructorOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int* count; ~this() { ++*count; } }
            int pick(S s, int v) {
                switch (v) {
                    case 0: goto case 1;
                    case 1: return 5;
                    case 2: goto default;
                    default: return 9;
                }
            }
            int main() {
                int count;
                if (pick(S(&count), 0) != 5) return 1;
                if (count != 1) return 10 + count;
                if (pick(S(&count), 2) != 9) return 2;
                return count == 2 ? 0 : 20 + count;
            }
        });
    }
}

// `goto case` in the scope of a returned local (NRVO) must not run that local's destructor.
static foreach (backend; Matrix!()) {
    @("tryFinally.gotoCaseInNrvoScope." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int* count; int v; ~this() { ++*count; } }
            S make(int* count, int k) {
                S s = S(count);
                switch (k) {
                    case 0: goto case 1;
                    case 1: s.v = 5; break;
                    default: s.v = 9;
                }
                return s;
            }
            int main() {
                int count;
                {
                    auto s = make(&count, 0);
                    if (s.v != 5) return 1;
                    if (count != 0) return 10 + count;
                }
                return count == 1 ? 0 : 20 + count;
            }
        });
    }
}
