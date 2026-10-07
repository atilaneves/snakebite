module ut.backends.call.intrinsics;


import ut.backends;


// A guest is analysed as dmd code, so an intrinsic gives dmd's result on
// every backend, whichever compiler built the test binary. Compiled D is
// the oracle only where its compiler is dmd: LDC's `core.math` rounds
// `rndtol` ties away from zero without regard to the rounding mode, takes
// `sin` and `cos` from libm instead of the x87 instruction, and has a
// different `ldexp` and no `float` or `double` `yl2x`. A test of such a
// function asserts the values of a native dmd run.
version (DigitalMars)
    private alias DmdOnlyNative = AliasSeq!();
else
    private alias DmdOnlyNative = AliasSeq!(
        Omit!(Native, Because.inexpressible,
            "LDC's core.math gives another result than dmd's for this"),
    );


// A value that an optimising host compiler cannot see through. A constant
// argument lets dmd's frontend or LLVM fold the call with the default
// rounding mode, or with libm, before the program runs.
private enum opaqueDouble = q{
    import core.volatile: volatileLoad;

    double opaque(double value) {
        ulong bits = *cast(ulong*) &value;
        bits = volatileLoad(&bits);
        return *cast(double*) &bits;
    }
};


// `core.math.fabs` takes the builtin route (`dmd.builtin.isBuiltin`
// classifies it, so the call runs through snakebite's own compiled
// wrapper, never across the FFI barrier). This test pins an unexecuted
// builtin call: a call site that never executes must run without
// resolving the intrinsic at all.
static foreach (backend; Matrix!()) {
    @("ffi.unexecutedIntrinsicCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: fabs;

            float absoluteIfNegative(float value) {
                if (value < 0)
                    return fabs(value);
                return value;
            }

            void main() {
                assert(absoluteIfNegative(1.0f) == 1.0f);
            }
        });
    }
}


// The same intrinsics reached by calls that do execute. Compiled D emits
// every one of them inline, so no symbol exists anywhere in the process
// for any of them: a backend has to evaluate the bodiless intrinsic
// itself instead of binding it through FFI. dmd's own `BUILTIN`
// classification (`dmd.builtin.isBuiltin`) does not distinguish a
// `float`/`double`/`real` overload - it goes by name alone - so one
// assertion per type below is what actually exercises a backend's own
// per-type wrapper, not dmd's classification. `ldexp` is a two-argument
// intrinsic (its second argument, `int`, is never the same type as the
// first); the rest take one argument of the overload's own type.
static foreach (backend; Matrix!()) {
    @("ffi.executedIntrinsicCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math:
                fabs, sqrt, sin, cos, ldexp, yl2x, yl2xp1;

            void main() {
                float fValue = -1.0f;
                double dValue = -1.0;
                real rValue = -1.0L;
                assert(fabs(fValue) == 1.0f);
                assert(fabs(dValue) == 1.0);
                assert(fabs(rValue) == 1.0L);

                assert(sqrt(4.0f) == 2.0f);
                assert(sqrt(4.0) == 2.0);
                assert(sqrt(4.0L) == 2.0L);

                assert(sin(0.0f) == 0.0f);
                assert(sin(0.0) == 0.0);
                assert(sin(0.0L) == 0.0L);

                assert(cos(0.0f) == 1.0f);
                assert(cos(0.0) == 1.0);
                assert(cos(0.0L) == 1.0L);

                assert(ldexp(1.0f, 3) == 8.0f);
                assert(ldexp(1.0, 3) == 8.0);
                assert(ldexp(1.0L, 3) == 8.0L);

                // yl2x(x, y) computes y * log2(x); yl2xp1 computes
                // y * log2(x + 1).
                assert(yl2x(8.0f, 1.0f) == 3.0f);
                assert(yl2x(8.0, 1.0) == 3.0);
                assert(yl2x(8.0L, 1.0L) == 3.0L);

                assert(yl2xp1(7.0f, 1.0f) == 3.0f);
                assert(yl2xp1(7.0, 1.0) == 3.0);
                assert(yl2xp1(7.0L, 1.0L) == 3.0L);
            }
        });
    }
}


