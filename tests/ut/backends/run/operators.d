module ut.backends.run.operators;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a floating value to a pointer"),
)) {
    @("pointerFloatingCastsConvertNumericValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            double asNumber(int* value) { return cast(double) value; }
            int* asPointer(double value) { return cast(int*) value; }

            void main() {
                int* pointer = asPointer(12.0);
                assert(cast(size_t) pointer == 12);
                assert(asNumber(pointer) == 12.0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("functionPointerCastsPreserveCallableAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int twice(int value) { return value * 2; }

            void main() {
                alias Function = int function(int);
                Function original = &twice;
                void* address = cast(void*) original;
                Function restored = cast(Function) address;

                assert(restored(21) == 42);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static array variable in this cast"),
)) {
    @("staticArrayToVoidSliceUsesByteLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[2] values;

            void main() {
                values = [0x01020304, 0x05060708];
                void[] bytes = cast(void[]) values;

                assert(bytes.length == 2 * int.sizeof);
                assert(bytes.ptr == cast(void*) values.ptr);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not form a byte-length slice from a static array"),
)) {
    @("localStaticArrayToVoidSlicePreservesLengthAndStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[2] values = [0x01020304, 0x05060708];
                void[] bytes = cast(void[]) values;

                assert(bytes.length == 2 * int.sizeof);
                assert(bytes.ptr == cast(void*) values.ptr);
            }
        });
    }
}

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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast an associative array to a class reference"),
)) {
    @("associativeArrayClassCastsKeepTheHandle." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {}
            C asClass(int[int] value) { return cast(C) value; }

            void main() {
                int[int] value;
                value[1] = 2;
                C object = asClass(value);
                assert(cast(void*) object == cast(void*) value);
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

// Complex arithmetic mixes complex, real and imaginary operands: a real or
// imaginary operand has no other half, so `c + d` adds `d` to the real
// half alone, and `c * i` swaps the halves. Each product and quotient of
// two complex operands is a function of its own that takes and returns
// values: around dmd's calls to druntime's `_Cmul` and `_Cdiv`, a caller's
// live registers are clobbered, and a `ref` parameter misaligns the stack.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE drops the imaginary half of a complex plus a real: "
        ~ "`(1 + 2i) + 2.0` is `3 + 0i`"),
)) {
    @("complexArithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            cdouble times(cdouble a, cdouble b) { return a * b; }
            cdouble over(cdouble a, cdouble b) { return a / b; }
            cdouble realOver(double a, cdouble b) { return a / b; }
            cdouble imaginaryOver(idouble a, cdouble b) { return a / b; }
            cdouble timesAssign(cdouble a, cdouble b) { a *= b; return a; }
            cdouble overAssign(cdouble a, cdouble b) { a /= b; return a; }
            cfloat timesFloat(cfloat a, cfloat b) { return a * b; }
            cfloat overAssignFloat(cfloat a, cfloat b) { a /= b; return a; }
            creal timesAssignReal(creal a, creal b) { a *= b; return a; }

            void main() {
                cdouble c = 1.0 + 2.0i;
                cdouble e = 3.0 + 4.0i;
                cdouble f = 1.0 + 1.0i;
                double d = 2.0;
                idouble i = 2.0i;
                assert(c + e == 4.0 + 6.0i);
                assert(c - e == -2.0 - 2.0i);
                assert(times(c, e) == -5.0 + 10.0i);
                assert(over(-5.0 + 10.0i, e) == c);
                assert(c + d == 3.0 + 2.0i);
                assert(d + c == 3.0 + 2.0i);
                assert(c - d == -1.0 + 2.0i);
                assert(d - c == 1.0 - 2.0i);
                assert(c + i == 1.0 + 4.0i);
                assert(i + c == 1.0 + 4.0i);
                assert(c - i == 1.0 + 0.0i);
                assert(i - c == -1.0 + 0.0i);
                assert(d + i == 2.0 + 2.0i);
                assert(i + d == 2.0 + 2.0i);
                assert(d - i == 2.0 - 2.0i);
                assert(i - d == -2.0 + 2.0i);
                assert(c * d == 2.0 + 4.0i);
                assert(d * c == 2.0 + 4.0i);
                assert(c * i == -4.0 + 2.0i);
                assert(i * c == -4.0 + 2.0i);
                assert(c / d == 0.5 + 1.0i);
                assert(c / i == 1.0 - 0.5i);
                assert(realOver(d, f) == 1.0 - 1.0i);
                assert(imaginaryOver(i, f) == 1.0 + 1.0i);
                cdouble m = 7.5 - 5.5i;
                assert(m % d == 1.5 - 1.5i);
                assert(m % i == 1.5 - 1.5i);
                assert(-c == -1.0 - 2.0i);
                cdouble x = c;
                x += e;
                assert(x == 4.0 + 6.0i);
                x -= i;
                assert(x == 4.0 + 4.0i);
                x = timesAssign(x, f);
                assert(x == 0.0 + 8.0i);
                x /= i;
                assert(x == 4.0 + 0.0i);
                x += d;
                assert(x == 6.0 + 0.0i);
                x *= i;
                assert(x == 0.0 + 12.0i);
                x = overAssign(x, f);
                assert(x == 6.0 + 6.0i);
                x %= 4.0;
                assert(x == 2.0 + 2.0i);
                x /= d;
                assert(x == 1.0 + 1.0i);
                x -= d;
                assert(x == -1.0 + 1.0i);
                cdouble y = 1.5 + 2.0i;
                assert(y++ == 1.5 + 2.0i);
                assert(y == 2.5 + 2.0i);
                assert(y-- == 2.5 + 2.0i);
                assert(y == 1.5 + 2.0i);
                ++y;
                assert(y == 2.5 + 2.0i);
                cfloat g = 1.0f + 2.0fi;
                assert(timesFloat(g, g) == -3.0f + 4.0fi);
                g = overAssignFloat(g, 1.0f + 2.0fi);
                assert(g == 1.0f + 0.0fi);
                creal r = 1.0L + 2.0Li;
                r = timesAssignReal(r, 3.0L + 4.0Li);
                assert(r == -5.0L + 10.0Li);
                assert(-r == 5.0L - 10.0Li);
                cfloat narrow = 1.0f + 2.0fi;
                narrow += e;
                assert(narrow == 4.0f + 6.0fi);
            }
        });
    }
}

