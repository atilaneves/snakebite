module ut.backends.call.compare;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("compare.integralConditions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int signedBranches(long a, long b) {
                    int bits;
                    if (a < b) bits |= 1;
                    if (a <= b) bits |= 2;
                    if (a > b) bits |= 4;
                    if (a >= b) bits |= 8;
                    if (a == b) bits |= 16;
                    if (a != b) bits |= 32;
                    return bits;
                }

                int unsignedBranches(ulong a, ulong b) {
                    int bits;
                    if (a < b) bits |= 1;
                    if (a <= b) bits |= 2;
                    if (a > b) bits |= 4;
                    if (a >= b) bits |= 8;
                    if (a == b) bits |= 16;
                    if (a != b) bits |= 32;
                    return bits;
                }

                bool conditions() {
                    int sum;
                    for (int i = -3; i < 2; ++i) sum += i;
                    return sum == -5
                        && signedBranches(-1, 0) == 35
                        && signedBranches(0, -1) == 44
                        && signedBranches(-1, -1) == 26
                        && unsignedBranches(0, ulong.max) == 35
                        && unsignedBranches(ulong.max, 0) == 44
                        && unsignedBranches(ulong.max, ulong.max) == 26;
                }
            },
            "conditions",
        );
    }
}


// `1 < 2` is true and `2 < 1` is false. Both orderings are here so a
// comparison that always answers the same way fails one of them, and both
// operands are calls so the answer cannot be folded before a backend runs.
static foreach (backend; Matrix!()) {
    @("compare.lessThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool less() {
                    return small() < big();
                }
            },
            "less",
        );
    }
}

// Pointers into the same allocation have the array element order. Keep the
// four operators in one runtime expression so each pointer handler is
// exercised without relying on the addresses of separate locals.
static foreach (backend; Matrix!()) {
    @("compare.pointerOrdering." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool ordered() {
                    int[] values = [10, 20];
                    int* first = values.ptr;
                    int* second = values.ptr + 1;
                    return first < second
                        && first <= second
                        && second > first
                        && second >= first;
                }
            },
            "ordered",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.floatingOrdering." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                float lowFloat() {
                    return -1.5f;
                }

                float highFloat() {
                    return 2.5f;
                }

                double lowDouble() {
                    return -4.5;
                }

                double highDouble() {
                    return 3.5;
                }

                bool ordered() {
                    return lowFloat() < highFloat()
                        && lowFloat() <= highFloat()
                        && highFloat() > lowFloat()
                        && highFloat() >= lowFloat()
                        && lowDouble() < highDouble()
                        && highDouble() >= lowDouble();
                }
            },
            "ordered",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.lessThan.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool less() {
                    return big() < small();
                }
            },
            "less",
        );
    }
}

// `uint.max < 1u` is false. Read as two's complement the same bits are -1,
// which would make it true.
static foreach (backend; Matrix!()) {
    @("compare.lessThan.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint one() {
                    return 1u;
                }

                bool less() {
                    return top() < one();
                }
            },
            "less",
        );
    }
}

// The three orderings besides `<`. Each is pinned on both sides of its
// boundary and on the boundary itself, so an implementation that answers
// one of them with another - `<=` with `<`, say - fails the equal case.
static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notMore() {
                    return small() <= big();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool notMore() {
                    return one() <= uno();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notMore() {
                    return big() <= small();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool more() {
                    return big() > small();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterThan.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool more() {
                    return one() > uno();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterThan.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool more() {
                    return small() > big();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notLess() {
                    return big() >= small();
                }
            },
            "notLess",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool notLess() {
                    return one() >= uno();
                }
            },
            "notLess",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int small() {
                    return 1;
                }

                int big() {
                    return 2;
                }

                bool notLess() {
                    return small() >= big();
                }
            },
            "notLess",
        );
    }
}

// `uint.max > 1u` is true. Read as two's complement the same bits are -1,
// which would make it false.
static foreach (backend; Matrix!()) {
    @("compare.greaterThan.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint one() {
                    return 1u;
                }

                bool more() {
                    return top() > one();
                }
            },
            "more",
        );
    }
}

// `-1 >= 0` is false. Read as an unsigned bit pattern the same bits are
// `uint.max`, which would make it true.
static foreach (backend; Matrix!()) {
    @("compare.greaterOrEqual.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -1;
                }

                int zero() {
                    return 0;
                }

                bool notLess() {
                    return negative() >= zero();
                }
            },
            "notLess",
        );
    }
}

