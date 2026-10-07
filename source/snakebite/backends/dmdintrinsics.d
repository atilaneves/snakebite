module snakebite.backends.dmdintrinsics;


private:


// The `core.math` intrinsics with the result dmd's code generator gives
// them. A guest is analysed as dmd code (`version (DigitalMars)`), so the
// same guest program must give the same result whether the host that runs
// it was built by dmd or by LDC. dmd's own `core.math` is that result by
// definition. LDC's `core.math` differs from it in places: `sin` and `cos`
// are libm's, `rndtol` ties away from zero and ignores the rounding mode,
// `ldexp` is software, and `yl2x`/`yl2xp1` exist for `real` only. The
// definitions for LDC below are what dmd emits: an x87 instruction on a
// `real`, narrowed once when the result is not a `real`.
version (DigitalMars) {
    public import core.math: fabs, sqrt, sin, cos, ldexp, rint, rndtol,
        yl2x, yl2xp1;
} else version (LDC) {
    public import core.math: fabs, rint;

    import ldc.intrinsics: llvm_llrint;

    // The instruction itself, not `llvm_sqrt`: LLVM can lower that to a call
    // of libm's `sqrt`, whose NaN for a negative argument has the other sign.
    public T sqrt(T)(in T x) @trusted pure nothrow @nogc {
        T result = void;
        static if (is(T == float))
            asm @trusted pure nothrow @nogc {
                "sqrtss %1, %0" : "=x" (result) : "x" (x);
            }
        else static if (is(T == double))
            asm @trusted pure nothrow @nogc {
                "sqrtsd %1, %0" : "=x" (result) : "x" (x);
            }
        else
            asm @trusted pure nothrow @nogc {
                "fsqrt" : "=st" (result) : "st" (x);
            }
        return result;
    }

    public T sin(T)(in T x) @trusted pure nothrow @nogc {
        real result = void;
        const widened = cast(real) x;
        asm @trusted pure nothrow @nogc {
            "fsin" : "=st" (result) : "st" (widened);
        }
        return cast(T) result;
    }

    public T cos(T)(in T x) @trusted pure nothrow @nogc {
        real result = void;
        const widened = cast(real) x;
        asm @trusted pure nothrow @nogc {
            "fcos" : "=st" (result) : "st" (widened);
        }
        return cast(T) result;
    }

    public T ldexp(T)(in T x, in int exponent) @trusted pure nothrow @nogc {
        real result = void;
        const widened = cast(real) x;
        const scale = cast(real) exponent;
        asm @trusted pure nothrow @nogc {
            "fscale\n\tfstp\t%%st(1)" : "=st" (result)
                : "st" (widened), "st(1)" (scale) : "st(1)";
        }
        return cast(T) result;
    }

    public T yl2x(T)(in T x, in T y) @trusted pure nothrow @nogc {
        real result = void;
        const widenedX = cast(real) x;
        const widenedY = cast(real) y;
        asm @trusted pure nothrow @nogc {
            "fyl2x" : "=st" (result) : "st(1)" (widenedY), "st" (widenedX)
                : "st(1)";
        }
        return cast(T) result;
    }

    public T yl2xp1(T)(in T x, in T y) @trusted pure nothrow @nogc {
        real result = void;
        const widenedX = cast(real) x;
        const widenedY = cast(real) y;
        asm @trusted pure nothrow @nogc {
            "fyl2xp1" : "=st" (result) : "st(1)" (widenedY), "st" (widenedX)
                : "st(1)";
        }
        return cast(T) result;
    }

    public long rndtol(T)(in T x) @safe pure nothrow @nogc {
        return llvm_llrint(x);
    }
} else
    static assert(false, "Builtin intrinsics need DMD or LDC as the host");
