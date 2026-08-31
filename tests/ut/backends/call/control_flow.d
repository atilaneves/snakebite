module ut.backends.call.control_flow;


import ut.backends;


@("tryFinally.scopeExitRuns.Interpreter")
@Tags("Interpreter")
unittest {
    3.shouldBeRetOf!(
        Interpreter,
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


@("tryFinally.scopeExitRunsDuringReturnAndThrow.Interpreter")
@Tags("Interpreter")
unittest {
    23.shouldBeRetOf!(
        Interpreter,
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


@("tryFinally.scopeExitRunsDuringContinue.Interpreter")
@Tags("Interpreter")
unittest {
    3.shouldBeRetOf!(
        Interpreter,
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


@("unrolledLoop.staticForeachRunsInOrder.Interpreter")
@Tags("Interpreter")
unittest {
    123.shouldBeRetOf!(
        Interpreter,
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
