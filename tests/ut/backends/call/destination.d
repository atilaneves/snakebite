module ut.backends.call.destination;


import ut.backends;


// An expression may compute its value straight into the variable, field or
// slot that receives it. These tests pin the aliasing cases: the destination
// is also an operand, or it is reached through a pointer or a reference, or
// the expression throws before it has a value.

static foreach (backend; Matrix!()) {
    @("destination.local.isAlsoRightOperand." ~ backend.stringof)
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
    @("destination.local.isAlsoLeftOperandOfChain." ~ backend.stringof)
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
    @("destination.local.swapsThroughExpression." ~ backend.stringof)
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
    @("destination.bool.conversionOfItself." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    ubyte[2] raw = [0, 5];
                    bool flag = true;
                    flag = cast(bool) raw[0];
                    const first = flag;
                    flag = cast(bool) raw[1];
                    flag = cast(bool) (flag + raw[0]);
                    return first ? 0 : (flag ? 1 : 2);
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("destination.bool.comparisonThatReadsTheFlag." ~ backend.stringof)
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
    @("destination.field.isAlsoOperandThroughPointer." ~ backend.stringof)
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
    @("destination.field.ofSameStructReadByTheValue." ~ backend.stringof)
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
    @("destination.reference.isAlsoOperand." ~ backend.stringof)
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
    @("destination.array.elementIsAlsoOperand." ~ backend.stringof)
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
    @("destination.throwBeforeValueLeavesDestination." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        74_203.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] values = [10, 20];
                    int x = 42;
                    long wide = 7;
                    bool flag = true;
                    size_t position = 5;
                    int thrown;
                    try {
                        x = values[position] + x;
                    } catch (Throwable) {
                        thrown += 1;
                    }
                    try {
                        wide = values[position];
                    } catch (Throwable) {
                        thrown += 1;
                    }
                    try {
                        flag = cast(bool) values[position];
                    } catch (Throwable) {
                        thrown += 1;
                    }
                    return cast(int) wide * 10_000 + x * 100 + (flag ? 0 : 1) + thrown;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("destination.result.leavesCopyOfVariable." ~ backend.stringof)
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
    @("destination.throwAfterPartialValueLeavesDestination." ~ backend.stringof)
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
