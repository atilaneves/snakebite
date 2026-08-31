module ut.backends.call.arithmetic;


import ut.backends;


// Every operand is a call so dmd cannot fold the arithmetic away before a
// backend ever runs it. The operands differ from each other and from the
// answer, so an implementation that returns one of them fails.
static foreach (backend; Matrix!()) {
    @("arithmetic.add." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int sum() {
                    return three() + four();
                }
            },
            "sum",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.subtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-1).shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int difference() {
                    return three() - four();
                }
            },
            "difference",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.multiply." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int product() {
                    return three() * four();
                }
            },
            "product",
        );
    }
}

// `uint` arithmetic wraps at its own width instead of answering with the
// wider value the host computed it in.
static foreach (backend; Matrix!()) {
    @("arithmetic.multiplyWrapsAtTargetWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (uint.max - 1).shouldBeRetOf!(
            backend,
            q{
                uint big() {
                    return uint.max;
                }

                uint two() {
                    return 2;
                }

                uint product() {
                    return big() * two();
                }
            },
            "product",
        );
    }
}

// Both answers of the condition are here: a ternary that always takes the
// same branch fails one of them.
static foreach (backend; Matrix!()) {
    @("arithmetic.ternary.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                bool yes() {
                    return true;
                }

                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int chosen() {
                    return yes() ? three() : four();
                }
            },
            "chosen",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.ternary.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4.shouldBeRetOf!(
            backend,
            q{
                bool no() {
                    return false;
                }

                int three() {
                    return 3;
                }

                int four() {
                    return 4;
                }

                int chosen() {
                    return no() ? three() : four();
                }
            },
            "chosen",
        );
    }
}


// `-7 / 2` is -3: D truncates toward zero rather than toward minus
// infinity, so an implementation that floors answers -4.
static foreach (backend; Matrix!()) {
    @("arithmetic.divide.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-3).shouldBeRetOf!(
            backend,
            q{
                int minusSeven() {
                    return -7;
                }

                int two() {
                    return 2;
                }

                int quotient() {
                    return minusSeven() / two();
                }
            },
            "quotient",
        );
    }
}

// `uint.max / 2u` is 2147483647. Read as two's complement the same bits are
// -1, and -1 / 2 is 0.
static foreach (backend; Matrix!()) {
    @("arithmetic.divide.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2147483647u.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint two() {
                    return 2u;
                }

                uint quotient() {
                    return top() / two();
                }
            },
            "quotient",
        );
    }
}

// `-7 % 2` is -1: D's remainder takes the sign of the dividend.
static foreach (backend; Matrix!()) {
    @("arithmetic.modulo.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-1).shouldBeRetOf!(
            backend,
            q{
                int minusSeven() {
                    return -7;
                }

                int two() {
                    return 2;
                }

                int remainder() {
                    return minusSeven() % two();
                }
            },
            "remainder",
        );
    }
}

// `uint.max % 7u` is 3. Read as two's complement the same bits are -1, and
// -1 % 7 is -1.
static foreach (backend; Matrix!()) {
    @("arithmetic.modulo.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3u.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint seven() {
                    return 7u;
                }

                uint remainder() {
                    return top() % seven();
                }
            },
            "remainder",
        );
    }
}

// A zero divisor has no answer in D, and the host's divide instruction
// raises SIGFPE on it - which would end the host process rather than the
// guest call. The interpreter reports it instead, naming the expression, so
// this is pinned for the interpreter alone: compiled D really does die.
@("arithmetic.divide.byZero.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int seven() { return 7; }
        int zero() { return 0; }
        int quotient() { return seven() / zero(); }
    });
    auto function_ = findFunction(module_, "quotient");

    int result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter: division by zero in `seven() / zero()`");
}

@("arithmetic.modulo.byZero.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int seven() { return 7; }
        int zero() { return 0; }
        int remainder() { return seven() % zero(); }
    });
    auto function_ = findFunction(module_, "remainder");

    int result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter: division by zero in `seven() % zero()`");
}

// The zero-divisor guard sits above the signedness question, so unsigned
// division and modulo are refused the same way. Without these, a guard
// moved below the unsigned path would still leave the signed pair passing
// while the host died on `uint / 0u`.
@("arithmetic.divide.byZero.unsigned.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        uint seven() { return 7u; }
        uint zero() { return 0u; }
        uint quotient() { return seven() / zero(); }
    });
    auto function_ = findFunction(module_, "quotient");

    uint result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter: division by zero in `seven() / zero()`");
}

@("arithmetic.modulo.byZero.unsigned.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        uint seven() { return 7u; }
        uint zero() { return 0u; }
        uint remainder() { return seven() % zero(); }
    });
    auto function_ = findFunction(module_, "remainder");

    uint result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter: division by zero in `seven() % zero()`");
}