// The D spec gives imaginary types so that an operation does not "perform
// extra operations on the implied 0 real part": an absent half is never
// added to or subtracted from, so it cannot change the sign of a zero.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd adds a zero imaginary half to a real operand of `+`, and "
        ~ "which zeros keep their sign changes with -O; ldc follows the spec"),
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE drops the imaginary half of a complex plus a real"),
)) {
    @("complexArithmeticKeepsSignedZeros." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            bool negative(double value) { return 1.0 / value < 0; }

            void main() {
                cdouble c = -0.0 - 0.0i;
                double d = -0.0;
                idouble i = -0.0i;
                cdouble r = c + d;
                assert(negative(r.im));
                r = d + c;
                assert(negative(r.im));
                r = c + i;
                assert(negative(r.re));
                r = i + c;
                assert(negative(r.re));
                r = c - d;
                assert(negative(r.im));
                r = c - i;
                assert(negative(r.re));
                r = d - c;
                assert(!negative(r.re));
                r = i - c;
                assert(!negative(r.im));
                cdouble y = 1.0 + d * 1.0i;
                assert(negative(y.im));
                cdouble a = y; a++;
                assert(negative(a.im));
                cdouble b = y; b += 1;
                assert(negative(b.im));
                cdouble e = y; ++e;
                assert(negative(e.im));
                cdouble f = y; f--;
                assert(negative(f.im));
                cdouble g = y; g -= 1;
                assert(negative(g.im));
                cdouble h = y; --h;
                assert(negative(h.im));
            }
        });
    }
}

