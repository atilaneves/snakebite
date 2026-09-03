module ut.backends.call.cast_;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("cast.staticArrayToSliceAliasesStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        24.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] storage = void;
                    int[] first = cast(int[]) storage;
                    first[0] = 4;
                    int[] second = cast(int[]) storage;
                    return cast(int) second.length * 10 + second[0];
                }
            },
            "result",
        );
    }
}


// `5_000_000_000` needs 33 bits, so its low 32 bits - what `cast(int)`
// keeps - differ from the value itself. An implementation that clamps or
// saturates instead of truncating fails this.
static foreach (backend; Matrix!()) {
    @("cast.narrowing.truncates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        705_032_704.shouldBeRetOf!(
            backend,
            q{
                long big() {
                    return 5_000_000_000L;
                }

                int narrowed() {
                    return cast(int) big();
                }
            },
            "narrowed",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.floatToDouble.widensValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5.shouldBeRetOf!(
            backend,
            q{
                float source() {
                    return 1.5f;
                }

                double widened() {
                    return cast(double) source();
                }
            },
            "widened",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.doubleToFloat.roundsValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        16_777_216.0f.shouldBeRetOf!(
            backend,
            q{
                double source() {
                    return 16_777_217.0;
                }

                float narrowed() {
                    return cast(float) source();
                }
            },
            "narrowed",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("cast.floatToIntegral.truncatesTowardZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-3L).shouldBeRetOf!(
            backend,
            q{
                double source() {
                    return -3.75;
                }

                long truncated() {
                    return cast(long) source();
                }
            },
            "truncated",
        );
    }
}

// Widening a signed operand copies its sign bit into the new high bits, so
// `cast(long)` of a negative `int` stays negative. An implementation that
// zero-extends instead answers a large positive value.
static foreach (backend; Matrix!()) {
    @("cast.widening.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-5L).shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -5;
                }

                long widened() {
                    return cast(long) negative();
                }
            },
            "widened",
        );
    }
}

// Widening an unsigned operand fills the new high bits with zero, so
// `cast(long)` of `uint.max` is the same positive value, not -1. An
// implementation that sign-extends instead answers -1.
static foreach (backend; Matrix!()) {
    @("cast.widening.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4_294_967_295L.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                long widened() {
                    return cast(long) top();
                }
            },
            "widened",
        );
    }
}

// The shape the array code needs: a `size_t` (the array's own length,
// 8 bytes) narrowed to an `int` (4 bytes). The string literal isolates the
// cast from array support, which is exercised on its own elsewhere.
static foreach (backend; Matrix!()) {
    @("cast.narrowLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                string greeting() {
                    return "hello";
                }

                int length_() {
                    return cast(int) greeting().length;
                }
            },
            "length_",
        );
    }
}

// `cast(void[])` of a `T[]` scales the length by `T.sizeof`, the same
// conversion `core.internal.array.appending` applies before calling
// `gc_expandArrayUsed`/`gc_shrinkArrayUsed`, both of which take `void[]`.
// `int.sizeof` (4) isolates the scaling from a verbatim `{length, ptr}`
// copy: a 1-byte element would leave the length unchanged and the two
// implementations indistinguishable.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE keeps a `cast(void[])` array's length as an " ~
        "element count, not a byte count - pinned below"),
)) {
    @("cast.arrayToVoid.scalesLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(12).shouldBeRetOf!(
            backend,
            q{
                int[] ints() {
                    return [1, 2, 3];
                }

                size_t voidLength() {
                    void[] bytes = cast(void[]) ints();
                    return bytes.length;
                }
            },
            "voidLength",
        );
    }
}

// dmd's own CTFE does not scale the length through a `cast(void[])` the
// way runtime D does - pins the divergence; the native side (checked
// above for every other backend) scales it.
@("cast.arrayToVoid.scalesLength.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    size_t(3).shouldBeRetOf!(
        Ctfe,
        q{
            int[] ints() {
                return [1, 2, 3];
            }

            size_t voidLength() {
                void[] bytes = cast(void[]) ints();
                return bytes.length;
            }
        },
        "voidLength",
    );
}

