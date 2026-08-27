module ut.backends.run.arrays;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A module-level array is initialised before anything runs, so a callee
// that touches it first still sees its contents.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("moduleArrayInitialisedBeforeFirstUse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[] arr = [1, 2, 3];

            int sum() {
                return arr[0] + arr[1] + arr[2];
            }

            void main() {
                // First touch is from a lazily-compiled callee, not the
                // entry itself; it must still see the initialised contents.
                assert(sum() == 6);

                assert(arr.length == 3);
                assert(arr[0] == 1);
                assert(arr[1] == 2);
                assert(arr[2] == 3);

                arr[0] = 99;
                assert(arr[0] == 99);
                arr ~= 4;
                assert(arr.length == 4);
                assert(arr[3] == 4);
            }
        });
    }
}

// `~` allocates and copies. Neither operand's storage is reused, so a
// backend that returns a slice of either one is wrong.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("concatenationCopiesBothSides." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] left = [first];
                ubyte[] right = [second];

                const combined = left ~ right;

                assert(combined.length == 2);
                assert(combined[0] == first);
                assert(combined[1] == second);
            }
        });
    }
}

// `.dup` and `.idup` give storage of their own. Writing through the copy
// leaves the original alone, which a backend returning the same
// (ptr, length) pair would not.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("dupAndIdupCopyStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long longValue(long seed) {
                return seed;
            }

            double doubleValue(double seed) {
                return seed;
            }

            void main() {
                long first = longValue(1_000_000_000_000L);
                long[] longs =
                    [first, first + 1, first + 2, first + 3];

                long[] longCopy = longs.dup;
                longCopy[0] = longValue(-1);

                assert(longCopy.length == 4);
                assert(longCopy[0] == -1);
                assert(longs[0] == 1_000_000_000_000L);
                assert(longCopy[1] == longs[1]);
                assert(longCopy[2] == longs[2]);
                assert(longCopy[3] == longs[3]);

                double firstDouble = doubleValue(1.5);
                double[] doubles = [firstDouble, firstDouble + 1.5];

                immutable(double)[] frozenDoubles = doubles.idup;
                doubles[0] = doubleValue(-2.5);

                assert(frozenDoubles[0] == 1.5);
                assert(frozenDoubles[1] == 3.0);
                assert(doubles[0] == -2.5);
            }
        });
    }
}

// Appending a `dchar` to a `char[]` encodes it as UTF-8, so one append
// adds as many elements as the code point needs, not one.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("appendingDcharEncodesUtf8." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            dchar pick(dchar value) {
                return value;
            }

            void main() {
                char[] s;
                s ~= pick('A');
                s ~= pick('\u00e9');
                s ~= pick('\U0001F600');

                assert(s.length == 1 + 2 + 4);
                assert(s == "A\u00e9\U0001F600");
            }
        });
    }
}

// Growing storage through the allocator keeps what was already there,
// across both the element-at-a-time and slice-at-a-time appends.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("manualReallocationKeepsContents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.experimental.allocator: expandArray;
            import std.experimental.allocator.mallocator: Mallocator;

            struct Vector {
                private char[] _elements;
                private long _length;

                this(char[] values...) {
                    _elements = cast(char[]) Mallocator.instance.allocate(
                        values.length,
                    );
                    _elements[] = values[];
                    _length = values.length;
                }

                ~this() {
                    Mallocator.instance.deallocate(cast(void[]) _elements);
                }

                void put(char value) {
                    expand(_length + 1);
                    _elements[_length - 1] = value;
                }

                void put(const(char)[] values) {
                    const oldLength = _length;
                    expand(_length + values.length);
                    _elements[oldLength .. _length] = values[];
                }

                private void expand(long newLength) {
                    if (newLength > _elements.length) {
                        const newCapacity = (newLength * 3) / 2;
                        Mallocator.instance.expandArray(
                            mutableElements,
                            newCapacity - _elements.length,
                        );
                    }
                    _length = newLength;
                }

                private ref char[] mutableElements() return {
                    auto pointer = &_elements;
                    return *pointer;
                }
            }

            void main() {
                auto vector = Vector('f', 'o', 'o');
                vector.put('b');
                vector.put(['a', 'r']);
                vector.put("quux");

                assert(vector._length == 10);
                assert(vector._elements[0 .. vector._length] == "foobarquux");
            }
        });
    }
}

// A pointer into an element of a nested array aliases the array's own
// storage, so writing through it is visible through the array.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("pointerIntoNestedArrayAliasesStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                static struct S { int[][] a; }
                S s;
                s.a ~= [1, 2, 3];
                auto p = &s.a[0][1];
                *p = 9;
                assert(s.a[0][1] == 9);
                assert(s.a[0][0] == 1);
                assert(s.a[0].length == 3);
            }
        });
    }
}

