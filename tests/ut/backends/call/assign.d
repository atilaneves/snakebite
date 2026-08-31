module ut.backends.call.assign;


import ut.backends;


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
