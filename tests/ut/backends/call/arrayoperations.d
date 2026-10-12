module ut.backends.call.arrayoperations;


import ut.backends;


// druntime's array operations take a vector path for 16 bytes at a time and
// a scalar path for the remainder, so each test below covers lengths on
// both sides of the vector width, with a remainder, and checks that nothing
// beyond the slice changes. Lengths follow each type's vector width; extra
// iterations at unrelated widths add interpretation cost without another
// vector boundary. The expectation is the same expression on one element
// at a time.
private enum helpers = q{
    T valueOf(T)(size_t seed) {
        T value = cast(T) (seed * 7 % 23 + 1);
        static if (!__traits(isUnsigned, T))
            if (seed % 3 == 0)
                value = cast(T) -value;
        return value;
    }

    enum width(T) = 16 / T.sizeof;
    enum lengths(T) = [0, 1, width!T - 1, width!T,
        width!T + 1, 2 * width!T + 1];
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
                const b = filled!T(0);
                const c = filled!T(11);
                foreach (length; lengths!T) {
                    T[40] a;
                    a[] = cast(T) sentinel;
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
                const b = filled!T(0);
                const c = filled!T(11);
                foreach (length; lengths!T) {
                    T[40] a;
                    a[] = cast(T) sentinel;
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
                const b = filled!T(0);
                foreach (length; lengths!T) {
                    T[40] a;
                    a[] = cast(T) sentinel;
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
                const original = filled!T(0);
                const c = filled!T(11);
                foreach (length; lengths!T) {
                    T[40] a;
                    a[] = original[];
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
                const b = filled!T(0);
                foreach (length; lengths!T) {
                    T[40] a;
                    a[] = cast(T) sentinel;
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

                    T[40] d;
                    d[] = b[];
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
//
// LDC's `loadUnaligned` is LLVM inline IR, which no backend runs (ADR-0012);
// native code built by LDC runs it. The load refusal is pinned in
// `inlineasm.loadDiagnostic.llvmInlineIrFailsLoad`.
version (LDC)
    private alias InlineIr = AliasSeq!(
        Omit!(Interpreter, Because.diverges,
            "LDC's inline IR is refused at load"),
        Omit!(Bytecode, Because.diverges,
            "LDC's inline IR is refused at load"),
    );
else
    private alias InlineIr = AliasSeq!();

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE cannot evaluate `core.simd.__simd`"),
    InlineIr,
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
                foreach (length; lengths!T) {
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