// `uint.max <= 1u` is false. Read as two's complement the same bits are -1,
// which would make it true.
static foreach (backend; Matrix!()) {
    @("compare.lessOrEqual.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                uint one() {
                    return 1u;
                }

                bool notMore() {
                    return top() <= one();
                }
            },
            "notMore",
        );
    }
}

// `-1 < 0` is true. Read as an unsigned bit pattern the same bits are
// `uint.max`, which would make it false.
static foreach (backend; Matrix!()) {
    @("compare.lessThan.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -1;
                }

                int zero() {
                    return 0;
                }

                bool less() {
                    return negative() < zero();
                }
            },
            "less",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.equal.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool eq() {
                    return one() == uno();
                }
            },
            "eq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.equal.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                bool eq() {
                    return one() == two();
                }
            },
            "eq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.notEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                bool neq() {
                    return one() != two();
                }
            },
            "neq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.notEqual.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int uno() {
                    return 1;
                }

                bool neq() {
                    return one() != uno();
                }
            },
            "neq",
        );
    }
}

// Positive and negative zero have different bit patterns but compare equal.
// Calls supply every operand so the frontend cannot fold the comparisons.
static foreach (backend; Matrix!()) {
    @("compare.floatingEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                float positiveFloatZero() {
                    return 0.0f;
                }

                float negativeFloatZero() {
                    return -0.0f;
                }

                double oneAndAHalf() {
                    return 1.5;
                }

                double twoAndAHalf() {
                    return 2.5;
                }

                bool compareFloating() {
                    return positiveFloatZero() == negativeFloatZero()
                        && oneAndAHalf() != twoAndAHalf();
                }
            },
            "compareFloating",
        );
    }
}

// Equal contents in distinct allocations prevent pointer equality from
// standing in for D's element equality. The third array differs only in its
// last element, so a length-only comparison also fails. Empty and non-empty
// arrays cover the length check without reading a null data pointer.
static foreach (backend; Matrix!()) {
    @("compare.scalarDynamicArrayEquality.contents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                ubyte[] first() {
                    return [17, 31, 47];
                }

                ubyte[] same() {
                    return [17, 31, 47];
                }

                ubyte[] different() {
                    return [17, 31, 48];
                }

                ubyte[] empty() {
                    return [];
                }

                bool compareArrays() {
                    return first() == same()
                        && first() != different()
                        && empty() != first()
                        && empty() == empty();
                }
            },
            "compareArrays",
        );
    }
}

// `first() == [17, 31, 47]`: the right side is a bare array literal, not
// a call result like every other array-equality test above. dmd's own
// `__equals` (`core.internal.array.equality`) takes its right operand by
// `scope`, so a literal argument there gets hoisted into a compiler
// temporary (`__arrayliteral_on_stack*`, `expressionsem.d`'s
// `functionParameters`) before the call - a local this test's frame must
// account for.
static foreach (backend; Matrix!()) {
    @("compare.scalarDynamicArrayEquality.literalOperand."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                ubyte[] first() {
                    return [17, 31, 47];
                }

                bool compareAgainstLiteral() {
                    return first() == [17, 31, 47]
                        && first() != [17, 31, 48];
                }
            },
            "compareAgainstLiteral",
        );
    }
}

// rt-simple instantiates array round trips for exactly these six scalar
// element types. Listing all six here keeps the supported scope explicit.
static foreach (backend; Matrix!()) {
    @("compare.scalarDynamicArrayEquality.rtSimpleElementTypes."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                ubyte[] ubytes() {
                    return [17, 31, 47];
                }

                ushort[] ushorts() {
                    return [17, 31, 47];
                }

                int[] ints() {
                    return [17, 31, 47];
                }

                long[] longs() {
                    return [17, 31, 47];
                }

                float[] floats() {
                    return [17.0f, 31.0f, 47.0f];
                }

                double[] doubles() {
                    return [17.0, 31.0, 47.0];
                }

                float[] positiveFloatZero() {
                    return [0.0f];
                }

                float[] negativeFloatZero() {
                    return [-0.0f];
                }

                bool compareElementTypes() {
                    return ubytes() == ubytes()
                        && ushorts() == ushorts()
                        && ints() == ints()
                        && longs() == longs()
                        && floats() == floats()
                        && doubles() == doubles()
                        && positiveFloatZero() == negativeFloatZero();
                }
            },
            "compareElementTypes",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.scalarDynamicArrayEquality.nan." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                double[] nanArray() {
                    return [double.nan];
                }

                bool nanDoesNotEqualItself() {
                    return nanArray() != nanArray();
                }
            },
            "nanDoesNotEqualItself",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.dynamicArrayEquality.pod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Pod {
                    int first;
                    int second;
                }

                Pod[] values() {
                    return [Pod(17, 31), Pod(47, 53)];
                }

                Pod[] same() {
                    return [Pod(17, 31), Pod(47, 53)];
                }

                Pod[] different() {
                    return [Pod(17, 31), Pod(47, 59)];
                }

                bool comparePods() {
                    return values() == same() && values() != different();
                }
            },
            "comparePods",
        );
    }
}


