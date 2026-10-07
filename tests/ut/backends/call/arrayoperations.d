module ut.backends.call.arrayoperations;


import ut.backends;


// druntime's array operations take a vector path for 16 bytes at a time and
// a scalar path for the remainder, so each test below covers lengths on
// both sides of the vector width, with a remainder, and checks that nothing
// beyond the slice changes. The expectation is the same expression on one
// element at a time.
private enum helpers = q{
    T valueOf(T)(size_t seed) {
        T value = cast(T) (seed * 7 % 23 + 1);
        static if (!__traits(isUnsigned, T))
            if (seed % 3 == 0)
                value = cast(T) -value;
        return value;
    }

    immutable lengths = [0, 1, 3, 4, 5, 8, 15, 16, 17, 31, 33, 40];
    enum sentinel = 99;

    T[40] filled(T)(in size_t offset) {
        T[40] result;
        foreach (i; 0 .. 40)
            result[i] = valueOf!T(i + offset);
        return result;
    }
};


// Every binary operator of an array operation, on every integer width.
static foreach (backend; Matrix!()) {
    @("arrayOperations.binary.integers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T, string op)() {
                foreach (length; lengths) {
                    auto a = filled!T(100);
                    a[] = cast(T) sentinel;
                    const b = filled!T(0);
                    const c = filled!T(11);
                    mixin("a[0 .. length] = b[0 .. length] " ~ op ~
                        " c[0 .. length];");
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) mixin("b[i] " ~ op ~ " c[i]"));
                    foreach (i; length .. 40)
                        assert(a[i] == cast(T) sentinel);
                }
            }

            void main() {
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong))
                    static foreach (op; ["+", "-", "*", "/", "%", "&", "|",
                            "^"])
                        check!(T, op);
            }

            import std.meta: AliasSeq;
        });
    }
}


static foreach (backend; Matrix!()) {
    @("arrayOperations.binary.floatingPoint." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T, string op)() {
                foreach (length; lengths) {
                    auto a = filled!T(100);
                    a[] = cast(T) sentinel;
                    const b = filled!T(0);
                    const c = filled!T(11);
                    mixin("a[0 .. length] = b[0 .. length] " ~ op ~
                        " c[0 .. length];");
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) mixin("b[i] " ~ op ~ " c[i]"));
                    foreach (i; length .. 40)
                        assert(a[i] == cast(T) sentinel);
                }
            }

            void main() {
                static foreach (T; AliasSeq!(float, double, real))
                    static foreach (op; ["+", "-", "*", "/"])
                        check!(T, op);
            }

            import std.meta: AliasSeq;
        });
    }
}


static foreach (backend; Matrix!()) {
    @("arrayOperations.unary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T, string op)() {
                foreach (length; lengths) {
                    auto a = filled!T(100);
                    a[] = cast(T) sentinel;
                    const b = filled!T(0);
                    mixin("a[0 .. length] = " ~ op ~ "b[0 .. length];");
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) mixin(op ~ "b[i]"));
                    foreach (i; length .. 40)
                        assert(a[i] == cast(T) sentinel);
                }
            }

            void main() {
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong, float, double, real))
                    check!(T, "-");
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong))
                    check!(T, "~");
            }

            import std.meta: AliasSeq;
        });
    }
}


// `a[] op= b[]` and `a[] op= scalar`, which read and write the same slice.
static foreach (backend; Matrix!()) {
    @("arrayOperations.compoundAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T, string op)() {
                foreach (length; lengths) {
                    auto a = filled!T(0);
                    const original = filled!T(0);
                    const c = filled!T(11);
                    mixin("a[0 .. length] " ~ op ~ "= c[0 .. length];");
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) mixin("original[i] " ~ op ~
                            " c[i]"));
                    foreach (i; length .. 40)
                        assert(a[i] == original[i]);
                }
            }

            void main() {
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong))
                    static foreach (op; ["+", "-", "*", "/", "%", "&", "|",
                            "^"])
                        check!(T, op);
                static foreach (T; AliasSeq!(float, double, real))
                    static foreach (op; ["+", "-", "*", "/"])
                        check!(T, op);
            }

            import std.meta: AliasSeq;
        });
    }
}


