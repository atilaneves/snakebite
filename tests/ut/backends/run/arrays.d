module ut.backends.run.arrays;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A module-level array is initialised before anything runs, so a callee
// that touches it first still sees its contents.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
                // Module-scope initialisers run before `main`, so the
                // first read of `arr`, even from a callee, already sees
                // its initial contents.
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

// `~` allocates and copies. Neither operand's storage is reused, so
// writing through the result does not change either operand, and writing
// through an operand afterwards does not change the result.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
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

                ubyte[] combined = left ~ right;

                assert(combined.length == 2);
                assert(combined[0] == first);
                assert(combined[1] == second);

                combined[0] = cast(ubyte)(first + 1);
                assert(left[0] == first);

                left[0] = cast(ubyte)(first + 2);
                assert(combined[0] == cast(ubyte)(first + 1));

                combined[1] = cast(ubyte)(second + 1);
                assert(right[0] == second);
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

// Appending a `dchar` to a `wchar[]` encodes it as UTF-16, so a code
// point outside the Basic Multilingual Plane becomes a surrogate pair
// (two elements), not one.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("appendingDcharEncodesUtf16." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            dchar pick(dchar value) {
                return value;
            }

            void main() {
                wchar[] s;
                s ~= pick('\u00e9');
                s ~= pick('\U0001F600');

                assert(s.length == 1 + 2);
                assert(s == "\u00e9\U0001F600"w);
            }
        });
    }
}

// Growing storage through the allocator keeps what was already there,
// across both the element-at-a-time and slice-at-a-time appends.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
                            _elements,
                            newCapacity - _elements.length,
                        );
                    }
                    _length = newLength;
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

// Reserving empty storage before the first append grows through the same
// element and slice paths without relying on variadic slice assignment.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("manualReallocationFromReservedCapacityKeepsContents."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.experimental.allocator: expandArray;
            import std.experimental.allocator.mallocator: Mallocator;

            struct Vector {
                private char[] _elements;
                private long _length;

                this(size_t capacity) {
                    _elements = cast(char[]) Mallocator.instance.allocate(
                        capacity,
                    );
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
                            _elements,
                            newCapacity - _elements.length,
                        );
                    }
                    _length = newLength;
                }
            }

            void main() {
                auto vector = Vector(3);
                vector.put('f');
                vector.put('o');
                vector.put('o');
                vector.put('b');
                vector.put(['a', 'r']);
                vector.put("quux");

                assert(vector._length == 10);
                assert(vector._elements[0 .. vector._length]
                    == "foobarquux");
            }
        });
    }
}

// `a[] = b[]` for two dynamic arrays copies every element of `b` into `a`
// in order, at a length known only at run time - the same shape
// `core.lifetime._d_newclassT`'s own lowering needs for
// `p[0 .. init.length] = init[]` (`core/lifetime.d`). Element-by-element
// copying, as a static array's own whole-slice assignment already does,
// would need one instruction per element, which a run-time-only length
// cannot give a compile-time count for.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceCopyFromDynamicSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [0, 0, 0];
                int[] b = [1, 2, 3];
                a[] = b[];
                assert(a[0] == 1);
                assert(a[1] == 2);
                assert(a[2] == 3);

                // Copying `b`'s elements into `a`'s own storage does not
                // alias it: writing through `a` afterwards leaves `b`
                // alone.
                a[0] = 99;
                assert(b[0] == 1);
            }
        });
    }
}

// `a[] = v` for a dynamic array evaluates the scalar `v` once, then
// broadcasts it into every element, at a length known only at run time -
// the same shape `core/internal/newaa.d`'s own `allocEntry` needs for
// `(cast(ubyte*)&entry.value)[0 .. V.sizeof] = 0` when zeroing a freshly
// allocated associative array entry whose value type is not already
// zero-initialised. Unlike `dynamicSliceCopyFromDynamicSlice` above, no
// element-by-element source read is needed, only one broadcast write per
// element.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3];
                a[] = 7;
                assert(a[0] == 7);
                assert(a[1] == 7);
                assert(a[2] == 7);
            }
        });
    }
}

// `a[m .. n] = v` fills only the bounded slice, at whatever run-time
// start `m` names - not necessarily zero - leaving the elements outside
// the slice untouched.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.nonZeroStart." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3, 4, 5];
                a[1 .. 4] = 9;
                assert(a[0] == 1);
                assert(a[1] == 9);
                assert(a[2] == 9);
                assert(a[3] == 9);
                assert(a[4] == 5);
            }
        });
    }
}

// `a[] += b[]` for two dynamic arrays of the same length adds `b`'s
// elements into `a`'s, in place, at a length known only at run time.
// druntime lowers this to `core.internal.array.operations`'s `arrayOp`
// mixin, which also has a `core.simd` branch for long arrays - a
// backend must still compile that branch even for a two-element array
// short enough to never run it.
static foreach (backend; Matrix!(
)) {
    @("arrayOpAssignAddsElementwise." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2];
                int[] b = [10, 20];
                a[] += b[];
                assert(a[0] == 11);
                assert(a[1] == 22);
            }
        });
    }
}