// `int[]` against `uint[3]`: the element types differ only in signedness,
// so dmd neither unifies the operand types nor lowers to `__equals`. The
// `EqualExp` keeps one dynamic and one static array operand, and compiled
// D compares their lengths and then their bytes.
static foreach (backend; Matrix!()) {
    @("compare.mixedArrayEquality.dynamicAndStatic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int[] dynamic(int last) {
                    return [17, 31, last];
                }

                bool compareMixed() {
                    uint[3] same = [17, 31, 47];
                    uint[3] different = [17, 31, 48];
                    uint[2] shorter = [17, 31];
                    return dynamic(47) == same
                        && same == dynamic(47)
                        && dynamic(47) != different
                        && different != dynamic(47)
                        && dynamic(47) != shorter
                        && shorter != dynamic(47);
                }
            },
            "compareMixed",
        );
    }
}


// Two static arrays whose lengths differ: dmd's `shouldUseMemcmp` accepts
// them once the element types are memcmp-compatible, without checking
// that the lengths match, so compiled D reads past the shorter operand.
// snakebite treats differing lengths as unequal instead, without reading
// past either operand's storage.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd and ldc2 read past the shorter static array and disagree " ~
        "on the result - pinned below"),
)) {
    @("compare.staticArrayEquality.differentLengths." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int[3] a() {
                    return [1, 2, 3];
                }

                uint[2] b() {
                    return [1, 2];
                }

                int[2] c() {
                    return [1, 2];
                }

                uint[2] same() {
                    return [1, 2];
                }

                uint[2] different() {
                    return [1, 3];
                }

                bool compareStatic() {
                    return !(a() == b())
                        && !(b() == a())
                        && (a() != b())
                        && (b() != a())
                        && (c() == same())
                        && (same() == c())
                        && !(c() == different())
                        && (c() != different());
                }
            },
            "compareStatic",
        );
    }
}

// dmd's own runtime reads past the shorter operand for two static arrays
// of different lengths; ldc2 gives a different answer for the same code.
// This pins what native dmd actually returns, the divergence
// `Because.diverges` names above.
//
// Only `a() == b()` is pinned: `b() == a()` sizes its read from the
// 12-byte right operand, so it reads past the 8-byte left one and is flaky.
@("compare.staticArrayEquality.differentLengths.Native.diverges")
@Tags("Native")
unittest {
    true.shouldBeRetOf!(
        Native,
        q{
            int[3] a() {
                return [1, 2, 3];
            }

            uint[2] b() {
                return [1, 2];
            }

            bool compareStatic() {
                return (a() == b())
                    && !(a() != b());
            }
        },
        "compareStatic",
    );
}

// The four orderings over `real`, each pinned on both sides of its
// boundary the same way the integral versions above are. Every operand
// comes from a call so dmd cannot fold the comparison away.
static foreach (backend; Matrix!()) {
    @("compare.real.lessThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                real small() {
                    return 1.0L;
                }

                real big() {
                    return 2.0L;
                }

                bool less() {
                    return small() < big();
                }
            },
            "less",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.real.lessThan.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                real small() {
                    return 1.0L;
                }

                real big() {
                    return 2.0L;
                }

                bool less() {
                    return big() < small();
                }
            },
            "less",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.real.lessOrEqual.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                real one() {
                    return 1.0L;
                }

                real uno() {
                    return 1.0L;
                }

                bool notMore() {
                    return one() <= uno();
                }
            },
            "notMore",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.real.greaterThan.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                real small() {
                    return 1.0L;
                }

                real big() {
                    return 2.0L;
                }

                bool more() {
                    return big() > small();
                }
            },
            "more",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.real.greaterOrEqual.equal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                real one() {
                    return 1.0L;
                }

                real uno() {
                    return 1.0L;
                }

                bool notLess() {
                    return one() >= uno();
                }
            },
            "notLess",
        );
    }
}

