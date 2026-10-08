module ut.backends.eval.expressions.arithmetic;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


static foreach (backend; Matrix!()) {
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


// Complement of an unsigned operand keeps the unsigned type.
static foreach (backend; Matrix!()) {
    @("int.unsignedComplementStaysUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "~0UL").should == "18446744073709551615";
        eval!(backend, "~0UL > 0").should == "true";
    }
}


// An `int` operand converts to `uint` before the operation, so the result
// is unsigned division, not division of the bit pattern as a negative int.
static foreach (backend; Matrix!()) {
    @("int.unsignedDivisionAndModulo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "4_000_000_000u / 3").should == "1333333333";
        eval!(backend, "4_000_000_000u / 3u").should == "1333333333";
        eval!(backend, "4_000_000_000u % 3").should == "1";
    }
}

// Signed division truncates toward zero, whichever operand is negative.
static foreach (backend; Matrix!()) {
    @("long.divisionTruncatesTowardZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, "-1_000_000_000_000L / 7L").should == "-142857142857";
        eval!(backend, "1_000_000_000_000L / 7L").should == "142857142857";
        eval!(backend, "1_000_000_000_000L / -7L").should == "-142857142857";
        eval!(backend, "-1_000_000_000_000L / -7L").should == "142857142857";
    }
}


static foreach (backend; Matrix!()) {
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
    auto module_ = parseSnippet(q{
        int big() { return 16_777_217; }
        string __eval() {
            import std.conv: text;
            return text(cast(int) cast(float) big);
        }
    });

    (new Ctfe(Program([module_])))
        .eval(findFunction(module_, "__eval")).should == "16777217";
}

// With a literal on each side DMD folds the expression before any backend
// sees it; an operand behind a function call makes the backend do the work.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("nullStringResult." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, q{cast(string) null}).should == "";
    }
}