// `a[] = S(1, 2)` for a plain struct element broadcasts the whole struct
// value, every field, into each element.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.struct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int x; short y; }
            void main() {
                S[] a = [S(1, 1), S(2, 2), S(3, 3)];
                a[] = S(7, 8);
                assert(a[0].x == 7 && a[0].y == 8);
                assert(a[1].x == 7 && a[1].y == 8);
                assert(a[2].x == 7 && a[2].y == 8);
            }
        });
    }
}

// A `double` element fill.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.double." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                double[] a = [1.0, 2.0, 3.0];
                a[] = 2.5;
                assert(a[0] == 2.5 && a[1] == 2.5 && a[2] == 2.5);
            }
        });
    }
}

// A `float` element fill, where the right side is a `double` literal
// that dmd converts to `float` first.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.float." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                float[] a = [1.0f, 2.0f, 3.0f];
                a[] = 2.5;
                assert(a[0] == 2.5f && a[1] == 2.5f && a[2] == 2.5f);
            }
        });
    }
}

// A pointer element fill.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.pointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int x = 42;
                int*[] a = [null, null, null];
                a[] = &x;
                assert(*a[0] == 42 && *a[1] == 42 && *a[2] == 42);
                assert(a[0] is &x);
            }
        });
    }
}

// A `bool` element fill.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.bool." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                bool[] a = [false, false, false];
                a[] = true;
                assert(a[0] && a[1] && a[2]);
            }
        });
    }
}

// A `short` element fill.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.short." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                short[] a = [1, 2, 3];
                a[] = -5;
                assert(a[0] == -5 && a[1] == -5 && a[2] == -5);
            }
        });
    }
}

// A `ubyte` element fill from an `int` literal: dmd converts the right
// side to the element type, so only one byte per element is written.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] a = [1, 2, 3, 4];
                a[1 .. 3] = 200;
                assert(a[0] == 1 && a[1] == 200 && a[2] == 200 && a[3] == 4);
            }
        });
    }
}

// A `ubyte` element fill from an `int` variable cast to `ubyte`.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.ubyteFromVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int v = 0x1234;
                ubyte[] a = [1, 2, 3, 4];
                a[] = cast(ubyte) v;
                assert(a[0] == 0x34 && a[3] == 0x34);
            }
        });
    }
}

// A struct with a postblit: dmd lowers `a[] = v` to `_d_arraysetassign`,
// which runs the postblit once per element and the destructor on each
// overwritten element.
static foreach (backend; Matrix!()) {
    @("dynamicSliceScalarFill.postblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int x;
                int* copies;
                this(this) { if (copies) ++*copies; }
            }
            void main() {
                int copies;
                S[] a = new S[3];
                S v = S(7, &copies);
                a[] = v;
                assert(a[0].x == 7 && a[1].x == 7 && a[2].x == 7);
                assert(copies == 3);
            }
        });
    }
}

// The right side is evaluated exactly once, before any element is
// written, even when it has a side effect.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.rhsOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int next(int* calls) { return ++*calls; }
            void main() {
                int calls;
                int[] a = [0, 0, 0];
                a[] = next(&calls);
                assert(calls == 1);
                assert(a[0] == 1 && a[1] == 1 && a[2] == 1);
            }
        });
    }
}

// The slice bounds are evaluated once each, and the whole left side is
// evaluated before the right side.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.boundsOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            size_t low(int* lows) { ++*lows; return 1; }
            size_t high(int* highs) { ++*highs; return 3; }
            void main() {
                int lows;
                int highs;
                int[] a = [0, 0, 0, 0];
                a[low(&lows) .. high(&highs)] = 5;
                assert(lows == 1 && highs == 1);
                assert(a[0] == 0 && a[1] == 5 && a[2] == 5 && a[3] == 0);
            }
        });
    }
}

// An upper bound past the array's length is a `RangeError`, not a write
// past the end.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("dynamicSliceScalarFill.upperOutOfBounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;
            void main() {
                int[] a = [1, 2, 3];
                size_t high = 10;
                bool caught;
                try {
                    a[1 .. high] = 7;
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
                assert(a[0] == 1 && a[1] == 2 && a[2] == 3);
            }
        });
    }
}

// Reversed bounds are a `RangeError` too.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("dynamicSliceScalarFill.reversedBounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;
            void main() {
                int[] a = [1, 2, 3];
                size_t low = 2;
                size_t high = 1;
                bool caught;
                try {
                    a[low .. high] = 7;
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
                assert(a[0] == 1 && a[1] == 2 && a[2] == 3);
            }
        });
    }
}

// A zero-length slice writes nothing.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.zeroLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3];
                a[2 .. 2] = 7;
                assert(a[0] == 1 && a[1] == 2 && a[2] == 3);
                int[] empty;
                empty[] = 7;
                assert(empty.length == 0);
            }
        });
    }
}