// Positive and negative zero have different bit patterns but compare
// equal, the same rule `compare.floatingEquality` pins for `float`/
// `double`.
static foreach (backend; Matrix!()) {
    @("compare.real.equal.signedZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                real positiveZero() {
                    return 0.0L;
                }

                real negativeZero() {
                    return -0.0L;
                }

                bool eq() {
                    return positiveZero() == negativeZero();
                }
            },
            "eq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.real.notEqual.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                real one() {
                    return 1.0L;
                }

                real two() {
                    return 2.0L;
                }

                bool neq() {
                    return one() != two();
                }
            },
            "neq",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.and.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool yes() {
                    return true;
                }

                bool si() {
                    return true;
                }

                bool both() {
                    return yes() && si();
                }
            },
            "both",
        );
    }
}

// dmd does not cast either operand of `&&`/`||` to `bool` - a plain `int`
// operand is legal and is tested for nonzero the same way an `if`'s own
// condition is. `256`'s low byte is zero, so evaluating the operand at
// this expression's own one-byte `bool` width instead of its own `int`
// width would truncate it to zero and answer `false`.
static foreach (backend; Matrix!()) {
    @("logical.and.intOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int big() {
                    return 256;
                }

                int one() {
                    return 1;
                }

                bool both() {
                    return big() && one() == 1;
                }
            },
            "both",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.and.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                bool yes() {
                    return true;
                }

                bool no() {
                    return false;
                }

                bool both() {
                    return yes() && no();
                }
            },
            "both",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.or.true." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool no() {
                    return false;
                }

                bool yes() {
                    return true;
                }

                bool either() {
                    return no() || yes();
                }
            },
            "either",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("logical.or.false." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(
            backend,
            q{
                bool no() {
                    return false;
                }

                bool nein() {
                    return false;
                }

                bool either() {
                    return no() || nein();
                }
            },
            "either",
        );
    }
}

// D specifies that `&&` evaluates its right side only when the left side is
// true, so `bump` never runs here and `calls` stays at zero. An
// implementation that evaluates both sides answers one instead.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.and.shortCircuits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool no() {
                    return false;
                }

                bool bump() {
                    calls += 1;
                    return true;
                }

                int rightSideRuns() {
                    bool ignored = no() && bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}

// The other half of the pair: with the left side true the right side does
// run, so a backend that never evaluates it fails this one.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.and.evaluatesRightSide." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool yes() {
                    return true;
                }

                bool bump() {
                    calls += 1;
                    return true;
                }

                int rightSideRuns() {
                    bool ignored = yes() && bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}

// `||` evaluates its right side only when the left side is false.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.or.shortCircuits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool yes() {
                    return true;
                }

                bool bump() {
                    calls += 1;
                    return false;
                }

                int rightSideRuns() {
                    bool ignored = yes() || bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write mutable module-level state"),
)) {
    @("logical.or.evaluatesRightSide." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int calls;

                bool no() {
                    return false;
                }

                bool bump() {
                    calls += 1;
                    return false;
                }

                int rightSideRuns() {
                    bool ignored = no() || bump();
                    return calls;
                }
            },
            "rightSideRuns",
        );
    }
}


