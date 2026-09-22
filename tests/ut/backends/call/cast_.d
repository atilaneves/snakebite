module ut.backends.call.cast_;


import ut.backends;


// A cast between vectors of equal width reinterprets the bits of all lanes.
// It is not a per-lane conversion. DMD's SIMD intrinsics declare their
// parameters as `__vector(void[16])`, so code that reaches them casts
// through that void vector shape and expects the lanes to come back intact.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot reinterpret overlapping union fields"),
)) {
    @("cast.vector.preservesBits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            union Input {
                int[4] lanes;
                __vector(int[4]) packed;
            }

            void main() {
                Input input;
                input.lanes = [1, -2, int.min, int.max];
                auto bytes = cast(__vector(void[16])) input.packed;
                auto restored = cast(__vector(int[4])) bytes;
                auto lanes = cast(int[4]*) &restored;
                assert((*lanes)[0] == 1);
                assert((*lanes)[1] == -2);
                assert((*lanes)[2] == int.min);
                assert((*lanes)[3] == int.max);
            }
        });
    }
}


// Dropping function attributes must preserve both the callable and its
// context, including when the conversion supplies a constructor argument.
static foreach (backend; Matrix!()) {
    @("cast.delegate.weakenAttributes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            alias Strong = void delegate(in string[], in string[])
                pure nothrow @nogc @safe;
            alias Weak = void delegate(in string[], in string[]);

            struct Counter {
                int value;

                void add(in string[] left, in string[] right)
                    pure nothrow @nogc @safe {
                    value += cast(int) (left.length * 10 + right.length);
                }
            }

            struct Handler {
                Weak callback;
                this(Weak callback) {
                    this.callback = callback;
                }
            }

            int result() {
                Counter counter;
                Strong source = &counter.add;
                auto handler = Handler(source);
                handler.callback(["a", "b"], ["c"]);
                auto converted = cast(Weak) source;
                converted(["d", "e"], ["f"]);

                Strong missing;
                Weak empty = missing;
                if (empty !is null)
                    return -1;
                return counter.value;
            }
        }, "result");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "CTFE does not preserve storage aliasing through this void[] cast"),
)) {
    @("cast.voidSliceToSharedStructPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Impl { int count; }

                shared(Impl)* allocateImpl(void[] bytes) {
                    return cast(shared(Impl)*) bytes;
                }

                int result() {
                    Impl[1] storage;
                    void[] bytes = cast(void[]) storage[];
                    auto pointer = allocateImpl(bytes);
                    pointer.count = 42;
                    return storage[0].count;
                }
            },
            "result",
        );
    }
}


static foreach (backend; Matrix!()) {
    @("cast.nullValueToString." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            typeof(null) value(ref int calls) {
                ++calls;
                return null;
            }

            string convert(typeof(null) source) {
                return cast(string) source;
            }

            void main() {
                int calls;
                string result = "old value";
                result = cast(string) value(calls);
                assert(calls == 1);
                assert(result.length == 0);
                assert(result.ptr is null);
                result = convert(null);
                assert(result.length == 0);
                assert(result.ptr is null);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("cast.staticArrayToSliceAliasesStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        24.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int[2] storage = void;
                    int[] first = cast(int[]) storage;
                    first[0] = 4;
                    int[] second = cast(int[]) storage;
                    return cast(int) second.length * 10 + second[0];
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.immutableSliceToMutablePointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool nonNull() {
                    string value = "hello";
                    char* pointer = cast(char*) value;
                    return pointer !is null;
                }
            },
            "nonNull",
        );
    }
}


// `5_000_000_000` needs 33 bits, so its low 32 bits - what `cast(int)`
// keeps - differ from the value itself. An implementation that clamps or
// saturates instead of truncating fails this.
static foreach (backend; Matrix!()) {
    @("cast.narrowing.truncates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        705_032_704.shouldBeRetOf!(
            backend,
            q{
                long big() {
                    return 5_000_000_000L;
                }

                int narrowed() {
                    return cast(int) big();
                }
            },
            "narrowed",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.floatToDouble.widensValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5.shouldBeRetOf!(
            backend,
            q{
                float source() {
                    return 1.5f;
                }

                double widened() {
                    return cast(double) source();
                }
            },
            "widened",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.doubleToFloat.roundsValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        16_777_216.0f.shouldBeRetOf!(
            backend,
            q{
                double source() {
                    return 16_777_217.0;
                }

                float narrowed() {
                    return cast(float) source();
                }
            },
            "narrowed",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.floatToIntegral.truncatesTowardZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-3L).shouldBeRetOf!(
            backend,
            q{
                double source() {
                    return -3.75;
                }

                long truncated() {
                    return cast(long) source();
                }
            },
            "truncated",
        );
    }
}

// Widening a signed operand copies its sign bit into the new high bits, so
// `cast(long)` of a negative `int` stays negative. An implementation that
// zero-extends instead answers a large positive value.
static foreach (backend; Matrix!()) {
    @("cast.widening.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-5L).shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -5;
                }

                long widened() {
                    return cast(long) negative();
                }
            },
            "widened",
        );
    }
}