// Sibling pinning the divergence above: `dmd -g`, which builds this test,
// gives `c + d` and `d + c` a positive zero imaginary half. The same `+`
// bug reaches a postfix/compound/prefix `++` on a complex target, because
// each one adds a real step to the target's imaginary half; `--` does not
// diverge, since dmd's `-` keeps the sign dmd's own `+` loses.
@("complexArithmeticKeepsSignedZeros.Native")
@Tags(Native.stringof)
unittest {
    0.shouldBeStatusOf!(Native, q{
        bool negative(double value) { return 1.0 / value < 0; }

        void main() {
            cdouble c = -0.0 - 0.0i;
            double d = -0.0;
            cdouble r = c + d;
            assert(!negative(r.im));
            r = d + c;
            assert(!negative(r.im));
            cdouble y = 1.0 + d * 1.0i;
            cdouble a = y; a++;
            assert(!negative(a.im));
            cdouble b = y; b += 1;
            assert(!negative(b.im));
            cdouble e = y; ++e;
            assert(!negative(e.im));
        }
    });
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

// Vector arithmetic applies the operator lane by lane, and each lane wraps
// or rounds as its element type does. `++` and `--` add or subtract one in
// every lane.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot do vector arithmetic"),
)) {
    @("vectorArithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd:
                double2, float4, int4, long2, short8, ubyte16, uint4;

            void main() {
                int4 a = [1, 2, 3, 4];
                int4 b = [10, -20, 30, -40];
                assert((a + b).array == [11, -18, 33, -36]);
                assert((a - b).array == [-9, 22, -27, 44]);
                assert((a & b).array == [0, 0, 2, 0]);
                assert((a | b).array == [11, -18, 31, -36]);
                assert((a ^ b).array == [11, -18, 29, -36]);
                assert((-a).array == [-1, -2, -3, -4]);
                assert((~a).array == [-2, -3, -4, -5]);
                assert((a + 1).array == [2, 3, 4, 5]);
                a += b;
                assert(a.array == [11, -18, 33, -36]);
                a -= 1;
                assert(a.array == [10, -19, 32, -37]);
                a &= 0xff;
                assert(a.array == [10, 237, 32, 219]);
                a |= 256;
                assert(a.array == [266, 493, 288, 475]);
                a ^= 1;
                assert(a.array == [267, 492, 289, 474]);
                ubyte16 u = 200;
                ubyte16 v = 100;
                assert((u + v).array[0] == 44);
                uint4 w = [0, 1, 2, 3];
                assert((w - 1).array == [uint.max, 0, 1, 2]);
                short8 s = [1, -2, 3, -4, 5, -6, 7, 300];
                short8 t = 300;
                assert((s * t).array
                    == [300, -600, 900, -1200, 1500, -1800, 2100, 24464]);
                s *= t;
                assert(s.array[7] == 24464);
                long2 l = [long.max, -1];
                assert((l + 1).array == [long.min, 0]);
                float4 x = [1.0f, 2.0f, 3.0f, 4.0f];
                float4 y = [0.5f, 4.0f, -1.0f, 8.0f];
                assert((x + y).array == [1.5f, 6.0f, 2.0f, 12.0f]);
                assert((x - y).array == [0.5f, -2.0f, 4.0f, -4.0f]);
                assert((x * y).array == [0.5f, 8.0f, -3.0f, 32.0f]);
                assert((x / y).array == [2.0f, 0.5f, -3.0f, 0.5f]);
                assert((-x).array == [-1.0f, -2.0f, -3.0f, -4.0f]);
                x *= 2.0f;
                assert(x.array == [2.0f, 4.0f, 6.0f, 8.0f]);
                x /= y;
                assert(x.array == [4.0f, 1.0f, -6.0f, 1.0f]);
                double2 d = [1.5, -2.5];
                double2 e = [0.5, 0.5];
                assert((d + e).array == [2.0, -2.0]);
                assert((d / e).array == [3.0, -5.0]);
                d -= e;
                assert(d.array == [1.0, -3.0]);
                int4 old = b++;
                assert(old.array == [10, -20, 30, -40]);
                assert(b.array == [11, -19, 31, -39]);
                --b;
                float4 z = 1.0f;
                z--;
                assert(z.array == [0.0f, 0.0f, 0.0f, 0.0f]);
            }
        });
    }
}