// A comparison with a NaN operand is false except `!=`, and the opposite
// of a false `<` is not `>=`. The same operands go through the branch that
// is taken when the comparison is false (`if`, `while`) and the one taken
// when it is true (`!`, `do`), with and without a literal operand.
static foreach (backend; Matrix!()) {
    @("compare.floatingNaNBranches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            T nan(T)() { return T.nan; }

            int ifBits(T)(T a, T b) {
                int bits;
                if (a < b) bits |= 1;
                if (a <= b) bits |= 2;
                if (a > b) bits |= 4;
                if (a >= b) bits |= 8;
                if (a == b) bits |= 16;
                if (a != b) bits |= 32;
                return bits;
            }

            int notBits(T)(T a, T b) {
                int bits;
                if (!(a < b)) bits |= 1;
                if (!(a <= b)) bits |= 2;
                if (!(a > b)) bits |= 4;
                if (!(a >= b)) bits |= 8;
                if (!(a == b)) bits |= 16;
                if (!(a != b)) bits |= 32;
                return bits;
            }

            int rightLiteralBits(T)(T a) {
                int bits;
                if (a < 1.0) bits |= 1;
                if (a <= 1.0) bits |= 2;
                if (a > 1.0) bits |= 4;
                if (a >= 1.0) bits |= 8;
                if (a == 1.0) bits |= 16;
                if (a != 1.0) bits |= 32;
                return bits;
            }

            int leftLiteralBits(T)(T a) {
                int bits;
                if (1.0 < a) bits |= 1;
                if (1.0 <= a) bits |= 2;
                if (1.0 > a) bits |= 4;
                if (1.0 >= a) bits |= 8;
                if (1.0 == a) bits |= 16;
                if (1.0 != a) bits |= 32;
                return bits;
            }

            int nanLiteralBits(T)(T a) {
                int bits;
                if (a < T.nan) bits |= 1;
                if (a <= T.nan) bits |= 2;
                if (a > T.nan) bits |= 4;
                if (a >= T.nan) bits |= 8;
                if (a == T.nan) bits |= 16;
                if (a != T.nan) bits |= 32;
                if (T.nan < a) bits |= 64;
                if (T.nan != a) bits |= 128;
                return bits;
            }

            int notNanLiteralBits(T)(T a) {
                int bits;
                if (!(a < T.nan)) bits |= 1;
                if (!(a >= T.nan)) bits |= 2;
                if (!(a == T.nan)) bits |= 4;
                if (!(a != T.nan)) bits |= 8;
                return bits;
            }

            int whileCount(T)(T a, T b) {
                int n;
                while (a < b && n < 3) ++n;
                return n;
            }

            int doCount(T)(T a, T b) {
                int n;
                do ++n; while (a < b && n < 3);
                return n;
            }

            int checkType(T)() {
                if (ifBits!T(nan!T, 1) != 32) return 1;
                if (ifBits!T(1, nan!T) != 32) return 2;
                if (ifBits!T(nan!T, nan!T) != 32) return 3;
                if (ifBits!T(1, 2) != 35) return 4;
                if (ifBits!T(2, 1) != 44) return 5;
                if (ifBits!T(1, 1) != 26) return 6;
                if (notBits!T(nan!T, 1) != 31) return 7;
                if (notBits!T(1, nan!T) != 31) return 8;
                if (notBits!T(1, 2) != 28) return 9;
                if (notBits!T(2, 1) != 19) return 10;
                if (notBits!T(1, 1) != 37) return 11;
                if (rightLiteralBits!T(nan!T) != 32) return 12;
                if (rightLiteralBits!T(0.5) != 35) return 13;
                if (rightLiteralBits!T(1) != 26) return 14;
                if (rightLiteralBits!T(2) != 44) return 15;
                if (leftLiteralBits!T(nan!T) != 32) return 16;
                if (leftLiteralBits!T(0.5) != 44) return 17;
                if (leftLiteralBits!T(1) != 26) return 18;
                if (leftLiteralBits!T(2) != 35) return 19;
                if (whileCount!T(nan!T, 1) != 0) return 20;
                if (whileCount!T(1, nan!T) != 0) return 21;
                if (whileCount!T(1, 2) != 3) return 22;
                if (doCount!T(nan!T, 1) != 1) return 23;
                if (doCount!T(1, nan!T) != 1) return 24;
                if (doCount!T(1, 2) != 3) return 25;
                if (nanLiteralBits!T(1) != 160) return 26;
                if (nanLiteralBits!T(nan!T) != 160) return 27;
                if (notNanLiteralBits!T(1) != 7) return 28;
                if (notNanLiteralBits!T(nan!T) != 7) return 29;
                return 0;
            }

            int main() {
                if (const status = checkType!double) return status;
                if (const status = checkType!float) return 100 + status;
                if (const status = checkType!real) return 200 + status;
                return 0;
            }
        });
    }
}


// A literal on the left of a comparison gives the same answer as the
// mirrored comparison with the literal on the right, whether the answer
// chooses a branch or is a value. A literal on the left of `-` and `/`
// stays on the left.
static foreach (backend; Matrix!()) {
    @("compare.integralLiteralOnLeft." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int branchBits(long a) {
                int bits;
                if (0 < a) bits |= 1;
                if (0 <= a) bits |= 2;
                if (0 > a) bits |= 4;
                if (0 >= a) bits |= 8;
                if (0 == a) bits |= 16;
                if (0 != a) bits |= 32;
                return bits;
            }

            int unsignedBranchBits(ulong a) {
                int bits;
                if (0 < a) bits |= 1;
                if (0 <= a) bits |= 2;
                if (0 > a) bits |= 4;
                if (0 >= a) bits |= 8;
                if (0 == a) bits |= 16;
                if (0 != a) bits |= 32;
                return bits;
            }

            int valueBits(int a) {
                const lt = 5 < a;
                const le = 5 <= a;
                const gt = 5 > a;
                const ge = 5 >= a;
                const eq = 5 == a;
                const ne = 5 != a;
                return lt | le << 1 | gt << 2 | ge << 3 | eq << 4 | ne << 5;
            }

            int ten() { return 10; }

            int main() {
                if (branchBits(-1) != 44) return 1;
                if (branchBits(0) != 26) return 2;
                if (branchBits(1) != 35) return 3;
                if (unsignedBranchBits(0) != 26) return 4;
                if (unsignedBranchBits(ulong.max) != 35) return 5;
                if (valueBits(4) != 44) return 6;
                if (valueBits(5) != 26) return 7;
                if (valueBits(6) != 35) return 8;
                const three = ten - 7;
                if (10 - three != 7) return 9;
                if (21 / three != 7) return 10;
                return 0;
            }
        });
    }
}