// `long.min / -1L` has no representable quotient, and the host's divide
// instruction traps on it exactly as it does on a zero divisor. D's wrap
// answer is `long.min` itself, and the remainder is 0. Pinned for the
// interpreter alone because the native oracle really does die here.
@("arithmetic.divide.longMinByMinusOne.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        long lowest() { return long.min; }
        long negative() { return -1L; }
        long quotient() { return lowest() / negative(); }
        long remainder() { return lowest() % negative(); }
    });

    long quotient;
    interpreterOf(module_).call(findFunction(module_, "quotient"), &quotient, []);
    quotient.shouldEqual(long.min);

    long remainder;
    interpreterOf(module_).call(findFunction(module_, "remainder"), &remainder, []);
    remainder.shouldEqual(0);
}

static foreach (backend; Matrix!()) {
    @("arithmetic.bitwiseAnd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        8.shouldBeRetOf!(
            backend,
            q{
                int twelve() {
                    return 12;
                }

                int ten() {
                    return 10;
                }

                int masked() {
                    return twelve() & ten();
                }
            },
            "masked",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.bitwiseOr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        14.shouldBeRetOf!(
            backend,
            q{
                int twelve() {
                    return 12;
                }

                int ten() {
                    return 10;
                }

                int merged() {
                    return twelve() | ten();
                }
            },
            "merged",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.bitwiseXor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(
            backend,
            q{
                int twelve() {
                    return 12;
                }

                int ten() {
                    return 10;
                }

                int differing() {
                    return twelve() ^ ten();
                }
            },
            "differing",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.negate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-3).shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int negated() {
                    return -three();
                }
            },
            "negated",
        );
    }
}

// `~3` is -4: every bit flips, not just the sign.
static foreach (backend; Matrix!()) {
    @("arithmetic.complement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-4).shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int flipped() {
                    return ~three();
                }
            },
            "flipped",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.leftShift." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        24.shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int shift() {
                    return 3;
                }

                int shifted() {
                    return three() << shift();
                }
            },
            "shifted",
        );
    }
}

// `<<` keeps only the bits the destination holds: `uint`'s top bit shifted
// left leaves nothing behind, rather than the 33-bit value a wider
// intermediate would hold.
static foreach (backend; Matrix!()) {
    @("arithmetic.leftShiftWrapsAtTargetWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0u.shouldBeRetOf!(
            backend,
            q{
                uint topBit() {
                    return 0x8000_0000u;
                }

                int one() {
                    return 1;
                }

                uint shifted() {
                    return topBit() << one();
                }
            },
            "shifted",
        );
    }
}

// `>>` on a signed operand copies the sign bit down, so `-8 >> 1` is -4. A
// logical shift of the same bits answers 2147483644.
static foreach (backend; Matrix!()) {
    @("arithmetic.rightShift.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-4).shouldBeRetOf!(
            backend,
            q{
                int minusEight() {
                    return -8;
                }

                int one() {
                    return 1;
                }

                int shifted() {
                    return minusEight() >> one();
                }
            },
            "shifted",
        );
    }
}

// `>>` on an unsigned operand fills with zeros, so `uint.max >> 1` is
// 2147483647 rather than the `uint.max` an arithmetic shift of the same
// bits would leave.
static foreach (backend; Matrix!()) {
    @("arithmetic.rightShift.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2147483647u.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                int one() {
                    return 1;
                }

                uint shifted() {
                    return top() >> one();
                }
            },
            "shifted",
        );
    }
}

// `>>>` fills with zeros within the operand's own 32 bits even when the
// operand is signed, so `-8 >>> 1` is 2147483644. Filling from a
// sign-extended 64-bit intermediate would answer -4.
static foreach (backend; Matrix!()) {
    @("arithmetic.unsignedRightShift.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2147483644.shouldBeRetOf!(
            backend,
            q{
                int minusEight() {
                    return -8;
                }

                int one() {
                    return 1;
                }

                int shifted() {
                    return minusEight() >>> one();
                }
            },
            "shifted",
        );
    }
}

// A shift by the operand's own width or more is undefined in D, and the
// host's shift instruction answers it by taking the count modulo the
// register width - a plausible wrong answer. The interpreter refuses,
// naming the expression, so this is pinned for the interpreter alone.
@("arithmetic.leftShift.countTooLarge.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int one() { return 1; }
        int width() { return 32; }
        int shifted() { return one() << width(); }
    });
    auto function_ = findFunction(module_, "shifted");

    int result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot shift by 32 in `one() << width()`: " ~
            "the left operand has 32 bits");
}

@("arithmetic.rightShift.countNegative.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int one() { return 1; }
        int back() { return -1; }
        int shifted() { return one() >> back(); }
    });
    auto function_ = findFunction(module_, "shifted");

    int result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot shift by -1 in `one() >> back()`: " ~
            "the left operand has 32 bits");
}