// A write through a vector element changes the vector: plain assignment,
// compound assignment, `++`/`--`, and a write through the element's
// address all reach the same storage, whether indexed as `v[i]` or as
// `v.array[i]`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot write through a vector element"),
)) {
    @("vectorElementWriteChangesTheVector." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd: float4, int4;

            void main() {
                int4 v = [1, 2, 3, 4];
                v[0] = 10;
                assert(v.array == [10, 2, 3, 4]);
                v.array[1] = 20;
                assert(v.array == [10, 20, 3, 4]);
                v[0] += 5;
                assert(v.array == [15, 20, 3, 4]);
                v.array[1] += 5;
                assert(v.array == [15, 25, 3, 4]);
                v[2]++;
                assert(v.array == [15, 25, 4, 4]);
                v.array[3]++;
                assert(v.array == [15, 25, 4, 5]);
                --v[2];
                assert(v.array == [15, 25, 3, 5]);
                --v.array[3];
                assert(v.array == [15, 25, 3, 4]);
                *(&v[0]) = 100;
                assert(v.array == [100, 25, 3, 4]);
                *(&v.array[1]) = 200;
                assert(v.array == [100, 200, 3, 4]);

                float4 f = [1.0f, 2.0f, 3.0f, 4.0f];
                f[0] = 10.0f;
                assert(f.array == [10.0f, 2.0f, 3.0f, 4.0f]);
                f.array[1] = 20.0f;
                assert(f.array == [10.0f, 20.0f, 3.0f, 4.0f]);
                f[0] += 5.0f;
                assert(f.array == [15.0f, 20.0f, 3.0f, 4.0f]);
                f.array[1] *= 2.0f;
                assert(f.array == [15.0f, 40.0f, 3.0f, 4.0f]);
                f[2]++;
                assert(f.array == [15.0f, 40.0f, 4.0f, 4.0f]);
                f.array[3]--;
                assert(f.array == [15.0f, 40.0f, 4.0f, 3.0f]);
                *(&f[0]) = 100.0f;
                assert(f.array == [100.0f, 40.0f, 4.0f, 3.0f]);
                *(&f.array[1]) = 200.0f;
                assert(f.array == [100.0f, 200.0f, 4.0f, 3.0f]);
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

// dmd wraps a narrow compound-assignment target in the `CastExp` its own
// integral promotion adds. The load and the store must still use the
// target's own width, not the promoted `int`'s, or a neighbouring array
// element is read or written by mistake.
static foreach (backend; Matrix!()) {
    @("narrowCompoundAssignUsesTargetWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                {
                    byte[4] arr = [-10, -66, 55, 4];
                    ubyte step = 3;
                    arr[1] += step;
                    assert(arr[1] == -63 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] -= step;
                    assert(arr[1] == -66 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] *= step;
                    assert(arr[1] == 58 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] /= step;
                    assert(arr[1] == 19 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] %= step;
                    assert(arr[1] == 1 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = -66;
                    arr[1] &= step;
                    assert(arr[1] == 2 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = -66;
                    arr[1] |= step;
                    assert(arr[1] == -65 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = -66;
                    arr[1] ^= step;
                    assert(arr[1] == -67 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = -66;
                    arr[1] <<= 2;
                    assert(arr[1] == -8 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = -66;
                    arr[1] >>= 2;
                    assert(arr[1] == -17 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = -1;
                    arr[1] >>>= 1;
                    assert(arr[1] == 127 && arr[0] == -10 && arr[2] == 55
                        && arr[3] == 4);

                    byte b = -10;
                    ubyte ub = 3;
                    b /= ub;
                    assert(b == -3);
                }
                {
                    ubyte[4] arr = [200, 100, 55, 4];
                    ubyte step = 3;
                    arr[1] += step;
                    assert(arr[1] == 103 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] -= step;
                    assert(arr[1] == 100 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] *= step;
                    assert(arr[1] == 44 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] /= step;
                    assert(arr[1] == 14 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] %= step;
                    assert(arr[1] == 2 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = 100;
                    arr[1] &= step;
                    assert(arr[1] == 0 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = 100;
                    arr[1] |= step;
                    assert(arr[1] == 103 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = 100;
                    arr[1] ^= step;
                    assert(arr[1] == 103 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = 100;
                    arr[1] <<= 2;
                    assert(arr[1] == 144 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = 100;
                    arr[1] >>= 2;
                    assert(arr[1] == 25 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);
                    arr[1] = 255;
                    arr[1] >>>= 1;
                    assert(arr[1] == 127 && arr[0] == 200 && arr[2] == 55
                        && arr[3] == 4);

                    ubyte u2 = 2;
                    u2 -= step;
                    assert(u2 == 255);
                }
                {
                    short[4] arr = [-1000, -6600, 555, 4];
                    ushort step = 30;
                    arr[1] += step;
                    assert(arr[1] == -6570 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] -= step;
                    assert(arr[1] == -6600 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] *= step;
                    assert(arr[1] == -1392 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] /= step;
                    assert(arr[1] == -46 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] %= step;
                    assert(arr[1] == -16 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = -6600;
                    arr[1] &= step;
                    assert(arr[1] == 24 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = -6600;
                    arr[1] |= step;
                    assert(arr[1] == -6594 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = -6600;
                    arr[1] ^= step;
                    assert(arr[1] == -6618 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = -6600;
                    arr[1] <<= 2;
                    assert(arr[1] == -26400 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = -6600;
                    arr[1] >>= 2;
                    assert(arr[1] == -1650 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = -1;
                    arr[1] >>>= 1;
                    assert(arr[1] == 32767 && arr[0] == -1000
                        && arr[2] == 555 && arr[3] == 4);

                    short s2 = -9;
                    ushort u2 = 2;
                    s2 %= u2;
                    assert(s2 == -1);
                }
                {
                    ushort[4] arr = [60000, 6600, 555, 4];
                    ushort step = 30;
                    arr[1] += step;
                    assert(arr[1] == 6630 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] -= step;
                    assert(arr[1] == 6600 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] *= step;
                    assert(arr[1] == 1392 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] /= step;
                    assert(arr[1] == 46 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] %= step;
                    assert(arr[1] == 16 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = 6600;
                    arr[1] &= step;
                    assert(arr[1] == 8 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = 6600;
                    arr[1] |= step;
                    assert(arr[1] == 6622 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = 6600;
                    arr[1] ^= step;
                    assert(arr[1] == 6614 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = 6600;
                    arr[1] <<= 2;
                    assert(arr[1] == 26400 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = 6600;
                    arr[1] >>= 2;
                    assert(arr[1] == 1650 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                    arr[1] = 65535;
                    arr[1] >>>= 1;
                    assert(arr[1] == 32767 && arr[0] == 60000
                        && arr[2] == 555 && arr[3] == 4);
                }
                {
                    char[4] arr = ['a', 'z', 'm', 'q'];
                    ubyte step = 3;
                    arr[1] += step;
                    assert(arr[1] == 125 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] -= step;
                    assert(arr[1] == 122 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] *= step;
                    assert(arr[1] == 110 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] /= step;
                    assert(arr[1] == 36 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] %= step;
                    assert(arr[1] == 0 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] &= step;
                    assert(arr[1] == 2 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] |= step;
                    assert(arr[1] == 123 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] ^= step;
                    assert(arr[1] == 121 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] <<= 2;
                    assert(arr[1] == 232 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] >>= 2;
                    assert(arr[1] == 30 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 255;
                    arr[1] >>>= 1;
                    assert(arr[1] == 127 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                }
                {
                    wchar[4] arr = ['a', 'z', 'm', 'q'];
                    ushort step = 30;
                    arr[1] += step;
                    assert(arr[1] == 152 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] -= step;
                    assert(arr[1] == 122 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] *= step;
                    assert(arr[1] == 3660 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] /= step;
                    assert(arr[1] == 122 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] %= step;
                    assert(arr[1] == 2 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] &= step;
                    assert(arr[1] == 26 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] |= step;
                    assert(arr[1] == 126 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] ^= step;
                    assert(arr[1] == 100 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] <<= 2;
                    assert(arr[1] == 488 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 'z';
                    arr[1] >>= 2;
                    assert(arr[1] == 30 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                    arr[1] = 65535;
                    arr[1] >>>= 1;
                    assert(arr[1] == 32767 && arr[0] == 'a' && arr[2] == 'm'
                        && arr[3] == 'q');
                }
                {
                    bool[4] arr = [true, true, false, true];
                    bool step = true;
                    arr[1] &= step;
                    assert(arr[1] == true && arr[0] == true
                        && arr[2] == false && arr[3] == true);
                    arr[1] = true;
                    arr[1] |= step;
                    assert(arr[1] == true && arr[0] == true
                        && arr[2] == false && arr[3] == true);
                    arr[1] = true;
                    arr[1] ^= step;
                    assert(arr[1] == false && arr[0] == true
                        && arr[2] == false && arr[3] == true);
                }
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast an imaginary value to a pointer"),
)) {
    @("imaginaryAndComplexPointerCasts." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void* fromIfloat(ifloat value) { return cast(void*) value; }
            void* fromIdouble(idouble value) { return cast(void*) value; }
            void* fromIreal(ireal value) { return cast(void*) value; }
            void* fromCfloat(cfloat value) { return cast(void*) value; }
            void* fromCdouble(cdouble value) { return cast(void*) value; }
            void* fromCreal(creal value) { return cast(void*) value; }
            ifloat toIfloat(void* value) { return cast(ifloat) value; }
            idouble toIdouble(void* value) { return cast(idouble) value; }
            ireal toIreal(void* value) { return cast(ireal) value; }
            cfloat toCfloat(void* value) { return cast(cfloat) value; }
            cdouble toCdouble(void* value) { return cast(cdouble) value; }
            creal toCreal(void* value) { return cast(creal) value; }
            void main() {
                assert(fromIfloat(3.0i) == null);
                assert(fromIdouble(3.0i) == null);
                assert(fromIreal(3.0Li) == null);
                assert(fromCfloat(12.0f + 3.0fi) == cast(void*) 12);
                assert(fromCdouble(12.0 + 3.0i) == cast(void*) 12);
                assert(fromCreal(12.0L + 3.0Li) == cast(void*) 12);
                assert(toIfloat(cast(void*) 12) == 0.0fi);
                assert(toIdouble(cast(void*) 12) == 0.0i);
                assert(toIreal(cast(void*) 12) == 0.0Li);
                assert(toCfloat(cast(void*) 12) == 12.0f + 0.0fi);
                assert(toCdouble(cast(void*) 12) == 12.0 + 0.0i);
                assert(toCreal(cast(void*) 12) == 12.0L + 0.0Li);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a zero-size static array in this cast"),
)) {
    @("staticArrayOfZeroSizedElementsRetainsSliceLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[0][] asSlice(ref int[0][2] values) {
                return cast(int[0][]) values;
            }
            void main() {
                int[0][2] values;
                auto slice = asSlice(values);
                assert(slice.length == 2);
                assert(cast(void*) slice.ptr == cast(void*) &values);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("compoundAssignFieldsOfDifferentTypesInMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Owner {
                byte pad = 9;
                double d = 1.5;
                long l = 20;
                double run() {
                    d += 0.5;
                    l <<= 1;
                    return d + l;
                }
            }
            int main() {
                Owner owner;
                return owner.run == 42.0 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("shiftLongFieldThroughThisByInt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Owner {
                long value = 20;
                void run() { value <<= 1; }
            }
            int main() {
                Owner owner;
                owner.run;
                return owner.value == 40 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("powAssignLongByInt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                long value = 3;
                int exponent = 3;
                value ^^= exponent;
                return value == 27 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "CTFE converts a floating step to the integral target before the "
        ~ "operation: pinned by the `.Ctfe.diverges` test of the same name"),
)) {
    @("mulAssignUintByReal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                uint value = 20;
                real factor = 2.5;
                value *= factor;
                return value == 50 ? 0 : 1;
            }
        });
    }
}

@("mulAssignUintByReal.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
        int main() {
            uint value = 20;
            real factor = 2.5;
            value *= factor;
            return value == 40 ? 0 : 1;
        }
    });
}

static foreach (backend; Matrix!()) {
    @("addAssignIntFieldThroughThisByDouble." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Owner {
                byte pad = 9;
                int value = 20;
                void run(double step) { value += step; }
            }
            int main() {
                Owner owner;
                owner.run(2.5);
                return owner.value == 22 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "CTFE converts a floating step to the integral target before the "
        ~ "operation: pinned by the `.Ctfe.diverges` test of the same name"),
)) {
    @("mulAssignIntArrayElementByDouble." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int[2] values = [1, 21];
                double factor = 2.5;
                values[1] *= factor;
                return values[0] == 1 && values[1] == 52 ? 0 : 1;
            }
        });
    }
}

@("mulAssignIntArrayElementByDouble.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
        int main() {
            int[2] values = [1, 21];
            double factor = 2.5;
            values[1] *= factor;
            return values[0] == 1 && values[1] == 42 ? 0 : 1;
        }
    });
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable static variable"),
)) {
    @("addAssignIntStaticByDouble." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int value = 20;
            int main() {
                double step = 2.5;
                value += step;
                return value == 22 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("addAssignIntGivesTheStoredValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int value = 20;
                double step = 2.5;
                const result = (value += step);
                return result == 22 && value == 22 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE converts the step to the integral target and reads the " ~
        "target after the step: pinned by " ~
        "`addAssignIntReadsTheTargetBeforeTheStep.Ctfe.diverges`"),
)) {
    @("addAssignIntReadsTheTargetBeforeTheStep." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            double step(ref int value) { value = 5; return 2.5; }
            int main() {
                int value = 20;
                value += step(value);
                return value == 22 ? 0 : 1;
            }
        });
    }
}

@("addAssignIntReadsTheTargetBeforeTheStep.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
        double step(ref int value) { value = 5; return 2.5; }
        int main() {
            int value = 20;
            value += step(value);
            return value == 7 ? 0 : 1;
        }
    });
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE divides in 64 bits: pinned by `divAssignIntByUintDividesUnsigned.Ctfe.diverges`"),
)) {
    @("divAssignIntByUintDividesUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int value = -5;
                uint divisor = 7;
                value /= divisor;
                return value == 613_566_755 ? 0 : 1;
            }
        });
    }
}

@("divAssignIntByUintDividesUnsigned.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
            int main() {
                int value = -5;
                uint divisor = 7;
                value /= divisor;
                return value == -1_840_700_271 ? 0 : 1;
            }
    });
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE divides in 64 bits: pinned by `modAssignIntByUintGivesTheUnsignedRemainder.Ctfe.diverges`"),
)) {
    @("modAssignIntByUintGivesTheUnsignedRemainder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int value = -5;
                uint divisor = 7;
                value %= divisor;
                return value == 6 ? 0 : 1;
            }
        });
    }
}

@("modAssignIntByUintGivesTheUnsignedRemainder.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
            int main() {
                int value = -5;
                uint divisor = 7;
                value %= divisor;
                return value == 4 ? 0 : 1;
            }
    });
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE divides in 64 bits: pinned by `divAssignByteByUintDividesUnsigned.Ctfe.diverges`"),
)) {
    @("divAssignByteByUintDividesUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                byte value = -5;
                uint divisor = 7;
                value /= divisor;
                return value == 35 ? 0 : 1;
            }
        });
    }
}

@("divAssignByteByUintDividesUnsigned.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
            int main() {
                byte value = -5;
                uint divisor = 7;
                value /= divisor;
                return value == -111 ? 0 : 1;
            }
    });
}