// The same, for a floating operand, where a NaN on the right of the
// mirrored comparison still makes every ordering false.
static foreach (backend; Matrix!()) {
    @("compare.floatingLiteralOnLeft." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            double nan() { return double.nan; }
            double three() { return 3.0; }

            int valueBits(double a) {
                const lt = 5.0 < a;
                const le = 5.0 <= a;
                const gt = 5.0 > a;
                const ge = 5.0 >= a;
                const eq = 5.0 == a;
                const ne = 5.0 != a;
                return lt | le << 1 | gt << 2 | ge << 3 | eq << 4 | ne << 5;
            }

            int main() {
                if (valueBits(nan) != 32) return 1;
                if (valueBits(4) != 44) return 2;
                if (valueBits(5) != 26) return 3;
                if (valueBits(6) != 35) return 4;
                if (6.0 - three != 3.0) return 5;
                if (6.0 / three != 2.0) return 6;
                if (2.0 * three != 6.0) return 7;
                return 0;
            }
        });
    }
}


// The ends of every integral range, against variables and against literals,
// signed and unsigned, narrow and wide.
static foreach (backend; Matrix!()) {
    @("compare.integralEdges." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                byte bmin = byte.min;
                byte bmax = byte.max;
                ubyte ubmax = ubyte.max;
                short smin = short.min;
                ushort usmax = ushort.max;
                int imin = int.min;
                int imax = int.max;
                uint uimax = uint.max;
                long lmin = long.min;
                long lmax = long.max;
                ulong ulmax = ulong.max;
                long minusOne = -1;
                ulong zero = 0;

                if (!(bmin < bmax)) return 1;
                if (!(bmin < -127)) return 2;
                if (!(bmax > 126)) return 3;
                if (!(ubmax > 254)) return 4;
                if (!(ubmax == 255)) return 5;
                if (!(smin < -32767)) return 6;
                if (!(usmax >= 65535)) return 7;
                if (!(imin < imax)) return 8;
                if (!(imin <= int.min)) return 9;
                if (imax < int.max) return 10;
                if (!(imax >= int.max)) return 11;
                if (!(int.max > imax - 1)) return 12;
                if (!(uimax > 0)) return 13;
                if (!(uimax == uint.max)) return 14;
                if (!(0 < uimax)) return 15;
                if (!(lmin < lmax)) return 16;
                if (!(lmin <= long.min)) return 17;
                if (!(lmax > long.max - 1)) return 18;
                if (!(minusOne < 0)) return 19;
                if (!(0 > minusOne)) return 20;
                if (!(ulmax > zero)) return 21;
                if (!(ulmax >= ulong.max)) return 22;
                if (!(ulmax > 0)) return 23;
                if (ulmax < 1) return 24;
                if (!(zero < ulmax)) return 25;
                if (!(zero == 0)) return 26;
                if (!(ulmax != 0)) return 27;
                return 0;
            }
        });
    }
}