// The x87 instructions that dmd emits for these, which differ from libm and
// from LDC's own `core.math`. The values come from a native dmd 2.113 run.
// A `float` or `double` `yl2x` takes the `real` instruction's result,
// rounded once.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE evaluates sin, cos and yl2x in the host's libm, not as the x87 instruction"),
    DmdOnlyNative,
)) {
    @("ffi.executedIntrinsicCall.x87Results." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, opaqueDouble ~ q{
            import core.math: sin, cos, sqrt, ldexp, yl2x, yl2xp1;

            void main() {
                // Variables, not casts: dmd keeps the operand of an x87
                // instruction at `real` precision and drops a `float` cast.
                const double pi = opaque(0x1.921fb54442d18p+1);
                const float piFloat = pi;
                const real piReal = pi;
                assert(sin(pi) == 0x1.1a6p-53);
                assert(sin(piFloat) == -0x1.777a5cp-24f);
                assert(sin(piReal) == 0x8.d3p-56L);
                const double halfPi = -pi / 2;
                const float halfPiFloat = halfPi;
                const real halfPiReal = halfPi;
                assert(cos(halfPi) == 0x1.1a6p-54);
                assert(cos(halfPiFloat) == -0x1.777a5cp-25f);
                assert(cos(halfPiReal) == 0x8.d3p-57L);

                const double x = opaque(0x1.0624dd2f1a9fcp-10);
                const float xFloat = x;
                assert(yl2x(x, opaque(1.0)) == -0x1.3ee7b471b3a95p+3);
                assert(yl2x(xFloat, 1.0f) == -0x1.3ee7b4p+3f);
                assert(yl2xp1(x, opaque(1.0)) == 0x1.7a013faca6c6bp-10);
                assert(yl2xp1(xFloat, 1.0f) == 0x1.7a014p-10f);

                const float zero = cast(float) opaque(0);
                assert(ldexp(zero, 5) == 0.0f);

                const double negative = sqrt(opaque(-1.0));
                assert((*cast(const(ulong)*) &negative >> 63) == 1);
            }
        });
    }
}


// `core.bitop.bswap` is a bodiless intrinsic dmd's own `BUILTIN`
// classification recognises (`BUILTIN.bswap`), the same as the
// `core.math` names above, but its parameters are `uint`/`ulong`, not a
// floating point type. A call site that never executes must not need a
// host symbol for it, the same as `ffi.unexecutedIntrinsicCall` pins for
// `fabs`.
static foreach (backend; Matrix!()) {
    @("ffi.unexecutedIntrinsicCall.bswap." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.bitop: bswap;

            uint swapIfSet(uint value, bool doIt) {
                if (doIt)
                    return bswap(value);
                return value;
            }

            void main() {
                assert(swapIfSet(1u, false) == 1u);
            }
        });
    }
}


// The same intrinsic reached by a call that does execute, for both
// overloads dmd classifies (`uint` and `ulong`): compiled D emits
// `bswap` inline, so no symbol exists anywhere in the process for it,
// the same reason `ffi.executedIntrinsicCall` above exercises the
// `core.math` wrappers directly rather than through FFI.
static foreach (backend; Matrix!()) {
    @("ffi.executedIntrinsicCall.bswap." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.bitop: bswap;

            void main() {
                assert(bswap(0x01020304u) == 0x04030201u);
                assert(bswap(0x01020304_05060708uL) == 0x08070605_04030201uL);
            }
        });
    }
}


// `core.bitop._popcnt` is a bodiless intrinsic dmd's own `BUILTIN`
// classification recognises, but under `BUILTIN.popcnt` - a bare name
// that is not the declared identifier `_popcnt`. A call site that never
// executes must not need a host symbol for it, the same as
// `ffi.unexecutedIntrinsicCall.bswap` above pins for `bswap`.
static foreach (backend; Matrix!()) {
    @("ffi.unexecutedIntrinsicCall._popcnt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.bitop: _popcnt;

            uint countIfSet(uint value, bool doIt) {
                if (doIt)
                    return _popcnt(value);
                return 0;
            }

            void main() {
                assert(countIfSet(0xFFu, false) == 0);
            }
        });
    }
}


