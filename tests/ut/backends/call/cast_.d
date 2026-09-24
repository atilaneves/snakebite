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

// The reverse of `cast.pointerToUlong.preservesAddressOffset`: an
// integral-to-pointer cast preserves the same native bits, so converting a
// `ulong` to `void*` and back gives the original value unchanged. This is
// the exact shape `core.stdc.stdarg.alignUp` runs as guest code (`return
// cast(T) b;` where `T` is `void*` and `b` is a `size_t`), which both the
// bytecode compiler and the interpreter used to reject outright.
static foreach (backend; Matrix!()) {
    @("cast.ulongToVoidPointer.roundTrips." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool roundTrips() {
                    ulong original = 0x1234_5678;
                    void* pointer = cast(void*) original;
                    return cast(ulong) pointer == original;
                }
            },
            "roundTrips",
        );
    }
}

// `alignUp`'s own shape: round an address up to a `size_t` boundary through
// an integral, then cast it back to a real pointer that is then
// dereferenced. Isolates the arithmetic `cast(int*) (cast(size_t) p + 4)`
// performs from `alignUp`'s masking, showing the resulting pointer really
// does address the array's next element rather than only carrying the
// right bit pattern.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a pointer to an integral type"),
)) {
    @("cast.sizeTToPointer.pointsToNextElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        99.shouldBeRetOf!(
            backend,
            q{
                int next() {
                    int[2] values = [1, 99];
                    int* first = &values[0];
                    size_t address = cast(size_t) first;
                    int* second = cast(int*) (address + int.sizeof);
                    return *second;
                }
            },
            "next",
        );
    }
}

// A pointer-to-integral cast to a narrower destination keeps only the low
// bytes, the same truncation an ordinary narrowing integral cast performs -
// `pointerToIntegral` is not itself new, but nothing previously exercised
// it at a width narrower than the pointer's own. The address itself is a
// runtime value nothing here can predict, so the check compares the direct
// `ubyte` truncation against the already-proven `ulong` round trip
// (`cast.pointerToUlong.preservesAddressOffset`) narrowed the same way an
// ordinary integral cast narrows, rather than asserting a specific byte.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a pointer to an integral type"),
)) {
    @("cast.pointerToUbyte.truncates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool truncatesLowByte() {
                    int[2] values;
                    int* p = &values[0];
                    ubyte direct = cast(ubyte) p;
                    ulong full = cast(ulong) p;
                    return direct == cast(ubyte) full;
                }
            },
            "truncatesLowByte",
        );
    }
}

// Converting a narrower signed integral to a pointer sign-extends exactly
// as widening that same value to a wider integral would - `cast(void*)
// someNegativeInt` fills the pointer's high bits with the sign bit, not
// with zero. An implementation that zero-extends instead loses the
// negative int's high bits and answers a different, wrong address.
static foreach (backend; Matrix!()) {
    @("cast.intToPointer.signExtendsNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool matchesWidenedValue() {
                    int negative = -5;
                    void* pointer = cast(void*) negative;
                    long widened = cast(long) negative;
                    return cast(long) pointer == widened;
                }
            },
            "matchesWidenedValue",
        );
    }
}

// `cast(bool)` on a pointer tests it for non-null, the same nonzero test
// `cast(bool)` on an integral already runs - dmd allows this cast directly
// on a pointer (including a function pointer, the same `Tpointer` shape),
// unlike a class reference or a delegate, which dmd's own frontend refuses
// to cast to `bool` at all.
static foreach (backend; Matrix!()) {
    @("cast.pointerToBool.nonNullIsTrue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool bothDirections() {
                    int value;
                    int* present = &value;
                    int* absent;
                    return cast(bool) present && !cast(bool) absent;
                }
            },
            "bothDirections",
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

// An associative array is one pointer-sized handle natively - `cast(void*)`
// of an empty AA (no backing store allocated yet) is the null handle, and
// inserting a key gives it a real, non-null one. `source/dub/internal/
// undead/xml.d`'s `Tag.opCmp` relies on exactly this to compare two AAs by
// handle identity (issue: the bytecode compiler rejected the cast
// outright, `cast a from const(string[string]) to void* in opCmp`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE refuses `pointer cast from int[int] to void* is not " ~
        "supported at compile time` for a non-empty AA"),
)) {
    @("cast.aaToPointer.matchesHandle." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool matchesHandle() {
                    int[int] empty;
                    if (cast(void*) empty !is null)
                        return false;

                    int[int] filled;
                    filled[1] = 2;
                    if (cast(void*) filled is null)
                        return false;

                    return cast(void*) filled is cast(void*) filled;
                }
            },
            "matchesHandle",
        );
    }
}

