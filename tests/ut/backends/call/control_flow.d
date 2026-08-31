module ut.backends.call.control_flow;


import ut.backends;


static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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