// The same intrinsic reached by a call that does execute, for every
// overload dmd classifies (`ushort`, `uint`, `ulong`): compiled D emits
// `_popcnt` inline, so no symbol exists anywhere in the process for it,
// the same reason `ffi.executedIntrinsicCall.bswap` above exercises the
// `core.bitop` wrapper directly rather than through FFI.
static foreach (backend; Matrix!()) {
    @("ffi.executedIntrinsicCall._popcnt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.bitop: _popcnt;

            void main() {
                assert(_popcnt(cast(ushort) 0xFFu) == 8);
                assert(_popcnt(0xFFu) == 8);
                assert(_popcnt(0xFFuL) == 8);
            }
        });
    }
}


// `rndtol` and `rint` are bodiless `core.math` intrinsics that compiled D
// emits inline, so no host symbol exists for either.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's own CTFE has no source for either intrinsic"),
)) {
    @("ffi.executedIntrinsicCall.rndtolAndRint." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rndtol, rint;

            void main() {
                assert(rndtol(2.7) == 3L);
                assert(rint(2.7) == 3.0);
            }
        });
    }
}


// `core.math.rndtol` and `core.math.rint` are bodiless intrinsics that
// dmd's code generator inlines but its `BUILTIN` enum has no member for,
// so dmd's own CTFE cannot evaluate them either.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rndtol` (`dmd.builtin.isBuiltin` " ~
        "does not classify it)"),
)) {
    @("ffi.executedIntrinsicCall.rndtol." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rndtol;

            void main() {
                assert(rndtol(2.7f) == 3L);
                assert(rndtol(2.7) == 3L);
                assert(rndtol(2.7L) == 3L);
            }
        });
    }
}


