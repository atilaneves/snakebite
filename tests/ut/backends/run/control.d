module ut.backends.run.control;


// Every test here reaches an AST node class that no test
// chosen before it reached, and is named for that class.
// Together they reach every class the frontend produced
// for a corpus of guest programs.
//
// The expected exit status is what `dmd -run` gives the
// program, so each test states what compiled D does. A
// backend joins a test's `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("gotoStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int seed(int value) {
                return value;
            }

            void main() {
                int total;

                for (int i = 0; i < seed(1); ++i) {
                    try {
                        throw new Exception("expected");
                    } catch (Exception) {
                        goto resumed;

                        total += seed(99);

                    resumed:
                        break;
                    }
                }

                assert(total == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("importStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct ByteRange {
                void* ptr;
                size_t length;
            }

            struct Allocations {
                ByteRange[] entries;

                bool remove(void[] bytes) scope pure {
                    import std.algorithm: canFind, countUntil;

                    bool matches(ByteRange other) {
                        return other.ptr == bytes.ptr &&
                            other.length == bytes.length;
                    }

                    assert(entries.canFind!matches);
                    const index = entries.countUntil!matches;
                    foreach (i; index .. entries.length - 1)
                        entries[i] = entries[i + 1];
                    entries = entries[0 .. $ - 1];
                    return true;
                }
            }

            void main() {
                ubyte[2] first;
                ubyte[3] second;
                auto allocations = Allocations([
                    ByteRange(first.ptr, first.length),
                    ByteRange(second.ptr, second.length),
                ]);
                assert(allocations.remove(first[]));
                assert(allocations.entries.length == 1);
                assert(allocations.entries[0].ptr == second.ptr);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("gotoCaseStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 1;
                int result;

                switch (value) {
                    case 1:
                        result += 10;
                        goto case 2;

                    case 2:
                        result += 20;
                        break;

                    default:
                        result += 30;
                        break;
                }

                assert(result == 30);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("doStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int i;
                int sum;

                do {
                    ++i;

                    if (i == 2)
                        continue;

                    if (i == 5)
                        break;

                    sum += i;
                } while (i < 6);

                assert(sum == 8);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("foreachRangeStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void writeLength(T)(ref ubyte[] bytes, size_t length) {
                const narrowed = cast(T) length;

                foreach (i; 0 .. T.sizeof)
                    bytes ~= cast(ubyte)(narrowed >> (i * 8));
            }

            void main() {
                ubyte[] bytes;
                size_t length = 250;
                length += 8;

                writeLength!ushort(bytes, length);

                assert(bytes.length == 2);
                assert(bytes[0] == 2);
                assert(bytes[1] == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("gotoDefaultStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 1;
                int result;

                switch (value) {
                    case 1:
                        result += 10;
                        goto default;

                    case 2:
                        result += 20;
                        break;

                    default:
                        result += 30;
                        break;
                }

                assert(result == 40);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("switchErrorStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Colour {
                red,
                green,
                blue,
            }

            Colour pick(int n) {
                return n == 0 ? Colour.red : n == 1 ? Colour.green : Colour.blue;
            }

            int weight(Colour colour) {
                final switch (colour) {
                    case Colour.red:
                        return 10;

                    case Colour.green:
                        return 20;

                    case Colour.blue:
                        return 30;
                }
            }

            void main() {
                assert(weight(pick(0)) == 10);
                assert(weight(pick(1)) == 20);
                assert(weight(pick(2)) == 30);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("unrolledLoopStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.meta: AliasSeq;

            int helper(int value) {
                return value + 1;
            }

            void main() {
                int first = helper(1);
                int second = helper(3);
                int third = helper(5);
                int sum;

                foreach (value; AliasSeq!(first, second, third)) {
                    if (value == second)
                        continue;

                    if (value == third)
                        break;

                    sum += value;
                }

                assert(sum == 2);
            }
        });
    }
}

