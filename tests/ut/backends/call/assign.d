module ut.backends.call.assign;


import ut.backends;


// The `assign.structBlitRunsPostblitOnce` case this used to cover -
// postblit runs exactly once on a struct-local copy assignment - is now
// `structs.postblitRunsOnceOnCopyIntoVariable`, which asserts the same
// behaviour across the whole backend `Matrix` instead of `Interpreter`
// alone.


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the call counters after evaluating the assignment"),
)) {
    @("assign.resultIsLvalue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    119.shouldBeRetOf!(
        backend,
        q{
            int calls;
            int targetCalls;
            int value;

            int assigned() {
                ++calls;
                return 7;
            }

            ref int target() {
                ++targetCalls;
                return value;
            }

            int result() {
                int* address = &(target() = assigned());
                // Writing a different value through the returned pointer
                // proves it names `value`, not a temporary.
                *address = 9;
                return targetCalls * 100 + calls * 10 + value;
            }
        },
        "result",
    );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.compoundResultKeepsStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int four() {
                    return 4;
                }

                int nine() {
                    return 9;
                }

                int result() {
                    int value = 3;
                    (value += four()) = nine();
                    return value;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.nestedResultUsesSharedStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int seven() {
                    return 7;
                }

                int nine() {
                    return 9;
                }

                int result() {
                    int value = 0;
                    (value = seven()) = nine();
                    return value;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.bitfieldResultKeepsPackedSiblings." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        535.shouldBeRetOf!(
            backend,
            q{
                struct Pair {
                    ubyte first : 4;
                    ubyte second : 4;
                }

                int result() {
                    Pair pair;
                    pair.first = 3;
                    auto value = (pair.second = 5);
                    return cast(int) value * 100
                        + cast(int) pair.first * 10
                        + cast(int) pair.second;
                }
            },
            "result",
        );
    }
}


// `2 += 5` leaves 7. The addend is behind a call so the answer cannot be
// folded before a backend runs.
static foreach (backend; Matrix!()) {
    @("assign.addAssign.local." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 2;
                    sum += five();
                    return sum;
                }
            },
            "total",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("assign.dynamicArrayLengthGrowsInPlace." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    uint[] values = new uint[](2);
                    values[0] = 4;
                    values.length += 3;
                    return cast(int) values.length + cast(int) values[0];
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("assign.dynamicArrayStructFieldLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                struct Box {
                    uint[] values;
                }

                int answer() {
                    Box box;
                    box.values = new uint[](2);
                    box.values[1] = 6;
                    box.values.length += 2;
                    return cast(int) box.values.length +
                        cast(int) box.values[1];
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("assign.dynamicArrayElementCompound." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    uint[] values = new uint[](2);
                    values[1] = 4;
                    values[1] += 7;
                    return cast(int) values[1];
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("assign.dynamicArrayStructFieldCompound." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                struct Box {
                    uint[] values;
                }

                int answer() {
                    Box box;
                    box.values = new uint[](1);
                    box.values[0] = 4;
                    box.values ~= 7;
                    return cast(int) box.values.length +
                        cast(int) box.values[1];
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call native memcpy"),
)) {
    @("assign.cerealMemcpyThroughPointerAndRef." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(7).shouldBeRetOf!(
            backend,
            q{
                import core.stdc.string: memcpy;

                struct Cerealiser {
                    ubyte[] _bytes;

                    void put(ref ubyte value) {
                        _bytes.length += 1;
                        memcpy(&_bytes[$ - 1], &value, 1);
                    }
                }

                struct Decerealiser {
                    const(ubyte)[] _bytes;

                    void get(ref ubyte value) {
                        memcpy(&value, _bytes.ptr, 1);
                    }
                }

                ubyte answer() {
                    ubyte input = 7;
                    auto cerealiser = Cerealiser();
                    cerealiser.put(input);

                    auto decerealiser = Decerealiser(cerealiser._bytes);
                    ubyte output;
                    decerealiser.get(output);
                    return output;
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot hold mutable static state across calls"),
)) {
    @("assign.lvalueReceiverAndIndexEvaluatedOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.shouldBeRetOf!(
            backend,
            q{
                int calls;

                int index() {
                    ++calls;
                    return 1;
                }

                int answer() {
                    uint[] values = new uint[](2);

                    values[index()] += 10;
                    return calls + cast(int) values[1];
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot hold mutable static state across calls"),
)) {
    @("assign.plainAssign.indexEvaluatedOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.shouldBeRetOf!(
            backend,
            q{
                int calls;

                int index() {
                    ++calls;
                    return 1;
                }

                int answer() {
                    uint[] values = new uint[](2);

                    values[index()] = 10;
                    return calls + cast(int) values[1];
                }
            },
            "answer",
        );
    }
}

// Applied twice, so a backend that wrote the addend over the target instead
// of adding to it would disagree: the answer differs from the last addend.
static foreach (backend; Matrix!()) {
    @("assign.addAssign.accumulates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        30.shouldBeRetOf!(
            backend,
            q{
                int ten() {
                    return 10;
                }

                int total() {
                    int sum = 0;
                    sum += ten();
                    sum += ten();
                    sum += ten();
                    return sum;
                }
            },
            "total",
        );
    }
}

// `sum += n` evaluates to the new sum. Every other test here uses `+=` as a
// statement, where that value is discarded.
static foreach (backend; Matrix!()) {
    @("assign.addAssign.isAnExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 0;
                    return (sum += five());
                }
            },
            "total",
        );
    }
}

// A plain `=` replaces the target instead of adding to it: `+=` here would
// leave 7. The initialiser is not the answer either, so a backend that
// dropped the assignment would disagree as well.
static foreach (backend; Matrix!()) {
    @("assign.plain.overwrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 2;
                    sum = five();
                    return sum;
                }
            },
            "total",
        );
    }
}

