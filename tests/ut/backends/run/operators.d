module ut.backends.run.operators;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// Shifting a value into bytes and back reconstructs it, which pins the
// shift amounts and the truncation each `cast(ubyte)` does.
static foreach (backend; Matrix!()) {
    @("shiftSerialisationRoundTrips." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            private enum MyEnum {
                foo,
                bar,
                baz,
            }

            struct Writer {
                ubyte[] bytes;

                void writeEnum(MyEnum value) {
                    const intValue = cast(int) value;

                    foreach_reverse (i; 0 .. int.sizeof)
                        bytes ~= cast(ubyte)(intValue >> (i * 8));
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                MyEnum readEnum() {
                    int intValue;

                    foreach (_; 0 .. int.sizeof) {
                        intValue <<= 8;
                        intValue |= bytes[index++];
                    }

                    return cast(MyEnum) intValue;
                }
            }

            void main() {
                Writer writer;
                writer.writeEnum(MyEnum.bar);
                writer.writeEnum(MyEnum.baz);
                writer.writeEnum(MyEnum.foo);

                assert(
                    writer.bytes ==
                    [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0]
                );

                auto reader = Reader(writer.bytes);

                assert(reader.readEnum == MyEnum.bar);
                assert(reader.readEnum == MyEnum.baz);
                assert(reader.readEnum == MyEnum.foo);
            }
        });
    }
}

// A byte copy through the post-semantic pointer expression writes at the
// requested element offset, so the cast, multiplication, and pointer
// addition must all be evaluated by the backend.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("pointerCastAndAdditionCopiesAtOffset." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: memcpy;

            struct Writer {
                private ubyte[] _bytes;

                size_t offset() {
                    return 2;
                }

                void copyAtOffset() {
                    const oldLength = offset;
                    const ubyte[] value = [9, 8];

                    memcpy(
                        cast(ubyte*)this._bytes + cast(long)oldLength,
                        value.ptr,
                        value.length,
                    );
                }
            }

            void main() {
                auto writer = Writer([1, 2, 3, 4]);
                writer.copyAtOffset;

                assert(writer._bytes[0] == 1);
                assert(writer._bytes[1] == 2);
                assert(writer._bytes[2] == 9);
                assert(writer._bytes[3] == 8);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("pointerPostIncrementAdvancesByElementSize." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        14.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] values = [6, 8];
                    int* pointer = &values[0];
                    auto old = pointer++;
                    return *old + *pointer;
                }
            },
            "result",
        );
    }
}

// Pointer arithmetic uses the pointee size, not byte addressing, for a
// dynamic array whose elements are wider than one byte.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("pointerCastAndAdditionScalesByPointeeSize." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: memcpy;

            struct Writer {
                private uint[] _values;

                void copyAtOffset() {
                    const oldLength = 1;
                    const uint[] value = [cast(uint) 0xaabbccdd];

                    memcpy(
                        cast(uint*)this._values + cast(long)oldLength * 1L,
                        value.ptr,
                        value.length * uint.sizeof,
                    );
                }
            }

            void main() {
                auto writer = Writer([
                    cast(uint) 0x11111111,
                    cast(uint) 0x22222222,
                ]);
                writer.copyAtOffset;

                assert(writer._values[0] == cast(uint) 0x11111111);
                assert(writer._values[1] == cast(uint) 0xaabbccdd);
            }
        });
    }
}

// Integral-plus-pointer addition uses the same native pointee addressing as
// pointer-plus-integral addition.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("integralPlusPointerAdditionScalesByPointeeSize." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: memcpy;

            struct Writer {
                private uint[] _values;

                long offset() {
                    return 1;
                }

                uint* base() {
                    return _values.ptr;
                }

                void copyAtOffset() {
                    const uint[] value = [cast(uint) 0xaabbccdd];

                    memcpy(
                        cast(long)offset * 1L + base,
                        value.ptr,
                        value.length * uint.sizeof,
                    );
                }
            }

            void main() {
                auto writer = Writer([
                    cast(uint) 0x11111111,
                    cast(uint) 0x22222222,
                ]);
                writer.copyAtOffset;

                assert(writer._values[0] == cast(uint) 0x11111111);
                assert(writer._values[1] == cast(uint) 0xaabbccdd);
            }
        });
    }
}

// Cerealising and decerealising nonzero bytes through the computed pointer
// preserves the bytes at the nonzero old length.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("cerealiseDecerealiseRoundTripsAtOffset." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: memcpy;

            struct Cerealiser {
                private ubyte[] _bytes;

                size_t offset() {
                    return 2;
                }

                void cerealise(in ubyte[] value) {
                    const oldLength = offset;

                    memcpy(
                        cast(ubyte*)this._bytes + cast(long)oldLength,
                        value.ptr,
                        value.length,
                    );
                }

                void decerealise(ubyte[] value) {
                    const oldLength = offset;

                    memcpy(
                        value.ptr,
                        cast(ubyte*)this._bytes + cast(long)oldLength,
                        value.length,
                    );
                }
            }

            void main() {
                auto cerealiser = Cerealiser([0, 0, 0, 0]);
                const original = [cast(ubyte) 7, cast(ubyte) 11];
                cerealiser.cerealise(original);

                auto decoded = [cast(ubyte) 0, cast(ubyte) 0];
                cerealiser.decerealise(decoded);

                assert(decoded[0] == original[0]);
                assert(decoded[1] == original[1]);
            }
        });
    }
}