// A call site that never runs must not resolve the intrinsic.
static foreach (backend; Matrix!()) {
    @("ffi.unexecutedIntrinsicCall.rndtol." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rndtol;

            long roundIfAsked(bool ask, double value) {
                if (ask)
                    return rndtol(value);
                return 0;
            }

            void main() {
                assert(roundIfAsked(false, 2.7) == 0);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rint` (`dmd.builtin.isBuiltin` " ~
        "does not classify it)"),
)) {
    @("ffi.executedIntrinsicCall.rint." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rint;

            void main() {
                assert(rint(2.5f) == 2.0f);
                assert(rint(2.5) == 2.0);
                assert(rint(2.5L) == 2.0L);
            }
        });
    }
}


// Halfway values round to even, and a negative argument that rounds to
// zero keeps its sign.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rint`"),
)) {
    @("ffi.executedIntrinsicCall.rint.halfway." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rint;

            bool negative(double value) {
                return (*cast(ulong*) &value >> 63) != 0;
            }

            void main() {
                assert(rint(0.5) == 0.0);
                assert(rint(1.5) == 2.0);
                assert(rint(2.5) == 2.0);
                assert(rint(-1.5) == -2.0);
                assert(rint(-2.5) == -2.0);
                assert(rint(0.5f) == 0.0f);
                assert(rint(3.5f) == 4.0f);
                assert(rint(0.5L) == 0.0L);
                assert(rint(3.5L) == 4.0L);
                assert(negative(rint(-0.5)));
                assert(negative(rint(-0.0)));
                assert(!negative(rint(0.0)));
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rint`"),
)) {
    @("ffi.executedIntrinsicCall.rint.nonFinite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rint;

            void main() {
                assert(rint(double.infinity) == double.infinity);
                assert(rint(-double.infinity) == -double.infinity);
                const nan = rint(double.nan);
                assert(nan != nan);
                const nanf = rint(float.nan);
                assert(nanf != nanf);
                const nanl = rint(real.nan);
                assert(nanl != nanl);
                assert(rint(real.infinity) == real.infinity);
            }
        });
    }
}


// The result follows the rounding mode the program sets.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rint`"),
)) {
    @("ffi.executedIntrinsicCall.rint.roundingMode." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, opaqueDouble ~ q{
            import core.math: rint;
            import core.stdc.fenv: fesetround, FE_UPWARD, FE_DOWNWARD,
                FE_TOWARDZERO, FE_TONEAREST;

            void main() {
                fesetround(FE_UPWARD);
                assert(rint(opaque(2.1)) == 3.0);
                assert(rint(opaque(-2.9)) == -2.0);
                assert(rint(cast(real) opaque(2.1)) == 3.0L);
                fesetround(FE_DOWNWARD);
                assert(rint(opaque(2.9)) == 2.0);
                assert(rint(opaque(-2.1)) == -3.0);
                assert(rint(cast(float) opaque(2.9)) == 2.0f);
                fesetround(FE_TOWARDZERO);
                assert(rint(opaque(2.9)) == 2.0);
                assert(rint(opaque(-2.9)) == -2.0);
                fesetround(FE_TONEAREST);
                assert(rint(opaque(2.9)) == 3.0);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rndtol`"),
    DmdOnlyNative,
)) {
    @("ffi.executedIntrinsicCall.rndtol.halfway." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rndtol;

            void main() {
                assert(rndtol(0.5) == 0L);
                assert(rndtol(1.5) == 2L);
                assert(rndtol(2.5) == 2L);
                assert(rndtol(-1.5) == -2L);
                assert(rndtol(-2.5) == -2L);
                assert(rndtol(3.5f) == 4L);
                assert(rndtol(3.5L) == 4L);
                assert(rndtol(-0.0) == 0L);
                assert(rndtol(1.0e15) == 1_000_000_000_000_000L);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `rndtol`"),
    DmdOnlyNative,
)) {
    @("ffi.executedIntrinsicCall.rndtol.roundingMode." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rndtol;
            import core.stdc.fenv: fesetround, FE_UPWARD, FE_DOWNWARD,
                FE_TOWARDZERO, FE_TONEAREST;

            void main() {
                fesetround(FE_UPWARD);
                assert(rndtol(2.1) == 3L);
                assert(rndtol(-2.9) == -2L);
                assert(rndtol(2.1L) == 3L);
                fesetround(FE_DOWNWARD);
                assert(rndtol(2.9) == 2L);
                assert(rndtol(-2.1) == -3L);
                assert(rndtol(2.9f) == 2L);
                fesetround(FE_TOWARDZERO);
                assert(rndtol(2.9) == 2L);
                assert(rndtol(-2.9) == -2L);
                fesetround(FE_TONEAREST);
                assert(rndtol(2.9) == 3L);
            }
        });
    }
}


// `core.volatile` accesses are bodiless intrinsics too.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `volatileLoad`"),
)) {
    @("ffi.executedIntrinsicCall.volatile." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.volatile: volatileLoad, volatileStore;

            void main() {
                ubyte b;
                volatileStore(&b, cast(ubyte) 0x9a);
                assert(volatileLoad(&b) == 0x9a);
                assert(b == 0x9a);
                ushort s;
                volatileStore(&s, cast(ushort) 0xbeef);
                assert(volatileLoad(&s) == 0xbeef);
                uint i;
                volatileStore(&i, 0xdeadbeefu);
                assert(volatileLoad(&i) == 0xdeadbeefu);
                assert(i == 0xdeadbeefu);
                ulong l;
                volatileStore(&l, 0x1122334455667788uL);
                assert(volatileLoad(&l) == 0x1122334455667788uL);
                assert(l == 0x1122334455667788uL);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE has no source for `__prefetch`"),
)) {
    @("ffi.executedIntrinsicCall.prefetch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd: prefetch;

            void main() {
                int value = 5;
                prefetch!(false, 0)(&value);
                prefetch!(false, 3)(&value);
                prefetch!(true, 0)(&value);
                assert(value == 5);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("ffi.unexecutedIntrinsicCall.rint." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.math: rint;

            double rintIfAsked(bool ask, double value) {
                if (ask)
                    return rint(value);
                return 0;
            }

            void main() {
                assert(rintIfAsked(false, 2.5) == 0);
            }
        });
    }
}