// Widening an unsigned operand fills the new high bits with zero, so
// `cast(long)` of `uint.max` is the same positive value, not -1. An
// implementation that sign-extends instead answers -1.
static foreach (backend; Matrix!()) {
    @("cast.widening.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4_294_967_295L.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                long widened() {
                    return cast(long) top();
                }
            },
            "widened",
        );
    }
}

// The shape the array code needs: a `size_t` (the array's own length,
// 8 bytes) narrowed to an `int` (4 bytes). The string literal isolates the
// cast from array support, which is exercised on its own elsewhere.
static foreach (backend; Matrix!()) {
    @("cast.narrowLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                string greeting() {
                    return "hello";
                }

                int length_() {
                    return cast(int) greeting().length;
                }
            },
            "length_",
        );
    }
}

// A pointer-to-integral cast preserves the native address bits. The local
// array makes the pointer values runtime values, and its two elements show
// that the bits preserve an `int`-sized address offset, not only non-null.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a pointer to an integral type"),
)) {
    @("cast.pointerToUlong.preservesAddressOffset." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool pointerBitsPreserveOffset() {
                    int[2] values;
                    int* first = &values[0];
                    int* second = &values[1];
                    return cast(ulong) second - cast(ulong) first
                        == int.sizeof;
                }
            },
            "pointerBitsPreserveOffset",
        );
    }
}

// `cast(void[])` of a `T[]` scales the length by `T.sizeof`, the same
// conversion `core.internal.array.appending` applies before calling
// `gc_expandArrayUsed`/`gc_shrinkArrayUsed`, both of which take `void[]`.
// `int.sizeof` (4) isolates the scaling from a verbatim `{length, ptr}`
// copy: a 1-byte element would leave the length unchanged and the two
// implementations indistinguishable.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE keeps a `cast(void[])` array's length as an " ~
        "element count, not a byte count - pinned below"),
)) {
    @("cast.arrayToVoid.scalesLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(12).shouldBeRetOf!(
            backend,
            q{
                int[] ints() {
                    return [1, 2, 3];
                }

                size_t voidLength() {
                    void[] bytes = cast(void[]) ints();
                    return bytes.length;
                }
            },
            "voidLength",
        );
    }
}

// dmd's own CTFE does not scale the length through a `cast(void[])` the
// way runtime D does - pins the divergence; the native side (checked
// above for every other backend) scales it.
@("cast.arrayToVoid.scalesLength.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    size_t(3).shouldBeRetOf!(
        Ctfe,
        q{
            int[] ints() {
                return [1, 2, 3];
            }

            size_t voidLength() {
                void[] bytes = cast(void[]) ints();
                return bytes.length;
            }
        },
        "voidLength",
    );
}

// `16_777_217` is `2^24 + 1`, the first integer a `float`'s 24-bit
// significand cannot hold, so D's integral-to-floating conversion rounds
// it to the nearest representable value, `16_777_216`. The operand comes
// from a function call because dmd folds a cast of a literal during
// semantic analysis, so a literal operand would never reach a backend. An
// implementation that converts through a wider intermediate and rounds
// once more, or that reinterprets the operand's bits, fails this.
static foreach (backend; Matrix!()) {
    @("cast.ulongToFloat.roundsToFloatPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        16_777_216.0f.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 16_777_217UL;
                }

                float converted() {
                    return cast(float) bits();
                }
            },
            "converted",
        );
    }
}

// The same operand as the `float` test above: a `double`'s 53-bit
// significand holds `2^24 + 1` exactly, so the conversion is exact. An
// implementation that converts every floating destination at `float`
// precision fails this while passing the `float` test.
static foreach (backend; Matrix!()) {
    @("cast.ulongToDouble.isExact." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        16_777_217.0.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 16_777_217UL;
                }

                double converted() {
                    return cast(double) bits();
                }
            },
            "converted",
        );
    }
}