static foreach (backend; Matrix!()) {
    @("divIntByUintDividesUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int value = -5;
                uint divisor = 7;
                return value / divisor == 613_566_755 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("modIntByUintGivesTheUnsignedRemainder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int value = -5;
                uint divisor = 7;
                return value % divisor == 6 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("modAssignUintByNegativeIntUsesTheUnsignedDivisor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                uint value = 5;
                int divisor = -7;
                value %= divisor;
                return value == 5 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("addAssignBitFieldGivesTheStoredValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Bits { uint low : 5; }
            int main() {
                Bits bits;
                bits.low = 10;
                const result = (bits.low += 30);
                return result == 8 && bits.low == 8 ? 0 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("addAssignSignedBitFieldGivesTheStoredValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Bits { int low : 5; }
            int main() {
                Bits bits;
                bits.low = 10;
                const result = (bits.low += 10);
                return result == -12 && bits.low == -12 ? 0 : 1;
            }
        });
    }
}

// `byte.min / -1` divides the promoted `int` operands, and `128` fits.
static foreach (backend; Matrix!()) {
    @("arrayOperationOfSmallestByteDividedByMinusOneIsNotAnOverflow."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            byte[] a = [byte.min, 6];
            byte[] b = [-1, 1];
            byte[2] c;
            c[] = a[] / b[];
            return c[0] == byte.min ? 0 : 1;
        }
        });
    }
}