// The exact shape `source/dub/internal/undead/xml.d`'s `Tag.opCmp` runs: a
// `const` associative-array field, read through a `const` method, compared
// by casting both sides to `void*` - `attr != tag.attr` (AA equality) picks
// the branch, `cast(void*) attr < cast(void*) tag.attr` (pointer identity)
// only orders the tie. `T.init`'s AA field is empty, so `left`'s handle is
// null and `right`'s is not; a working cast makes them compare unequal by
// pointer, giving a deterministic ordering.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE refuses `pointer cast from int[int] to void* is not " ~
        "supported at compile time` for a non-empty AA"),
)) {
    @("cast.aaToPointer.opCmpShape." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Tag {
                    const int[int] attr;

                    const int opCmp(Tag other) {
                        return attr != other.attr
                            ? (cast(void*) attr < cast(void*) other.attr
                                ? -1 : 1)
                            : 0;
                    }
                }

                bool comparesByHandle() {
                    Tag left;
                    int[int] filled;
                    filled[1] = 2;
                    Tag right = Tag(filled);
                    return left.opCmp(right) != 0;
                }
            },
            "comparesByHandle",
        );
    }
}

// The reverse of `cast.aaToPointer.matchesHandle`: `cast(int[int])
// somePointer` is the same bit-preserving cast in the other direction, so
// round-tripping a real AA's handle through `void*` and back gives an AA
// that still holds the same key.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE refuses `pointer cast from int[int] to void* is not " ~
        "supported at compile time` for a non-empty AA"),
)) {
    @("cast.pointerToAA.roundTrips." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                int roundTrips() {
                    int[int] original;
                    original[1] = 2;
                    void* handle = cast(void*) original;
                    int[int] restored = cast(int[int]) handle;
                    return restored[1];
                }
            },
            "roundTrips",
        );
    }
}

// `cast(void*) someDelegate` is deprecated (superseded by `.ptr`) but still
// accepted by dmd's frontend, which keeps only the delegate's context word
// - the same word `dg.ptr` itself reads.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read `dg.ptr`"),
)) {
    @("cast.delegateToPointer.matchesContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int value;
                    void bump() { value++; }
                }

                bool matchesContext() {
                    Counter counter;
                    void delegate() dg = &counter.bump;
                    void* p = cast(void*) dg;
                    return p is dg.ptr;
                }
            },
            "matchesContext",
        );
    }
}


// `complex`/`imaginary` are deprecated but still full members of the
// language: `cast(bool)` is true when either component is nonzero -
// either alone is enough, unlike an integral or plain real operand,
// which have only the one word to test.
static foreach (backend; Matrix!()) {
    @("cast.complexToBool.trueOnRealComponent." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cfloat c = 1.0f + 0.0fi;
                assert(cast(bool) c);
            }
        });
    }

    @("cast.complexToBool.trueOnImaginaryComponent." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cfloat c = 0.0f + 2.0fi;
                assert(cast(bool) c);
            }
        });
    }

    @("cast.complexToBool.falseOnZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cdouble c = 0.0 + 0.0i;
                assert(!cast(bool) c);
            }
        });
    }

    // `if (someComplex)` shares `Truth` with `cast(bool)` above, so it
    // gets the same either-component rule.
    @("cast.complexToBool.conditionSharesRule." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cdouble c = 0.0 + 3.0i;
                if (c) {} else assert(false);
            }
        });
    }
}


// `cast(double) someComplex`/`someComplex.re`: the real component alone.
static foreach (backend; Matrix!()) {
    @("cast.complexToReal.takesRealComponent." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cdouble c = 3.0 + 4.0i;
                double d = cast(double) c;
                assert(d == 3.0);
            }
        });
    }

    @("cast.complexToReal.field." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cdouble c = 3.0 + 4.0i;
                assert(c.re == 3.0);
            }
        });
    }
}


// `cast(cdouble) someDouble`: the real axis carries the value, the
// imaginary one is zero.
static foreach (backend; Matrix!()) {
    @("cast.realToComplex.zeroesImaginary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                double d = 2.5;
                cdouble c = cast(cdouble) d;
                assert(c.re == 2.5 && c.im == 0);
            }
        });
    }

    // As `realToComplex`, from an integral operand.
    @("cast.integralToComplex.zeroesImaginary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int i = 7;
                cdouble c = cast(cdouble) i;
                assert(c.re == 7.0 && c.im == 0);
            }
        });
    }
}


// An imaginary value has no real axis: `cast(T)` to a real or an
// integral both answer `0`, whatever the imaginary magnitude was.
static foreach (backend; Matrix!()) {
    @("cast.imaginaryToReal.isZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                idouble i = 5.0i;
                double d = cast(double) i;
                assert(d == 0);
            }
        });
    }

    @("cast.imaginaryToIntegral.isZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                idouble i = 5.0i;
                int x = cast(int) i;
                assert(x == 0);
            }
        });
    }

    // The imaginary magnitude's own nonzero test - not always `false`
    // the way the real/integral projections above are.
    @("cast.imaginaryToBool.testsMagnitude." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                idouble zero = 0.0i;
                idouble nonzero = 5.0i;
                assert(!cast(bool) zero);
                assert(cast(bool) nonzero);
            }
        });
    }
}