// Every compound assignment, each reading the target once and writing the
// combined value back. The starting value and the operand differ from each
// other and from the answer, so an implementation that drops either side
// fails.
static foreach (backend; Matrix!()) {
    @("arithmetic.subtractAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int three() {
                    return 3;
                }

                int left() {
                    int total = ten();
                    total -= three();
                    return total;
                }
            },
            "left",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.multiplyAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        30.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int three() {
                    return 3;
                }

                int scaled() {
                    int total = ten();
                    total *= three();
                    return total;
                }
            },
            "scaled",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.divideAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int three() {
                    return 3;
                }

                int shrunk() {
                    int total = ten();
                    total /= three();
                    return total;
                }
            },
            "shrunk",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.moduloAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int three() {
                    return 3;
                }

                int left() {
                    int total = ten();
                    total %= three();
                    return total;
                }
            },
            "left",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.andAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        8.shouldBeRetOf!(
            backend,
            q{
                int twelve() {
                    return 12;
                }

                int ten() {
                    return 10;
                }

                int masked() {
                    int bits = twelve();
                    bits &= ten();
                    return bits;
                }
            },
            "masked",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.orAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        14.shouldBeRetOf!(
            backend,
            q{
                int twelve() {
                    return 12;
                }

                int ten() {
                    return 10;
                }

                int merged() {
                    int bits = twelve();
                    bits |= ten();
                    return bits;
                }
            },
            "merged",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.xorAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(
            backend,
            q{
                int twelve() {
                    return 12;
                }

                int ten() {
                    return 10;
                }

                int differing() {
                    int bits = twelve();
                    bits ^= ten();
                    return bits;
                }
            },
            "differing",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.leftShiftAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        24.shouldBeRetOf!(
            backend,
            q{
                int three() {
                    return 3;
                }

                int shift() {
                    return 3;
                }

                int shifted() {
                    int bits = three();
                    bits <<= shift();
                    return bits;
                }
            },
            "shifted",
        );
    }
}

// `>>=` on a signed target keeps the sign, and `>>>=` on the same bits does
// not, so the pair distinguishes the two.
static foreach (backend; Matrix!()) {
    @("arithmetic.rightShiftAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-4).shouldBeRetOf!(
            backend,
            q{
                int minusEight() {
                    return -8;
                }

                int one() {
                    return 1;
                }

                int shifted() {
                    int bits = minusEight();
                    bits >>= one();
                    return bits;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.unsignedRightShiftAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2147483644.shouldBeRetOf!(
            backend,
            q{
                int minusEight() {
                    return -8;
                }

                int one() {
                    return 1;
                }

                int shifted() {
                    int bits = minusEight();
                    bits >>>= one();
                    return bits;
                }
            },
            "shifted",
        );
    }
}

// dmd's integral promotions widen a target narrower than `int` before the
// operator is applied, so the left side arrives as `cast(int)b` rather than
// a variable and the interpreter refuses. Pinned so the boundary is
// deliberate: every compound assignment above works at 4 and 8 bytes only.
@("arithmetic.addAssign.narrowTarget.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        byte start() { return 100; }
        byte step() { return 100; }
        byte wrapped() {
            byte value = start();
            value += step();
            return value;
        }
    });
    auto function_ = findFunction(module_, "wrapped");

    byte result;
    interpreterOf(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot assign to `cast(int)value`: " ~
            "`cast(int)value += cast(int)step()`");
}

// dmd's semantic pass rewrites `--x` into `x -= 1`, so this pins the
// language behaviour rather than a node kind: the variable is one lower
// afterwards.
static foreach (backend; Matrix!()) {
    @("arithmetic.predecrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int lowered() {
                    int total = ten();
                    --total;
                    return total;
                }
            },
            "lowered",
        );
    }
}

// The postfix forms are their own node, and they yield what the variable
// held before the change - so the returned expression value and the
// variable's later value differ, and an implementation that yields the new
// value fails.
static foreach (backend; Matrix!()) {
    @("arithmetic.postdecrement.yieldsOldValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int before() {
                    int total = ten();
                    int seen = total--;
                    return seen;
                }
            },
            "before",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.postdecrement.changesVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int after() {
                    int total = ten();
                    total--;
                    return total;
                }
            },
            "after",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.postincrement.yieldsOldValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int before() {
                    int total = ten();
                    int seen = total++;
                    return seen;
                }
            },
            "before",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arithmetic.postincrement.changesVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int after() {
                    int total = ten();
                    total++;
                    return total;
                }
            },
            "after",
        );
    }
}

// The floating operators the conversion tests elsewhere do not cover:
// `+`, `*`, and `%`, which D defines over floating operands (`%` as the
// remainder of truncated division, like `fmod`). Every operand comes
// from a call so dmd cannot fold the arithmetic away, and every
// intermediate value - `7.5`, `3.5`, `6.5` - is exact in binary, so the
// expectation does not depend on rounding.
static foreach (backend; Matrix!()) {
    @("arithmetic.floating." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.5.shouldBeRetOf!(
            backend,
            q{
                double three() {
                    return 3.0;
                }

                double twoAndAHalf() {
                    return 2.5;
                }

                double four() {
                    return 4.0;
                }

                double combined() {
                    return three() * twoAndAHalf() % four() + three();
                }
            },
            "combined",
        );
    }
}