// `a /= b` on a `byte` divides the promoted `int` operands: `-128 / -1` is
// `128`, which fits in an `int`, and the assignment truncates it. The
// hardware does not trap, so this is no fault.
static foreach (backend; Matrix!()) {
    @("narrowDivideAssignIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        byte lowest() { return byte.min; }
        byte minusOne() { return -1; }

        int main() {
            byte value = lowest();
            value /= minusOne();
            return value == byte.min ? 0 : 1;
        }
        });
    }
}

// `a /= b` with an `int` target and a `long` divisor divides as `long`:
// `int.min / -1L` is `2147483648L`, which fits. No fault.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects `int.min /= -1L` as an integer overflow"),
)) {
    @("wideDivisorDivideAssignIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int lowest() { return int.min; }
        long minusOne() { return -1; }

        int main() {
            int value = lowest();
            value /= minusOne();
            return value == int.min ? 0 : 1;
        }
        });
    }
}

// `byte.min / -1` divides the promoted `int` operands, and `128` fits.
static foreach (backend; Matrix!()) {
    @("narrowDivisionIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        byte lowest() { return byte.min; }
        byte minusOne() { return -1; }

        int main() {
            return lowest() / minusOne() == 128 ? 0 : 1;
        }
        });
    }
}

// `int.min / -1L` divides as `long`, and `2147483648L` fits.
static foreach (backend; Matrix!()) {
    @("wideDivisorDivisionIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int lowest() { return int.min; }
        long minusOne() { return -1; }

        int main() {
            return lowest() / minusOne() == 2147483648L ? 0 : 1;
        }
        });
    }
}