// `16_777_217` is `2^24 + 1`, the first integer a `float`'s 24-bit
// significand cannot hold, so D's integral-to-floating conversion rounds
// it to the nearest representable value, `16_777_216`. The operand comes
// from a function call because dmd folds a cast of a literal during
// semantic analysis, so a literal operand would never reach a backend. An
// implementation that converts through a wider intermediate and rounds
// once more, or that reinterprets the operand's bits, fails this.
static foreach (backend; Matrix!()) {
    @("cast.ulongToFloat.roundsToFloatPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        16_777_216.0f.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 16_777_217UL;
                }

                float converted() {
                    return cast(float) bits();
                }
            },
            "converted",
        );
    }
}

// The same operand as the `float` test above: a `double`'s 53-bit
// significand holds `2^24 + 1` exactly, so the conversion is exact. An
// implementation that converts every floating destination at `float`
// precision fails this while passing the `float` test.
static foreach (backend; Matrix!()) {
    @("cast.ulongToDouble.isExact." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        16_777_217.0.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 16_777_217UL;
                }

                double converted() {
                    return cast(double) bits();
                }
            },
            "converted",
        );
    }
}

// A runtime `ulong` reduced by `%`, converted to `float`, then divided
// and offset: dmd's usual arithmetic conversions turn `1_000_000` and `1`
// into `float` operands, so after the cast every operation is
// floating-point. `3_500_001 % 2_000_001` is `1_500_000`, and
// `1.5 - 1.0` is exact at every precision, so the expectation does not
// depend on rounding. The operand comes from a function call because dmd
// folds literal-only arithmetic during semantic analysis.
static foreach (backend; Matrix!()) {
    @("cast.ulongToFloat.thenDivideAndSubtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.5f.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 3_500_001UL;
                }

                float value() {
                    return cast(float) (bits() % 2_000_001) / 1_000_000 - 1;
                }
            },
            "value",
        );
    }
}

// As above, with a `double` destination: the conversions of `1_000_000`
// and `1` follow the cast's own type, so the whole chain runs at `double`
// precision instead.
static foreach (backend; Matrix!()) {
    @("cast.ulongToDouble.thenDivideAndSubtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.5.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 3_500_001UL;
                }

                double value() {
                    return cast(double) (bits() % 2_000_001) / 1_000_000 - 1;
                }
            },
            "value",
        );
    }
}

// The bytecode compiler's own type switch recognises only `float` and
// `double` as floating types - `real` has no case there at all, so a
// program using it cannot be compiled for that backend.
private alias RealOmit = Omit!(Bytecode, Because.unconfirmed,
    "the bytecode compiler recognises only `float`/`double` as floating "
        ~ "types, not `real`");

// `real` widening to `double`: exact, since `double` is narrower than
// `real` but the operand here fits in both. The operand comes from a
// call because dmd folds a cast of a literal during semantic analysis.
static foreach (backend; Matrix!(RealOmit)) {
    @("cast.realToDouble." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5.shouldBeRetOf!(
            backend,
            q{
                real value() {
                    return 1.5L;
                }

                double converted() {
                    return cast(double) value();
                }
            },
            "converted",
        );
    }
}

// `real` narrowing to `float`, and back again to `real`. `1.5` is exact
// at every one of the three widths, so the round trip does not depend on
// rounding.
static foreach (backend; Matrix!(RealOmit)) {
    @("cast.realToFloat." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5f.shouldBeRetOf!(
            backend,
            q{
                real value() {
                    return 1.5L;
                }

                float converted() {
                    return cast(float) value();
                }
            },
            "converted",
        );
    }
}

static foreach (backend; Matrix!(RealOmit)) {
    @("cast.doubleToReal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5L.shouldBeRetOf!(
            backend,
            q{
                double value() {
                    return 1.5;
                }

                real converted() {
                    return cast(real) value();
                }
            },
            "converted",
        );
    }
}

static foreach (backend; Matrix!(RealOmit)) {
    @("cast.floatToReal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5L.shouldBeRetOf!(
            backend,
            q{
                float value() {
                    return 1.5f;
                }

                real converted() {
                    return cast(real) value();
                }
            },
            "converted",
        );
    }
}

// dmd classifies `bool` as `integral | unsigned`, so a naive integral
// narrowing takes the operand's low byte instead of comparing it against
// zero. `256`'s low byte is `0`, which a truncating implementation would
// store as `false` - D specifies `cast(bool) 256` as `true`.
static foreach (backend; Matrix!()) {
    @("cast.bool.nonZeroIsTrue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int wide() {
                    return 256;
                }

                bool truthy() {
                    return cast(bool) wide();
                }
            },
            "truthy",
        );
    }
}