// `sum = n` evaluates to the assigned value and leaves it in `sum`. Both
// halves are added up, so a backend that yielded the old value and one that
// never wrote `sum` each return 5 rather than 10.
static foreach (backend; Matrix!()) {
    @("assign.plain.isAnExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        10.shouldBeRetOf!(
            backend,
            q{
                int five() {
                    return 5;
                }

                int total() {
                    int sum = 0;
                    int got = (sum = five());
                    got += sum;
                    return got;
                }
            },
            "total",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.local.isAlsoRightOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        13.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int x = 3;
                    int y = 5;
                    x = y * 2 + x;
                    return x;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.local.isAlsoLeftOperandOfChain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int x = 3;
                    int y = 5;
                    x = x - y + y * 2 - 1;
                    return x;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.local.swapsThroughExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        53.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int a = 3;
                    int b = 5;
                    a = a + b;
                    b = a - b;
                    a = a - b;
                    return a * 10 + b;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.bool.conversionOfZeroByteIntoItself." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    ubyte[2] raw = [0, 5];
                    bool flag = true;
                    flag = cast(bool) raw[0];
                    return flag ? 1 : 0;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.bool.conversionOfNonZeroByteIntoItself." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    ubyte[2] raw = [0, 5];
                    bool flag = false;
                    flag = cast(bool) raw[1];
                    return flag ? 1 : 0;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.bool.conversionOfExpressionReadingItself." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    ubyte[2] raw = [0, 5];
                    bool flag = true;
                    flag = cast(bool) (flag + raw[0]);
                    return flag ? 1 : 0;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.bool.comparisonThatReadsTheFlag." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int limit = 4;
                    bool seen = true;
                    seen = limit > 3 && !seen;
                    const first = seen;
                    seen = limit < 9 && !first;
                    return (seen ? 1 : 0) + (first ? 4 : 2);
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.field.isAlsoOperandThroughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_309.shouldBeRetOf!(
            backend,
            q{
                struct Pair {
                    int first;
                    int second;
                }

                int result() {
                    auto pair = Pair(3, 5);
                    auto pointer = &pair;
                    pointer.first = pointer.second * 2 + pointer.first;
                    pointer.second = pointer.first - pointer.second + 1;
                    return pair.first * 100 + pair.second;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.field.ofSameStructReadByTheValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        207.shouldBeRetOf!(
            backend,
            q{
                struct Pair {
                    int first;
                    int second;

                    void rotate() {
                        first = second - first;
                        second = first + second;
                    }
                }

                int result() {
                    auto pair = Pair(3, 5);
                    pair.rotate;
                    return pair.first * 100 + pair.second;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.reference.isAlsoOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_921.shouldBeRetOf!(
            backend,
            q{
                void update(ref int target, ref int other) {
                    target = other * 2 + target;
                }

                int result() {
                    int x = 5;
                    int y = 7;
                    update(x, y);
                    update(y, y);
                    return x * 100 + y;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.array.elementIsAlsoOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        17_026.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[3] values = [2, 5, 9];
                    values[1] = values[1] * 2 + values[2] - values[0];
                    int last = values[2];
                    last = values[1] + last;
                    return values[1] * 1000 + last;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE stops at an array bounds error; a catch cannot see it"),
)) {
    @("assign.destination.throwBeforeValueLeavesVariableOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] values = [10, 20];
                    int x = 42;
                    size_t position = 5;
                    try {
                        x = values[position] + x;
                    } catch (Throwable) {
                    }
                    return x;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE stops at an array bounds error; a catch cannot see it"),
)) {
    @("assign.destination.throwBeforeValueLeavesWideVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] values = [10, 20];
                    long wide = 7;
                    size_t position = 5;
                    try {
                        wide = values[position];
                    } catch (Throwable) {
                    }
                    return cast(int) wide;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE stops at an array bounds error; a catch cannot see it"),
)) {
    @("assign.destination.throwBeforeValueLeavesBoolVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] values = [10, 20];
                    bool flag = true;
                    size_t position = 5;
                    try {
                        flag = cast(bool) values[position];
                    } catch (Throwable) {
                    }
                    return flag ? 0 : 1;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.result.leavesCopyOfVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        107.shouldBeRetOf!(
            backend,
            q{
                long widened(int value) {
                    long copy = value;
                    value = 0;
                    return copy + value;
                }

                int result() {
                    return cast(int) widened(100) + 7;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("assign.destination.throwAfterPartialValueLeavesDestination." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int thrower(int value) {
                    if (value > 0)
                        throw new Exception("thrown");
                    return value;
                }

                int result() {
                    int x = 7;
                    const y = 3;
                    try {
                        x = y * 2 + thrower(y);
                    } catch (Exception) {
                    }
                    return x;
                }
            },
            "result",
        );
    }
}
