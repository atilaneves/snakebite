module ut.backends.run.operators;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// Shifting a value into bytes and back reconstructs it, which pins the
// shift amounts and the truncation each `cast(ubyte)` does.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
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