// The reverse of `imaginaryToReal.isZero`/`imaginaryToIntegral.isZero`
// above (a real/integral cast to imaginary answers `0` the same way),
// and an imaginary-to-imaginary width change (the identical byte
// operation a `float`-to-`double` one is). Each reads back through `&i`
// rather than `cast(double) i`: an imaginary-to-real cast is `zero`
// regardless of the operand (the very rule the first two exercise), so
// it cannot also be the readback - a raw reinterpret of the same
// storage sidesteps that. dmd's own CTFE refuses `cast(double*) &i`
// (`Error: cannot convert '&idouble' to 'double*' at compile time`,
// independently confirmed with `dmd -o-`), so `Ctfe` has no read-back
// this way to run at all.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's own CTFE refuses `cast(double*) &someImaginary`"),
)) {
    @("cast.realToImaginary.isZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                double d = 5.0;
                idouble i = cast(idouble) d;
                assert(*cast(double*) &i == 0);
            }
        });
    }

    @("cast.integralToImaginary.isZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 5;
                idouble i = cast(idouble) value;
                assert(*cast(double*) &i == 0);
            }
        });
    }

    @("cast.imaginaryWidth.preservesMagnitude." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ifloat f = 2.5fi;
                idouble d = cast(idouble) f;
                assert(*cast(double*) &d == 2.5);
            }
        });
    }
}


// `cast(cfloat) someCreal`: both components, independently rounded to
// the destination's own width - and the reverse, `imaginary` <-> `complex`.
static foreach (backend; Matrix!()) {
    @("cast.complexWidth.roundsBothComponents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                creal c = 1.0L + 2.0Li;
                cfloat f = cast(cfloat) c;
                assert(f.im == 2.0f);
                assert(f.re == 1.0f);
            }
        });
    }

    @("cast.complexToImaginary.takesImaginaryComponent." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                cdouble c = 3.0 + 4.0i;
                assert(c.im == 4.0);
            }
        });
    }

    @("cast.imaginaryToComplex.zeroesReal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                idouble im = 6.0i;
                cdouble c = cast(cdouble) im;
                assert(c.re == 0 && c.im == 6.0);
            }
        });
    }
}


// dmd's own `dcast.d` (bugzilla 3133) reinterprets the bytes of two
// equal-size "fat values" - a `struct`, a static array, a vector - into
// one another once no constructor rewrite claims a `struct` destination
// first: `cast(ubyte[S.sizeof]) someS` has no matching constructor, so
// it is a genuine bit reinterpret. dmd's own CTFE refuses every one of
// these at compile time (`Error: cannot cast ... at compile time` /
// `array cast from ... is not supported at compile time`), independently
// confirmed with `dmd -o-`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's own CTFE refuses a struct/static-array reinterpret cast"),
)) {
    @("cast.structToSarray.reinterprets." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                struct S { int x; }
                S s = S(3);
                ubyte[S.sizeof] raw = cast(ubyte[S.sizeof]) s;
                assert(raw[0] == 3);
            }
        });
    }

    @("cast.sarrayToStruct.reinterprets." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                struct S { int x; int y; }
                int[2] a = [7, 8];
                S s = cast(S) a;
                assert(s.x == 7 && s.y == 8);
            }
        });
    }

    @("cast.structToStruct.reinterprets." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                struct S { int x; int y; }
                struct T { int a; int b; }
                S s = S(1, 2);
                T t = cast(T) s;
                assert(t.a == 1 && t.b == 2);
            }
        });
    }

    @("cast.sarrayToSarray.reinterpretsDifferentElementType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[2] a = [1, 2];
                ubyte[8] raw = cast(ubyte[8]) a;
                assert(raw[0] == 1 && raw[4] == 2);
            }
        });
    }
}


// `int4 v = 1;`/`cast(int4) 1`: every lane gets the same value - dmd's
// own semantic pass spells the declaration's own initializer this way
// (`dcast.d`'s scalar-to-vector rewrite). `cast(int4) someInt4Sarray`
// reinterprets the array's own bytes instead of broadcasting a single
// "element". Both round trip through `.array`, itself a reinterpret
// (`typesem.d`'s `TypeVector.dotExp`, `Id.array`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's own CTFE refuses a vector-to-vector element-type reinterpret"
            ~ " cast"),
)) {
    @("cast.vectorBroadcast.everyLaneGetsTheSameValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd;

            void main() {
                int4 v = 1;
                float4 f = cast(float4) v;
                assert(f.array[0] != 0);
                assert(f.array[1] != 0);
                assert(f.array[2] != 0);
                assert(f.array[3] != 0);
            }
        });
    }
}


// `cast(int4) someInt4Sarray`/`someVector.array`: a plain reinterpret,
// dmd's own CTFE allows both (unlike the vector-to-vector element-type
// change above).
static foreach (backend; Matrix!()) {
    @("cast.sarrayToVector.reinterprets." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd;

            void main() {
                int[4] a = [10, 20, 30, 40];
                int4 v = cast(int4) a;
                assert(v.array[1] == 20);
            }
        });
    }

    @("cast.vectorToSarray.viaArrayProperty." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd;

            void main() {
                int4 v = [10, 20, 30, 40];
                int[4] a = v.array;
                assert(a[2] == 30);
            }
        });
    }
}