// A runtime `ulong` reduced by `%`, converted to `float`, then divided
// and offset: dmd's usual arithmetic conversions turn `1_000_000` and `1`
// into `float` operands, so after the cast every operation is
// floating-point. `3_500_001 % 2_000_001` is `1_500_000`, and
// `1.5 - 1.0` is exact at every precision, so the expectation does not
// depend on rounding. The operand comes from a function call because dmd
// folds literal-only arithmetic during semantic analysis.
static foreach (backend; Matrix!()) {
    @("cast.ulongToFloat.thenDivideAndSubtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.5f.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 3_500_001UL;
                }

                float value() {
                    return cast(float) (bits() % 2_000_001) / 1_000_000 - 1;
                }
            },
            "value",
        );
    }
}

// As above, with a `double` destination: the conversions of `1_000_000`
// and `1` follow the cast's own type, so the whole chain runs at `double`
// precision instead.
static foreach (backend; Matrix!()) {
    @("cast.ulongToDouble.thenDivideAndSubtract." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.5.shouldBeRetOf!(
            backend,
            q{
                ulong bits() {
                    return 3_500_001UL;
                }

                double value() {
                    return cast(double) (bits() % 2_000_001) / 1_000_000 - 1;
                }
            },
            "value",
        );
    }
}

// `real` widening to `double`: exact, since `double` is narrower than
// `real` but the operand here fits in both. The operand comes from a
// call because dmd folds a cast of a literal during semantic analysis.
static foreach (backend; Matrix!()) {
    @("cast.realToDouble." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5.shouldBeRetOf!(
            backend,
            q{
                real value() {
                    return 1.5L;
                }

                double converted() {
                    return cast(double) value();
                }
            },
            "converted",
        );
    }
}

// `real` narrowing to `float`, and back again to `real`. `1.5` is exact
// at every one of the three widths, so the round trip does not depend on
// rounding.
static foreach (backend; Matrix!()) {
    @("cast.realToFloat." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5f.shouldBeRetOf!(
            backend,
            q{
                real value() {
                    return 1.5L;
                }

                float converted() {
                    return cast(float) value();
                }
            },
            "converted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.doubleToReal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5L.shouldBeRetOf!(
            backend,
            q{
                double value() {
                    return 1.5;
                }

                real converted() {
                    return cast(real) value();
                }
            },
            "converted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("cast.floatToReal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.5L.shouldBeRetOf!(
            backend,
            q{
                float value() {
                    return 1.5f;
                }

                real converted() {
                    return cast(real) value();
                }
            },
            "converted",
        );
    }
}

// dmd classifies `bool` as `integral | unsigned`, so a naive integral
// narrowing takes the operand's low byte instead of comparing it against
// zero. `256`'s low byte is `0`, which a truncating implementation would
// store as `false` - D specifies `cast(bool) 256` as `true`.
static foreach (backend; Matrix!()) {
    @("cast.bool.nonZeroIsTrue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int wide() {
                    return 256;
                }

                bool truthy() {
                    return cast(bool) wide();
                }
            },
            "truthy",
        );
    }
}

// Floating truth conversion tests the value before integral truncation:
// `cast(bool) 0.5` is true while zero remains false.
static foreach (backend; Matrix!()) {
    @("cast.bool.fractionalNonZeroIsTrue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                double source() { return 0.5; }
                double zero() { return 0.0; }

                bool result() {
                    return cast(bool) source() && !cast(bool) zero();
                }
            },
            "result",
        );
    }
}


// `cast(T) null` where `T` is a delegate: two words, both zero.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read `dg.ptr`"),
)) {
    @("cast.null.delegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool isNull() {
                    void delegate() dg = cast(void delegate()) null;
                    return dg.ptr is null && dg.funcptr is null;
                }
            },
            "isNull",
        );
    }
}

// `cast(bool) null` is `false`, `cast(size_t) null` is `0`.
static foreach (backend; Matrix!()) {
    @("cast.null.arithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool zero() {
                    bool b = cast(bool) null;
                    size_t s = cast(size_t) null;
                    ubyte u = cast(ubyte) null;
                    return !b && s == 0 && u == 0;
                }
            },
            "zero",
        );
    }
}

// A null cast in a narrow-width context: the destination is an `int`
// field of a struct, so a 16-byte zero fill would clobber a neighbour.
static foreach (backend; Matrix!()) {
    @("cast.null.neighbourField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct S {
                    int a;
                    int b;
                    int c;
                }

                bool keepsNeighbours() {
                    S s = S(1, 2, 3);
                    s.b = cast(int) null;
                    return s.a == 1 && s.b == 0 && s.c == 3;
                }
            },
            "keepsNeighbours",
        );
    }
}
