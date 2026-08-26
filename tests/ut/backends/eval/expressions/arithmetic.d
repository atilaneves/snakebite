module ut.backends.eval.expressions.arithmetic;


import ut.backends;

mixin SnippetTests;


// `eval` is not implemented for the interpreter yet, so every test in this
// file omits it the same way.
private alias OmitInterpreterEval =
    Omit!(Interpreter, Because.unconfirmed, "eval not implemented yet");


static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.operators." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "2 + 3").should == "5";
        eval!(backend, "44 - 2").should == "42";
        eval!(backend, "2 * 3").should == "6";
        eval!(backend, "84 / 2").should == "42";
        eval!(backend, "86 % 44").should == "42";
    }
}

// The sign of `%` follows the dividend, not the divisor.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.moduloSignFollowsDividend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "-7 % 3").should == "-1";
        eval!(backend, "7 % -3").should == "1";
        eval!(backend, "-7 % -3").should == "-1";
    }
}

// `>>` sign-extends, `>>>` zero-fills.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.shifts." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "0x80 >> 2").should == "32";
        eval!(backend, "0x10 << 1").should == "32";
        eval!(backend, "-1 >> 28").should == "-1";
        eval!(backend, "-1 >>> 28").should == "15";
    }
}

static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.bitwise." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "0x2a | 0x06").should == "46";
        eval!(backend, "0x2f & 0x3a").should == "42";
        eval!(backend, "0x2e ^ 0x04").should == "42";
        eval!(backend, "~0x2a").should == "-43";
        eval!(backend, "-42").should == "-42";
    }
}

// Complement of an unsigned operand keeps the unsigned type.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.unsignedComplementStaysUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "~0UL").should == "18446744073709551615";
        eval!(backend, "~0UL > 0").should == "true";
    }
}

static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.relational." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "41 < 42").should == "true";
        eval!(backend, "42 <= 42").should == "true";
        eval!(backend, "43 > 42").should == "true";
        eval!(backend, "42 >= 42").should == "true";
        eval!(backend, "43 != 42").should == "true";
        eval!(backend, "42 == 42").should == "true";
        eval!(backend, "42 < 41").should == "false";
    }
}

// An `int` operand converts to `uint` before the operation, so the result
// is unsigned division, not division of the bit pattern as a negative int.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.unsignedDivisionAndModulo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "4_000_000_000u / 3").should == "1333333333";
        eval!(backend, "4_000_000_000u / 3u").should == "1333333333";
        eval!(backend, "4_000_000_000u % 3").should == "1";
    }
}

// Signed division truncates toward zero, whichever operand is negative.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("long.divisionTruncatesTowardZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "-1_000_000_000_000L / 7L").should == "-142857142857";
        eval!(backend, "1_000_000_000_000L / 7L").should == "142857142857";
        eval!(backend, "1_000_000_000_000L / -7L").should == "-142857142857";
        eval!(backend, "-1_000_000_000_000L / -7L").should == "142857142857";
    }
}

// Narrowing truncates; widening a negative signed value sign-extends and
// widening an unsigned value zero-extends.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.casts." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "cast(ubyte) 300").should == "44";
        eval!(backend, "cast(short) cast(byte) -5").should == "-5";
        eval!(backend, "cast(ushort) 0x34 | cast(ushort) 0x12 << 8")
            .should == "4660";
    }
}

// Character and boolean operands promote to integers.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.integerLikeOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "cast(char) 65 + 1").should == "66";
        eval!(backend, "true + 1").should == "2";
    }
}

static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("float.operators." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "1.5f + 2.25f").should == "3.75";
        eval!(backend, "2.0 ^^ 10").should == "1024";
        eval!(backend, "cast(int) 3.7").should == "3";
    }
}

// Widening `int` to `float` rounds to float precision. With a literal
// operand DMD folds the cast at `real` precision, so the operand comes from
// a function call.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "CTFE keeps `cast(float)` at real precision"),
    OmitInterpreterEval,
)) {
    @("float.intToFloatUsesFloatPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(
            backend,
            q{ int big() { return 16_777_217; } },
            q{ cast(int) cast(float) big },
        ).should == "16777216";
    }
}

// dmd's CTFE does not round through `cast(float)`, so the guest keeps the
// bit that float precision loses. Pins the divergence; the native side
// (checked above for every other backend) rounds.
@("float.intToFloatUsesFloatPrecision.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int big() { return 16_777_217; }
        string __eval() {
            import std.conv: text;
            return text(cast(int) cast(float) big);
        }
    });

    (new Ctfe).eval(findFunction(module_, "__eval")).should == "16777217";
}

// With a literal on each side DMD folds the expression before any backend
// sees it; an operand behind a function call makes the backend do the work.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.runtimeShapedOperators." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, q{ int one() { return 1; } }, q{ one + 41 })
            .should == "42";
        eval!(backend, q{ int two() { return 2; } }, q{ 44 - two })
            .should == "42";
        eval!(backend, q{ int two() { return 2; } }, q{ 21 * two })
            .should == "42";
        eval!(backend, q{ int two() { return 2; } }, q{ 84 / two })
            .should == "42";
        eval!(backend, q{ int divisor() { return 44; } }, q{ 86 % divisor })
            .should == "42";
    }
}

// The signed operand converts to `uint`, so -1 compares as `uint.max`.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.signedUnsignedComparisonIsUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(
            backend,
            q{ int neg() { return -1; } uint zero() { return 0u; } },
            q{ neg < zero },
        ).should == "false";
    }
}

static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.wraparound." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, q{ int top() { return int.max; } }, q{ top + 1 })
            .should == "-2147483648";
        eval!(backend, q{ uint bottom() { return 0u; } }, q{ bottom - 1 })
            .should == "4294967295";
    }
}

// The wrapped `uint` sum widens to `ulong` by zero-extension, not
// sign-extension.
static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.unsignedWrapThenWidenZeroExtends." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(
            backend,
            q{ uint high() { return 4_000_000_000u; } },
            q{ cast(ulong)(high + high) },
        ).should == "3705032704";
    }
}

static foreach (backend; Matrix!(OmitInterpreterEval)) {
    @("int.assignmentAndIncrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(
            backend,
            q{
                int answer() {
                    auto value = 0x28u;
                    value |= 0x02u;
                    return value;
                }
            },
            q{ answer },
        ).should == "42";
        eval!(
            backend,
            q{
                int answer() {
                    int value = 41;
                    const observed = value++;
                    return observed * 100 + value;
                }
            },
            q{ answer },
        ).should == "4142";
        eval!(
            backend,
            q{
                int answer() {
                    int value = 2;
                    value += 3, ++value;
                    return value;
                }
            },
            q{ answer },
        ).should == "6";
    }
}