// A pointer of another type to the same storage reads and writes those
// bytes, so a write through it is visible through the original.
static foreach (backend; Matrix!()) {
    @("punnedPointerSharesStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                dchar c = cast(dchar) 0x41;
                uint* p = cast(uint*) &c;
                *p >>= 1;
                assert(c == cast(dchar) 0x20);
            }
        });
    }
}

// An op-assign whose left side is a `ref`-returning call writes through to
// the referent, not to a temporary.
static foreach (backend; Matrix!()) {
    @("opAssignThroughRefReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Vec {
                int[] data;

                ref int at(in int index) return {
                    return data[index];
                }
            }

            void main() {
                Vec v;
                v.data = [10, 20, 30];

                v.at(1) /= 2;

                assert(v.data[0] == 10);
                assert(v.data[1] == 10);
                assert(v.data[2] == 30);
            }
        });
    }
}

// A postfix `++`/`--` on a floating value yields the old value and steps
// by one.
static foreach (backend; Matrix!()) {
    @("floatingPostfixIncrementDecrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                double d = 1.5;
                assert(d++ == 1.5);
                assert(d == 2.5);
                float f = 0.25f;
                assert(f-- == 0.25f);
                assert(f == -0.75f);
                real r = 3.0L;
                r++;
                assert(r == 4.0L);
            }
        });
    }
}

// Complex values are equal when both halves are; imaginary values compare
// as floating point.
static foreach (backend; Matrix!()) {
    @("complexAndImaginaryComparison." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                creal c = 1.5 + 2.0i;
                assert(c == 1.5 + 2.0i);
                assert(c != 1.5 + 3.0i);
                assert(c != 0.5 + 2.0i);
                cfloat zero = 0.0f + 0.0fi;
                cfloat negativeZero = -0.0f + 0.0fi;
                assert(zero == negativeZero);
                idouble i = 2.0i;
                assert(i == 2.0i);
                assert(i < 3.0i);
            }
        });
    }
}

// Imaginary values add, subtract and take a remainder as imaginary values.
// A real times or over an imaginary is imaginary, and an imaginary times or
// over an imaginary is real: `2i * 3i` is `-6`.
static foreach (backend; Matrix!()) {
    @("imaginaryArithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                idouble i = 3.0i;
                idouble two = 2.0i;
                double d = 2.0;
                assert(i + two == 5.0i);
                assert(i - two == 1.0i);
                assert(i % two == 1.0i);
                assert(i * d == 6.0i);
                assert(d * i == 6.0i);
                assert(i / d == 1.5i);
                assert(d / two == -1.0i);
                assert(i * two == -6.0);
                assert(i / two == 1.5);
                assert(-i == -3.0i);
                assert(7.0 % two == 1.0);
                i *= d;
                assert(i == 6.0i);
                i /= d;
                assert(i == 3.0i);
                i += two;
                assert(i == 5.0i);
                i -= two;
                assert(i == 3.0i);
                ifloat f = 1.5fi;
                f *= 2.0f;
                assert(f + 1.0fi == 4.0fi);
                ireal r = 2.0Li;
                assert(r * r == -4.0L);
                assert(-r == -2.0Li);
            }
        });
    }
}

// A vector comparison gives a vector: each lane is all-ones where it
// compares true.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot compare vectors"),
)) {
    @("vectorComparisonGivesLaneMasks." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd: float4, int4, ubyte16;

            void main() {
                int4 a = [1, 2, 3, 4];
                int4 b = [1, 0, 3, 5];
                int4 equal = a == b;
                assert(equal.array == [-1, 0, -1, 0]);
                int4 less = a < b;
                assert(less.array == [0, 0, 0, -1]);
                float4 x = [1.0f, 2.0f, float.nan, 4.0f];
                float4 y = [1.0f, 3.0f, float.nan, 0.0f];
                auto floatEqual = x == y;
                assert(floatEqual.array[0] != 0);
                assert(floatEqual.array[1] == 0);
                assert(floatEqual.array[2] == 0);
                ubyte16 u = 200;
                ubyte16 v = 100;
                ubyte16 greater = u > v;
                assert(greater.array[0] == 255);
            }
        });
    }
}

// Delegates order as one unsigned integer whose high word is the function
// pointer and whose low word is the context.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("delegateOrdering." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                void delegate() a, b;
                a.ptr = cast(void*) 1;
                a.funcptr = cast(void function()) 5;
                b.ptr = cast(void*) 2;
                b.funcptr = cast(void function()) 3;
                assert(a > b);
                assert(!(a < b));
                assert(b <= a);
                a.funcptr = cast(void function()) 3;
                assert(a < b);
                assert(a <= b);
                assert(!(a >= b));
                a.ptr = cast(void*) 2;
                assert(a <= b);
                assert(a >= b);
                assert(!(a < b));
            }
        });
    }
}
