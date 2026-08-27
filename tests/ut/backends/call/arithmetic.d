module ut.backends.call.arithmetic;


import ut.backends;


// Every operand here is behind a call so that dmd cannot fold the
// expression before a backend runs it.
static foreach (backend; Matrix!()) {
    @("arithmetic.add." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        13.shouldBeRetOf!(
            backend,
            q{
                int six() {
                    return 6;
                }

                int seven() {
                    return 7;
                }

                int result() {
                    return six() + seven();
                }
            },
            "result",
        );
    }
}

// Subtraction the way round that a backend adding instead would get wrong,
// and that a backend swapping the operands would get wrong too.
static foreach (backend; Matrix!()) {
    @("arithmetic.subtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int six() {
                    return 6;
                }

                int seven() {
                    return 7;
                }

                int result() {
                    return seven() - six();
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.multiply." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int six() {
                    return 6;
                }

                int seven() {
                    return 7;
                }

                int result() {
                    return six() * seven();
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.bitwise." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0x2a.shouldBeRetOf!(
            backend,
            q{
                int mask() {
                    return 0x3a;
                }

                int bits() {
                    return 0x2f;
                }

                int result() {
                    return bits() & mask();
                }
            },
            "result",
        );
        0x2e.shouldBeRetOf!(
            backend,
            q{
                int mask() {
                    return 0x2a;
                }

                int bits() {
                    return 0x06;
                }

                int result() {
                    return bits() | mask();
                }
            },
            "result",
        );
        0x2a.shouldBeRetOf!(
            backend,
            q{
                int mask() {
                    return 0x04;
                }

                int bits() {
                    return 0x2e;
                }

                int result() {
                    return bits() ^ mask();
                }
            },
            "result",
        );
    }
}

// `int.max + 1` wraps to `int.min`: the result is truncated to the
// destination's own width, not left as the wider value the operands were
// widened to.
static foreach (backend; Matrix!()) {
    @("arithmetic.wrapsToDestinationWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int.min.shouldBeRetOf!(
            backend,
            q{
                int top() {
                    return int.max;
                }

                int one() {
                    return 1;
                }

                int result() {
                    return top() + one();
                }
            },
            "result",
        );
    }
}

// `0u - 1` is `uint.max`, not -1: the same bits either way, read back as
// the unsigned type the expression has.
static foreach (backend; Matrix!()) {
    @("arithmetic.unsignedWraps." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint.max.shouldBeRetOf!(
            backend,
            q{
                uint zero() {
                    return 0u;
                }

                uint one() {
                    return 1u;
                }

                uint result() {
                    return zero() - one();
                }
            },
            "result",
        );
    }
}

// `long` operands are wider than the `int` ones above, so a backend that
// truncated everything to 32 bits would disagree here.
static foreach (backend; Matrix!()) {
    @("arithmetic.long." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6_000_000_000L.shouldBeRetOf!(
            backend,
            q{
                long big() {
                    return 3_000_000_000L;
                }

                long two() {
                    return 2L;
                }

                long result() {
                    return big() * two();
                }
            },
            "result",
        );
    }
}

// The interpreter answers the six operators whose result bits are the same
// whether the operands are read as signed or unsigned, and refuses the rest
// so that a missing one is a refusal rather than a wrong answer. Compiled D
// answers them all, which is why these are pinned for the interpreter
// alone.
@("arithmetic.divide.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int six() { return 6; }
        int two() { return 2; }
        int result() { return six() / two(); }
    });
    auto function_ = findFunction(module_, "result");

    int result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}

@("arithmetic.modulo.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int six() { return 6; }
        int two() { return 2; }
        int result() { return six() % two(); }
    });
    auto function_ = findFunction(module_, "result");

    int result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}

@("arithmetic.shift.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int six() { return 6; }
        int two() { return 2; }
        int result() { return six() >> two(); }
    });
    auto function_ = findFunction(module_, "result");

    int result;
    (new Interpreter).call(function_, &result, [])
        .shouldThrow;
}