static foreach (backend; Matrix!()) {
    @("arrayOperations.scalarOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T, string op)() {
                const T scalar = valueOf!T(5);
                foreach (length; lengths) {
                    auto a = filled!T(100);
                    a[] = cast(T) sentinel;
                    const b = filled!T(0);
                    mixin("a[0 .. length] = b[0 .. length] " ~ op ~
                        " scalar;");
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) mixin("b[i] " ~ op ~
                            " scalar"));
                    mixin("a[0 .. length] = scalar " ~ op ~ " b[0 .. length];");
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) mixin("scalar " ~ op ~ " b[i]"));
                    foreach (i; length .. 40)
                        assert(a[i] == cast(T) sentinel);

                    auto d = filled!T(0);
                    mixin("d[0 .. length] " ~ op ~ "= scalar;");
                    foreach (i; 0 .. length)
                        assert(d[i] == cast(T) mixin("b[i] " ~ op ~ " scalar"));

                    a[0 .. length] = scalar;
                    foreach (i; 0 .. length)
                        assert(a[i] == scalar);
                }
            }

            void main() {
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong))
                    static foreach (op; ["+", "-", "*", "/", "&", "|", "^"])
                        check!(T, op);
                static foreach (T; AliasSeq!(float, double, real))
                    static foreach (op; ["+", "-", "*", "/"])
                        check!(T, op);
            }

            import std.meta: AliasSeq;
        });
    }
}


// A slice that starts at an odd element is not 16-byte aligned, and
// operands that are different slices of one array do not overlap. An
// operand that is the destination itself is the one overlap that D defines.
static foreach (backend; Matrix!()) {
    @("arrayOperations.slices." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T)() {
                foreach (offset; [0, 1, 3]) {
                    auto storage = filled!T(0);
                    const original = filled!T(0);
                    storage[offset .. offset + 12] =
                        storage[offset + 12 .. offset + 24]
                        + storage[offset + 24 .. offset + 36];
                    foreach (i; 0 .. 12)
                        assert(storage[offset + i] == cast(T)
                            (original[offset + 12 + i]
                                + original[offset + 24 + i]));
                    foreach (i; 0 .. offset)
                        assert(storage[i] == original[i]);
                    foreach (i; offset + 12 .. 40)
                        assert(storage[i] == original[i]);

                    auto same = filled!T(0);
                    same[offset .. offset + 20] =
                        same[offset .. offset + 20]
                        * same[offset .. offset + 20];
                    foreach (i; 0 .. 20)
                        assert(same[offset + i] == cast(T)
                            (original[offset + i] * original[offset + i]));
                }
            }

            void main() {
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong, float, double, real))
                    check!T;
            }

            import std.meta: AliasSeq;
        });
    }
}


// `core.simd`'s own unaligned load and store, which druntime's array
// operations are written with.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE cannot evaluate `core.simd.__simd`"),
)) {
    @("arrayOperations.loadAndStoreUnaligned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd: float4, int4, loadUnaligned, storeUnaligned;

            void main() {
                float[8] source = [1, 2, 3, 4, 5, 6, 7, 8];
                float[8] target = 0;
                foreach (offset; 0 .. 4) {
                    float4 loaded = loadUnaligned(
                        cast(const float4*) (source.ptr + offset));
                    storeUnaligned(cast(float4*) (target.ptr + offset), loaded);
                    foreach (i; 0 .. 4)
                        assert(target[offset + i] == source[offset + i]);
                }

                int[7] integers = [10, 20, 30, 40, 50, 60, 70];
                int4 one = loadUnaligned(cast(const int4*) (integers.ptr + 1));
                assert(one.array == [20, 30, 40, 50]);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("arrayOperations.power." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, helpers ~ q{
            void check(T)() {
                foreach (length; lengths) {
                    auto a = filled!T(100);
                    const b = filled!T(0);
                    a[0 .. length] = b[0 .. length] ^^ 2;
                    foreach (i; 0 .. length)
                        assert(a[i] == cast(T) (b[i] ^^ 2));
                    static if (T.sizeof >= 4) {
                        auto d = filled!T(0);
                        d[0 .. length] ^^= 2;
                        foreach (i; 0 .. length)
                            assert(d[i] == cast(T) (b[i] ^^ 2));
                    }
                }
            }

            void main() {
                static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int,
                        uint, long, ulong, float, double, real))
                    check!T;
            }

            import std.meta: AliasSeq;
        });
    }
}