// A temporary with a destructor in a condition dies at the same point
// whether or not the operands of `&&` and `||` are branches: the temporary
// of a right operand when that operand ends, the one of a left operand when
// the whole condition ends.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE runs no destructor of a temporary in a condition"),
)) {
    @("compare.logicalConditionWithDestructors." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Probe {
                int* log;
                int id;
                bool value;
                ~this() { *log = *log * 10 + id; }
            }

            Probe probe(int* log, int id, bool value) {
                return Probe(log, id, value);
            }

            int both(bool first, bool second, int x) {
                int log;
                if (x < 3 && probe(&log, 1, first).value
                        && probe(&log, 2, second).value)
                    log = log * 10 + 9;
                return log;
            }

            int either(bool first, bool second, int x) {
                int log;
                if (probe(&log, 1, first).value
                        || x > 3 || probe(&log, 2, second).value)
                    log = log * 10 + 9;
                return log;
            }

            int loop(int x) {
                int log;
                int n;
                while (n < x && probe(&log, 1, true).value)
                    ++n;
                return log;
            }

            int main() {
                if (both(true, true, 1) != 129) return 1;
                if (both(true, false, 1) != 12) return 2;
                if (both(false, true, 1) != 1) return 3;
                if (both(true, true, 5) != 0) return 4;
                if (either(true, true, 1) != 19) return 5;
                if (either(false, true, 1) != 219) return 6;
                if (either(false, false, 1) != 21) return 7;
                if (either(false, false, 5) != 19) return 8;
                if (loop(2) != 11) return 9;
                return 0;
            }
        });
    }
}


// `&&`, `||` and `!` over scalars give the fixed answers below for every
// combination, in `if`, `while` and `do`.
static foreach (backend; Matrix!()) {
    @("compare.logicalBranches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            // Bit 0 is (a && b) || c, bit 1 is !(a || b) && c, bit 2 is
            // x < 3 || (x == 5 && !c) || x >= 7, bit 3 is !(x < 3 && x != 1).
            immutable int[8] conditions = [4, 12, 4, 9, 11, 9, 9, 13];
            immutable int[8] whileCounts = [0, 2, 0, 0, 2, 2, 0, 0];
            immutable int[8] doCounts = [1, 1, 3, 3, 3, 1, 3, 3];

            int main() {
                foreach (bits; 0 .. 8) {
                    const bool a = (bits & 1) != 0;
                    const bool b = (bits & 2) != 0;
                    const bool c = (bits & 4) != 0;
                    const int x = bits;

                    int got;
                    if ((a && b) || c) got |= 1;
                    if (!(a || b) && c) got |= 2;
                    if (x < 3 || (x == 5 && !c) || x >= 7) got |= 4;
                    if (!(x < 3 && x != 1)) got |= 8;
                    if (got != conditions[bits]) return 1;

                    int n;
                    while (n < 2 && (a || c) && !b) ++n;
                    if (n != whileCounts[bits]) return 2;

                    int m;
                    do ++m; while (m < 3 && (b || x == 4));
                    if (m != doCounts[bits]) return 3;
                }
                return 0;
            }
        });
    }
}


// Pointers and class references compare as one-word integers. The answers
// cover a null on either side, equal and different operands, and the value
// and the branch form of each test.
static foreach (backend; Matrix!()) {
    @("compare.pointerIdentity.values." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int answers(int* p, int* q, int* r) {
                    const a = p is null;
                    const b = p !is null;
                    const c = q is null;
                    const d = q !is null;
                    const e = p is r;
                    const f = p !is r;
                    const g = null is q;
                    const h = p == q;
                    const i = p != q;
                    return (a ? 1 : 0) | (b ? 2 : 0) | (c ? 4 : 0)
                        | (d ? 8 : 0) | (e ? 16 : 0) | (f ? 32 : 0)
                        | (g ? 64 : 0) | (h ? 128 : 0) | (i ? 256 : 0);
                }

                bool check() {
                    int x, y;
                    return answers(&x, null, &x) == 342
                        && answers(&x, &y, &y) == 298
                        && answers(null, &y, null) == 281;
                }
            },
            "check",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.pointerIdentity.branches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int answers(int* p, int* q, int* r) {
                    int bits;
                    if (p is null) bits |= 1;
                    if (p !is null) bits |= 2;
                    if (q is null) bits |= 4;
                    if (q !is null) bits |= 8;
                    if (p is r) bits |= 16;
                    if (p !is r) bits |= 32;
                    if (p !is null && q is null) bits |= 64;
                    if (p is null || q is null) bits |= 128;
                    if (q !is null && p !is null) bits |= 256;
                    if (null !is p) bits |= 512;
                    if (p == r) bits |= 1024;
                    if (p != q) bits |= 2048;
                    if (!(p is null)) bits |= 4096;
                    return bits;
                }

                bool check() {
                    int x, y;
                    return answers(&x, null, &x) == 7894
                        && answers(&x, &y, &y) == 6954
                        && answers(null, &y, null) == 3225;
                }
            },
            "check",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("compare.classIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                class Node {
                    int value;
                }

                int answers(Node a, Node b, Node c) {
                    int bits;
                    if (a is null) bits |= 1;
                    if (a !is null) bits |= 2;
                    if (b is null) bits |= 4;
                    if (a is c) bits |= 8;
                    if (a !is c) bits |= 16;
                    if (a !is null && b is null) bits |= 32;
                    const e = b is null;
                    const f = a is c;
                    if (e) bits |= 64;
                    if (f) bits |= 128;
                    return bits;
                }

                bool check() {
                    auto n = new Node;
                    return answers(n, null, n) == 238
                        && answers(n, n, null) == 18
                        && answers(null, n, n) == 17;
                }
            },
            "check",
        );
    }
}