// A floating point remainder by zero is `nan`, not a trap.
static foreach (backend; Matrix!()) {
    @("floatingModuloByZeroIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        double zero() { return 0; }

        int main() {
            const remainder = 1.0 % zero();
            return remainder != remainder ? 0 : 1;
        }
        });
    }
}

// A floating point division by zero is `inf`, not a trap.
static foreach (backend; Matrix!()) {
    @("floatingDivisionByZeroIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        double zero() { return 0; }

        int main() {
            const quotient = 1.0 / zero();
            return quotient == double.infinity ? 0 : 1;
        }
        });
    }
}

// Compound assignment and increment on a narrow integral type operate at
// `int` width and store only the low bytes back. Each expectation is
// computed with plain `int` arithmetic and a cast, a form without the
// compound operator, and each test runs it against one kind of lvalue.
// A signed `>>>=` shifts the value at its own width, so the expectation
// shifts the unsigned type of the same width.
private enum compoundPrelude = q{
    immutable int[] starts = [
        0, 1, 2, 100, 127, 128, 129, 200, 255, 256, 32767, 32768, 65535,
        -1, -2, -100, -128, -129, -32768,
    ];
    immutable int[] operands = [1, 3, 200];
    immutable int[] counts = [1, 3];

    T expectedAfter(T, string op)(int start, int rhs) {
        static if (op == ">>>") {
            static if (is(T == byte)) alias W = ubyte;
            else static if (is(T == short)) alias W = ushort;
            else alias W = T;
            return cast(T)(cast(W) cast(T) start >>> rhs);
        } else {
            return cast(T) mixin("cast(int) cast(T) start " ~ op ~ " rhs");
        }
    }

    void sweep(T)() {
        static foreach (op; ["+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>", ">>>"]) {
            foreach (start; starts)
                foreach (rhs; op == "<<" || op == ">>" || op == ">>>" ? counts : operands)
                    cell!(T, op)(start, rhs);
        }
    }

