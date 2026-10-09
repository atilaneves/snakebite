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


// The operand is a value in memory, already narrowed to its own precision,
// which is all that dmd's `toPrec` guarantees.
public T toPrec(T)(in T x) @safe pure nothrow @nogc {
    return x;
}


// xmmabs masks the operand in XMM without a conversion. An x87 result
// instead uses FABS followed by a store at the declared result width.
public Result magnitudeTo(Result, T)(in T x) pure nothrow @nogc {
    static if (!is(T == real) && !is(Result == real)) {
        union Stored {
            double double_;
            float float_;
        }
        Stored stored;
        stored.double_ = 0;
        static if (is(T == double))
            stored.double_ = fabs(x);
        else
            stored.float_ = fabs(x);
        static if (is(Result == double))
            return stored.double_;
        else
            return stored.float_;
    } else
        return cast(Result) fabs(cast(real) x);
}


// FISTP converts at the destination width. Converting to long first would
// wrap an out-of-range int or short instead of returning integer indefinite.
public Result roundedTo(Result, T)(in T x) pure nothrow @nogc {
    Result result = void;
    version (DigitalMars) {
        asm pure nothrow @nogc {
            fld x;
            fistp result;
        }
    } else version (LDC) {
        const widened = cast(real) x;
        static if (is(Result == short))
            enum instruction = "fistps %0";
        else static if (is(Result == int))
            enum instruction = "fistpl %0";
        else
            enum instruction = "fistpq %0";
        mixin("asm pure nothrow @nogc { \"" ~ instruction
            ~ "\" : \"=m\" (result) : \"st\" (widened) : \"st\"; }");
    }
    return result;
}


// The byte swap instruction uses the result width, unlike bit scans and
// population counts, which use the operand width.
public Result swapTo(Result, T)(in T value) @safe pure nothrow @nogc {
    import core.bitop: bswap;

    static if (Result.sizeof == 2)
        return cast(Result) (bswap(cast(uint) cast(ushort) value) >> 16);
    else static if (Result.sizeof == 4)
        return cast(Result) bswap(cast(uint) value);
    else
        return cast(Result) bswap(cast(ulong) value);
}


// The memory bit instructions use the index operand's width, not the
// pointer's element type. Public core.bitop uses size_t for both operands.
public int bitTest(string name, T)(void* address, in T index) nothrow @nogc {
    int result;
    version (DigitalMars) {
        enum register = T.sizeof == 8 ? "RCX" : T.sizeof == 4 ? "ECX" : "CX";
        mixin("asm nothrow @nogc {"
            ~ "mov RAX, address; mov " ~ register ~ ", index;"
            ~ name ~ " [RAX], " ~ register ~ ";"
            ~ "setc AL; movzx EAX, AL; mov result, EAX; }");
    } else version (LDC) {
        ubyte carry;
        mixin("asm nothrow @nogc { \"" ~ name ~ " %2, (%1)\\n\\tsetc %0\""
            ~ " : \"=q\" (carry) : \"r\" (address), \"r\" (index)"
            ~ " : \"memory\", \"cc\"; }");
        result = carry;
    }
    return result;
}


// dmd chooses the IN width from the result and the OUT width from the
// stored value. The name's suffix does not select the instruction width.
// On x86-64 its size override selects AX for both two- and four-byte
// values (cdport). A four-byte IN result has unspecified upper bits.
public Value portInput(Value, Port)(in Port port) nothrow @nogc {
    const address = cast(ushort) port;
    Value result = void;
    version (DigitalMars) {
        enum register = Value.sizeof == 1 ? "AL" : Value.sizeof == 2 ? "AX" : "EAX";
        enum operand = Value.sizeof == 1 ? "AL" : "AX";
        mixin("asm nothrow @nogc { mov DX, address; in " ~ operand
            ~ ", DX; mov result, " ~ register ~ "; }");
    } else version (LDC) {
        enum instruction = Value.sizeof == 4 ? "in %1, %%ax" : "in %1, %0";
        mixin("asm nothrow @nogc { \"" ~ instruction
            ~ "\" : \"={ax}\" (result) : \"{dx}\" (address); }");
    }
    return result;
}


public Value portOutput(Value, Port)(in Port port, in Value value) nothrow @nogc {
    const address = cast(ushort) port;
    version (DigitalMars) {
        enum register = Value.sizeof == 1 ? "AL" : Value.sizeof == 2 ? "AX" : "EAX";
        enum operand = Value.sizeof == 1 ? "AL" : "AX";
        mixin("asm nothrow @nogc { mov DX, address; mov " ~ register
            ~ ", value; out DX, " ~ operand ~ "; }");
    } else version (LDC) {
        enum instruction = Value.sizeof == 4 ? "out %%ax, %1" : "out %0, %1";
        mixin("asm nothrow @nogc { \"" ~ instruction
            ~ "\" : : \"{ax}\" (value), \"{dx}\" (address); }");
    }
    return value;
}


public void volatileCopyWide(size_t width)(
    void* destination, const(void)* source,
) nothrow @nogc {
    static assert(width == 10 || width == 16);
    version (DigitalMars) {
        static if (width == 10) {
            asm nothrow @nogc {
                mov RAX, source;
                mov RDX, destination;
                fld real ptr [RAX];
                fstp real ptr [RDX];
            }
        } else {
            asm nothrow @nogc {
                mov RAX, source;
                mov RDX, destination;
                movdqu XMM0, [RAX];
                movdqu [RDX], XMM0;
            }
        }
    } else version (LDC) {
        static if (width == 10) {
            asm nothrow @nogc {
                "fldt (%1)\n\tfstpt (%0)"
                    : : "r" (destination), "r" (source) : "memory", "st";
            }
        } else {
            asm nothrow @nogc {
                "movdqu (%1), %%xmm0\n\tmovdqu %%xmm0, (%0)"
                    : : "r" (destination), "r" (source) : "memory", "xmm0";
            }
        }
    }
}