// A static-array element (`int[2]`) fill: the right side is a static
// array with the element's own size, broadcast whole into each element.
static foreach (backend; Matrix!()) {
    @("dynamicSliceScalarFill.staticArrayElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[2][] a = new int[2][3];
                int[2] pair = [7, 8];
                a[] = pair;
                assert(a[0][0] == 7 && a[0][1] == 8);
                assert(a[2][0] == 7 && a[2][1] == 8);
            }
        });
    }
}

// The assignment's own value is the filled slice.
static foreach (backend; Matrix!(
)) {
    @("dynamicSliceScalarFill.resultValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3, 4];
                int[] r = (a[1 .. 3] = 9);
                assert(r.length == 2);
                assert(r[0] == 9 && r[1] == 9);
                assert(r.ptr is a.ptr + 1);
            }
        });
    }
}

// A class reference element fill.
static foreach (backend; Matrix!()) {
    @("dynamicSliceScalarFill.classRef." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int x; this(int x) { this.x = x; } }
            void main() {
                C[] a = new C[3];
                auto c = new C(5);
                a[] = c;
                assert(a[0] is c && a[1] is c && a[2] is c);
                assert(a[2].x == 5);
            }
        });
    }
}


// A 3-byte struct element fill: an element size that is not a native
// integral width, so the value must be copied as bytes, not as a word.
static foreach (backend; Matrix!()) {
    @("dynamicSliceScalarFill.threeByteStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S3 { ubyte a; ubyte b; ubyte c; }
            void main() {
                S3[] a = new S3[2];
                a[] = S3(1, 2, 3);
                assert(a[0].a == 1 && a[0].b == 2 && a[0].c == 3);
                assert(a[1].a == 1 && a[1].b == 2 && a[1].c == 3);
                S3 v = S3(4, 5, 6);
                a[1 .. 2] = v;
                assert(a[0].c == 3);
                assert(a[1].a == 4 && a[1].b == 5 && a[1].c == 6);
            }
        });
    }
}


// An out-of-bounds index into a dynamic array is a `RangeError`, the same
// as an out-of-bounds slice - both are one contract in compiled D, not
// two, so a guest catching `RangeError` around an index must see it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.outOfBoundsIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                bool caught;
                try {
                    auto val = a[3];
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}


// Compiled D's bounds check calls `_d_arraybounds_indexp`, which throws
// `core.exception.ArrayIndexError`, a `RangeError` subclass - so a guest
// `catch (ArrayIndexError)` around an index must match, not only a
// `catch (RangeError)`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.catchArrayIndexError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArrayIndexError;

            void main() {
                int[] a = [1, 2, 3];
                bool caught;
                try {
                    auto val = a[3];
                } catch (ArrayIndexError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// druntime's `ArrayIndexError` message names the failing index and the
// array's length; a guest that reports `e.msg` must see the same text.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.msgNamesIndexAndLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                string msg;
                try {
                    auto val = a[3];
                } catch (RangeError e) {
                    msg = e.msg;
                }
                assert(msg == "index [3] is out of bounds for array of length 3");
            }
        });
    }
}

// `p[i]` has no length to check against, so compiled D never bounds-checks
// a pointer index - a read, a write, and an address-of through one must
// all reach memory the pointer legitimately covers.
static foreach (backend; Matrix!()) {
    @("pointerIndex.notBoundsChecked." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3];
                int[] b = a[0 .. 1];
                int* p = b.ptr;
                assert(p[2] == 3);
                p[2] = 7;
                assert(a[2] == 7);
                assert(*(&p[2]) == 7);
            }
        });
    }
}

// `$` is the array's length, so `a[$ - 1]` is the last element and `a[$]`
// is one past it, a `RangeError`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.dollarAtLengthIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                assert(a[$ - 1] == 3);
                bool caught;
                try {
                    auto val = a[$];
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// An index is converted to `size_t`, so a negative one wraps to a huge
// value - still a `RangeError`, never a read before the array.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.negativeIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                int i = -1;
                bool caught;
                try {
                    auto val = a[i];
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// The bounds check applies to a write through the index, not only a read.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.lvalueAssignIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                bool caught;
                try {
                    a[3] = 1;
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// Taking an element's address is bounds-checked the same as reading it:
// `&a[3]` on a three-element array is a `RangeError`, not a pointer past
// the end.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.addressOfIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                bool caught;
                try {
                    int* p = &a[3];
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// `a[i]++` indexes as an lvalue and is bounds-checked like any other
// element write.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Bytecode, Because.unconfirmed,
        "cannot compile `a[i]++`: `PostExp` on an `IndexExp` is rejected"),
)) {
    @("dynamicIndex.incrementIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a = [1, 2, 3];
                bool caught;
                try {
                    a[3]++;
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// `RangeError` derives from `Error`, so a guest `catch (Error)` handles an
// out-of-bounds index too.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.catchErrorBase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3];
                bool caught;
                try {
                    auto val = a[3];
                } catch (Error) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}

// A null array has length zero, so `a[0]` on it is a `RangeError` - never
// a dereference of the null pointer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("dynamicIndex.nullArrayIsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;

            void main() {
                int[] a;
                bool caught;
                try {
                    auto val = a[0];
                } catch (RangeError) {
                    caught = true;
                }
                assert(caught);
            }
        });
    }
}
