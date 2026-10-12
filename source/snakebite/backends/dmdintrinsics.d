module snakebite.backends.dmdintrinsics;


private:


// The `core.math` intrinsics with the result dmd's code generator gives
// them, for a host built by dmd. A host built by LDC takes the results of
// LDC's druntime through `ldcintrinsics`.
version (DigitalMars):

public import core.math: fabs, sqrt, sin, cos, ldexp, rint, rndtol,
    yl2x, yl2xp1;


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
    }
}