// `&&` and `||` over `bool` operands give the same answer whatever the
// value goes to: a variable, an argument, a field, an array element, or
// the destination being one of the operands.
static foreach (backend; Matrix!()) {
    @("compare.logicalValueDestinations." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { bool flag; }

            bool identity(bool value) { return value; }

            int main() {
                foreach (bits; 0 .. 4) {
                    const bool a = (bits & 1) != 0;
                    const bool b = (bits & 2) != 0;

                    bool x = a;
                    x = b || x;
                    if (x != (b || a)) return 1;
                    x = a;
                    x = x && b;
                    if (x != (a && b)) return 2;
                    x = b;
                    x = a || x;
                    if (x != (a || b)) return 3;
                    x = b;
                    x = a && x;
                    if (x != (a && b)) return 4;

                    if (identity(a && b) != (bits == 3)) return 5;
                    if (identity(a || b) != (bits != 0)) return 6;

                    S s;
                    s.flag = a && b;
                    if (s.flag != (bits == 3)) return 7;
                    s.flag = a || b;
                    if (s.flag != (bits != 0)) return 8;

                    bool[2] array;
                    array[1] = a && b;
                    array[0] = a || b;
                    if (array[1] != (bits == 3)) return 9;
                    if (array[0] != (bits != 0)) return 10;
                }
                return 0;
            }
        });
    }
}


// Operands that are calls with side effects run in order, and the right one
// only when the left one does not decide, in every kind of enclosing
// statement.
static foreach (backend; Matrix!()) {
    @("compare.logicalValueSideEffects." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            bool probe(int* log, int id, bool value) {
                *log = *log * 10 + id;
                return value;
            }

            int inIf(bool first, bool second, bool useAnd) {
                int log;
                if (true) {
                    bool r = useAnd ? probe(&log, 1, first) && probe(&log, 2, second)
                        : probe(&log, 1, first) || probe(&log, 2, second);
                    log = log * 10 + (r ? 1 : 0);
                }
                return log;
            }

            int inLoop(bool first, bool second) {
                int log;
                foreach (i; 0 .. 2) {
                    bool r = probe(&log, 1, first) && probe(&log, 2, second);
                    log = log * 10 + (r ? 1 : 0);
                }
                return log;
            }

            int inCase(int selector, bool first, bool second) {
                int log;
                switch (selector) {
                    case 1:
                        bool r = probe(&log, 1, first) || probe(&log, 2, second);
                        log = log * 10 + (r ? 1 : 0);
                        break;
                    default:
                        break;
                }
                return log;
            }

            int inTry(bool first, bool second) {
                int log;
                try {
                    bool r = probe(&log, 1, first) && probe(&log, 2, second);
                    log = log * 10 + (r ? 1 : 0);
                    throw new Exception("x");
                } catch (Exception) {
                    bool r = probe(&log, 3, first) || probe(&log, 4, second);
                    log = log * 10 + (r ? 1 : 0);
                }
                return log;
            }

            bool last(int* log, bool first, bool second) {
                return probe(log, 1, first) && probe(log, 2, second);
            }

            int main() {
                if (inIf(true, true, true) != 121) return 1;
                if (inIf(false, true, true) != 10) return 2;
                if (inIf(true, false, false) != 11) return 3;
                if (inIf(false, false, false) != 120) return 4;
                if (inLoop(true, false) != 120120) return 5;
                if (inLoop(false, true) != 1010) return 6;
                if (inCase(1, true, false) != 11) return 7;
                if (inCase(1, false, true) != 121) return 8;
                if (inCase(2, true, true) != 0) return 9;
                if (inTry(true, false) != 12031) return 10;
                if (inTry(false, true) != 10341) return 11;
                int log;
                if (last(&log, true, true) != true || log != 12) return 12;
                log = 0;
                if (last(&log, false, true) != false || log != 1) return 13;
                return 0;
            }
        });
    }
}