    void main() {
        sweep!byte;
        sweep!ubyte;
        sweep!short;
        sweep!ushort;
        sweep!char;
        sweep!wchar;
    }
};

private enum stepPrelude = q{
    immutable int[] starts = [
        0, 1, 2, 100, 127, 128, 129, 200, 255, 256, 32767, 32768, 65535,
        -1, -2, -100, -128, -129, -32768,
    ];

    T moved(T)(int start, int delta) {
        return cast(T)(cast(int) cast(T) start + delta);
    }

    void sweep(T)() {
        static foreach (i, pre; ["++", "--", "", ""]) {
            foreach (start; starts)
                step!(T, pre, ["", "", "++", "--"][i])(start, i % 2 ? -1 : 1, i >= 2);
        }
    }

    void main() {
        sweep!byte;
        sweep!ubyte;
        sweep!short;
        sweep!ushort;
        sweep!char;
        sweep!wchar;
    }
};

static foreach (backend; Matrix!()) {
    @("narrowCompoundAssignmentOnLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, compoundPrelude ~ q{
            void cell(T, string op)(int start, int rhs) {
                const expected = expectedAfter!(T, op)(start, rhs);
                T value = cast(T) start;
                T result = mixin("value " ~ op ~ "= rhs");
                assert(result == expected);
                assert(value == expected);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowCompoundAssignmentOnStructField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, compoundPrelude ~ q{
            struct Fields(T) { T before; T field; T after; }

            void cell(T, string op)(int start, int rhs) {
                const expected = expectedAfter!(T, op)(start, rhs);
                Fields!T fields = Fields!T(cast(T) 17, cast(T) start, cast(T) 99);
                T result = mixin("fields.field " ~ op ~ "= rhs");
                assert(result == expected);
                assert(fields.field == expected);
                assert(fields.before == 17 && fields.after == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowCompoundAssignmentThroughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, compoundPrelude ~ q{
            void cell(T, string op)(int start, int rhs) {
                const expected = expectedAfter!(T, op)(start, rhs);
                T[3] storage = [cast(T) 17, cast(T) start, cast(T) 99];
                T* pointer = &storage[1];
                T result = mixin("*pointer " ~ op ~ "= rhs");
                assert(result == expected);
                assert(storage[1] == expected);
                assert(storage[0] == 17 && storage[2] == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowCompoundAssignmentOnSliceElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, compoundPrelude ~ q{
            void cell(T, string op)(int start, int rhs) {
                const expected = expectedAfter!(T, op)(start, rhs);
                T[3] storage = [cast(T) 17, cast(T) start, cast(T) 99];
                T[] slice = storage[];
                T result = mixin("slice[1] " ~ op ~ "= rhs");
                assert(result == expected);
                assert(storage[1] == expected);
                assert(storage[0] == 17 && storage[2] == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowIncrementOnLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, stepPrelude ~ q{
            void step(T, string pre, string post)(int start, int delta, bool givesOld) {
                T value = cast(T) start;
                T result = mixin(pre ~ "value" ~ post);
                assert(value == moved!T(start, delta));
                assert(result == (givesOld ? cast(T) start : moved!T(start, delta)));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowIncrementOnStructField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, stepPrelude ~ q{
            struct Fields(T) { T before; T field; T after; }

            void step(T, string pre, string post)(int start, int delta, bool givesOld) {
                Fields!T fields = Fields!T(cast(T) 17, cast(T) start, cast(T) 99);
                T result = mixin(pre ~ "fields.field" ~ post);
                assert(fields.field == moved!T(start, delta));
                assert(result == (givesOld ? cast(T) start : moved!T(start, delta)));
                assert(fields.before == 17 && fields.after == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowIncrementThroughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, stepPrelude ~ q{
            void step(T, string pre, string post)(int start, int delta, bool givesOld) {
                T[3] storage = [cast(T) 17, cast(T) start, cast(T) 99];
                T* pointer = &storage[1];
                T result = mixin(pre ~ "(*pointer)" ~ post);
                assert(storage[1] == moved!T(start, delta));
                assert(result == (givesOld ? cast(T) start : moved!T(start, delta)));
                assert(storage[0] == 17 && storage[2] == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("narrowIncrementOnSliceElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, stepPrelude ~ q{
            void step(T, string pre, string post)(int start, int delta, bool givesOld) {
                T[3] storage = [cast(T) 17, cast(T) start, cast(T) 99];
                T[] slice = storage[];
                T result = mixin(pre ~ "slice[1]" ~ post);
                assert(storage[1] == moved!T(start, delta));
                assert(result == (givesOld ? cast(T) start : moved!T(start, delta)));
                assert(storage[0] == 17 && storage[2] == 99);
            }
        });
    }
}
