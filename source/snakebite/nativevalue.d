module snakebite.nativevalue;


private:


// Integral values in guest storage use the same byte order and widths as
// compiled D values. Callers validate a width before reaching this module;
// the assertions keep invalid calls from becoming silent memory corruption
// without adding an exception path to hot backend operations.
pragma(inline, true) public void storeIntegral(
    void* place,
    in ulong value,
    in size_t size,
) @nogc nothrow {
    switch (size) {
        case 1: *cast(ubyte*) place = cast(ubyte) value; return;
        case 2: *cast(ushort*) place = cast(ushort) value; return;
        case 4: *cast(uint*) place = cast(uint) value; return;
        case 8: *cast(ulong*) place = value; return;
        default: assert(0, "no native layout for this integral width");
    }
}

// Reads an integral value from guest storage and widens it to 64 bits.
// Signed values are sign extended; unsigned values retain their bits in the
// returned `long`, so callers can reinterpret them as `ulong` when needed.
pragma(inline, true) public long loadIntegral(
    in void* place,
    in size_t size,
    in bool signed,
) @nogc nothrow {
    if (signed)
        return loadSigned(place, size);
    else
        return cast(long) loadUnsigned(place, size);
}

pragma(inline, true) public long loadSigned(
    in void* place,
    in size_t size,
) @nogc nothrow {
    switch (size) {
        case 1: return *cast(const(byte)*) place;
        case 2: return *cast(const(short)*) place;
        case 4: return *cast(const(int)*) place;
        case 8: return *cast(const(long)*) place;
        default: assert(0, "no native layout for this integral width");
    }
    assert(0);
    return 0;
}

pragma(inline, true) public ulong loadUnsigned(
    in void* place,
    in size_t size,
) @nogc nothrow {
    switch (size) {
        case 1: return *cast(const(ubyte)*) place;
        case 2: return *cast(const(ushort)*) place;
        case 4: return *cast(const(uint)*) place;
        case 8: return *cast(const(ulong)*) place;
        default: assert(0, "no native layout for this integral width");
    }
    assert(0);
    return 0;
}

// Floating values in guest storage use the same widths as compiled D values.
// A real return value carries every supported source precision without a
// second rounding step; the destination width applies the one conversion.
pragma(inline, true) public real loadFloating(
    in void* place,
    in size_t size,
) @nogc nothrow {
    if (size == float.sizeof)
        return *cast(const(float)*) place;
    if (size == double.sizeof)
        return *cast(const(double)*) place;
    assert(size == real.sizeof, "no native layout for this floating width");
    return *cast(const(real)*) place;
}

pragma(inline, true) public void storeFloating(
    void* place,
    in real value,
    in size_t size,
) @nogc nothrow {
    if (size == float.sizeof) {
        *cast(float*) place = cast(float) value;
        return;
    }
    if (size == double.sizeof) {
        *cast(double*) place = cast(double) value;
        return;
    }
    assert(size == real.sizeof, "no native layout for this floating width");
    *cast(real*) place = value;
}

pragma(inline, true) public void integralToFloating(
    void* destination,
    in void* source,
    in size_t destinationSize,
    in size_t sourceSize,
    in bool unsignedSource,
) @nogc nothrow {
    const value = unsignedSource
        ? cast(real) loadUnsigned(source, sourceSize)
        : cast(real) loadSigned(source, sourceSize);
    storeFloating(destination, value, destinationSize);
}

// What native x86 code gives, which D leaves undefined outside the range of
// the destination: a value that does not fit makes the hardware convert to
// its "integer indefinite" value, the smallest signed integer of that width.
// A destination of 1 to 4 bytes converts through a 32-bit register, except
// `uint`, which converts through a 64-bit one; a `real` source for those
// first rounds to `double`. A `ulong` converts a value below 2^63 as a
// signed integer, wrapping a negative one, and a larger value after
// subtracting 2^63. A `float` or `double` converts as a `double`, which is
// cheaper than `real` and gives the same integer.
pragma(inline, true) public void floatingToIntegral(
    void* destination,
    in void* source,
    in size_t destinationSize,
    in size_t sourceSize,
    in bool unsignedDestination,
) @nogc nothrow {
    ulong converted;
    if (sourceSize == double.sizeof)
        converted = truncated(
            *cast(const(double)*) source, destinationSize,
            unsignedDestination);
    else if (sourceSize == float.sizeof)
        converted = truncated(
            cast(double) *cast(const(float)*) source, destinationSize,
            unsignedDestination);
    else {
        assert(sourceSize == real.sizeof,
            "no native layout for this floating width");
        const value = *cast(const(real)*) source;
        converted = destinationSize < ulong.sizeof
            ? truncated(cast(double) value, destinationSize,
                unsignedDestination)
            : truncated(value, destinationSize, unsignedDestination);
    }
    storeIntegral(destination, converted, destinationSize);
}

pragma(inline, true) private ulong truncated(T)(
    in T value, in size_t destinationSize, in bool unsignedDestination,
) @nogc nothrow pure @safe {
    switch (destinationSize) {
        case ulong.sizeof:
            if (!unsignedDestination || value < 0x1p63)
                return cast(ulong) signed64(value);
            return cast(ulong) signed64(value - 0x1p63) + (1UL << 63);
        case int.sizeof:
            return unsignedDestination
                ? cast(ulong) signed64(value) : cast(ulong) signed32(value);
        default:
            return cast(ulong) signed32(value);
    }
}

// The smallest value of the width is also what the hardware gives for the
// value just below it, so one magnitude test covers both ends.
pragma(inline, true) private long signed64(T)(in T value)
        @nogc nothrow pure @safe {
    import core.math: fabs;

    return fabs(value) < 0x1p63 ? cast(long) value : long.min;
}

pragma(inline, true) private int signed32(T)(in T value)
        @nogc nothrow pure @safe {
    import core.math: fabs;

    return fabs(value) < 2147483648.0 ? cast(int) value : int.min;
}

pragma(inline, true) public void floatingToBool(
    void* destination,
    in void* source,
    in size_t sourceSize,
) @nogc nothrow {
    storeIntegral(destination, loadFloating(source, sourceSize) != 0, 1);
}

// A complex value's native layout is its two components, `re` then `im`,
// each exactly half the whole value's size - `float`+`float` for
// `cfloat`, and so on. Every complex primitive below shares that one
// halving instead of taking the component size as a separate argument.
pragma(inline, true) public real loadComplexRe(
    in void* place,
    in size_t size,
) @nogc nothrow {
    return loadFloating(place, size / 2);
}

pragma(inline, true) public real loadComplexIm(
    in void* place,
    in size_t size,
) @nogc nothrow {
    return loadFloating(cast(const(ubyte)*) place + size / 2, size / 2);
}

pragma(inline, true) public void storeComplex(
    void* place,
    in real re,
    in real im,
    in size_t size,
) @nogc nothrow {
    storeFloating(place, re, size / 2);
    storeFloating(cast(ubyte*) place + size / 2, im, size / 2);
}

// What one operand of a complex operation holds. The D spec gives
// imaginary types so that no operation touches the implied zero half of a
// real or an imaginary operand: that half is absent, not zero, and so it
// cannot change the sign of a zero in the result.
public enum ComplexOperand {
    real_,
    imaginary,
    complex,
}

public enum ComplexOperation {
    add,
    subtract,
    multiply,
    divide,
    modulo,
}

// Both operands of a complex operation, packed into one instruction field.
public struct ComplexOperands {
    public ComplexOperand left;
    public ComplexOperand right;

    public size_t packed() const @safe @nogc nothrow pure {
        return left << 8 | right;
    }

    public static ComplexOperands unpack(in size_t packed)
        @safe @nogc nothrow pure
    {
        return ComplexOperands(cast(ComplexOperand)(packed >> 8),
            cast(ComplexOperand)(packed & 0xff));
    }
}

// `left op right` into `result`, which may be `left`. Every part is
// computed in `real` and rounded once to `partSize`, as dmd's x87 code
// and druntime's `_Cmul` and `_Cdiv` do.
public void applyComplex(ComplexOperation operation)(
    void* result,
    in void* left,
    in void* right,
    in ComplexOperands operands,
    in size_t partSize,
) @nogc nothrow {
    const a = ComplexParts(left, operands.left, partSize);
    const b = ComplexParts(right, operands.right, partSize);
    static if (operation == ComplexOperation.add)
        const answer = ComplexParts.sum(a, b);
    else static if (operation == ComplexOperation.subtract)
        const answer = ComplexParts.sum(a, b.negated);
    else static if (operation == ComplexOperation.multiply)
        const answer = ComplexParts.product(a, b);
    else static if (operation == ComplexOperation.divide)
        const answer = ComplexParts.quotient(a, b);
    else static if (operation == ComplexOperation.modulo)
        const answer = ComplexParts.remainder(a, b);
    else
        static assert(0, "no complex operation " ~ operation.stringof);
    storeFloating(result, answer.re, partSize);
    storeFloating(cast(ubyte*) result + partSize, answer.im, partSize);
}

// `-value` into `result`, which may be `value`.
public void negateComplex(void* result, in void* value, in size_t partSize)
    @nogc nothrow
{
    const re = loadFloating(value, partSize);
    const im = loadFloating(cast(const(ubyte)*) value + partSize, partSize);
    storeFloating(result, -re, partSize);
    storeFloating(cast(ubyte*) result + partSize, -im, partSize);
}

// A complex, real or imaginary operand as its two halves, either of which
// may be absent.
private struct ComplexParts {
    real re = 0;
    real im = 0;
    bool hasRe;
    bool hasIm;

    this(in void* place, in ComplexOperand operand, in size_t partSize)
        @nogc nothrow
    {
        final switch (operand) with (ComplexOperand) {
            case real_:
                re = loadFloating(place, partSize);
                hasRe = true;
                break;
            case imaginary:
                im = loadFloating(place, partSize);
                hasIm = true;
                break;
            case complex:
                re = loadFloating(place, partSize);
                im = loadFloating(cast(const(ubyte)*) place + partSize,
                    partSize);
                hasRe = hasIm = true;
                break;
        }
    }

    this(in real re, in bool hasRe, in real im, in bool hasIm)
        @nogc nothrow pure
    {
        this.re = re;
        this.hasRe = hasRe;
        this.im = im;
        this.hasIm = hasIm;
    }

    ComplexParts negated() const @nogc nothrow pure {
        return ComplexParts(-re, hasRe, -im, hasIm);
    }

    static ComplexParts sum(in ComplexParts a, in ComplexParts b)
        @nogc nothrow pure
    {
        return ComplexParts(
            combined(a.re, a.hasRe, b.re, b.hasRe), true,
            combined(a.im, a.hasIm, b.im, b.hasIm), true,
        );
    }

    // `(a.re + a.im i)(b.re + b.im i)`, with no term for an absent half.
    // With both operands complex this is druntime's `_Cmul`.
    static ComplexParts product(in ComplexParts a, in ComplexParts b)
        @nogc nothrow pure
    {
        return ComplexParts(
            combined(a.re * b.re, a.hasRe && b.hasRe,
                -(a.im * b.im), a.hasIm && b.hasIm), true,
            combined(a.im * b.re, a.hasIm && b.hasRe,
                a.re * b.im, a.hasRe && b.hasIm), true,
        );
    }

    // By a real or an imaginary divisor, each half of the complex dividend
    // divides on its own. By a complex divisor this is druntime's `_Cdiv`:
    // Smith's algorithm, which scales by the ratio of the divisor's halves
    // so that no intermediate overflows first. `_Cdiv` compares the halves'
    // magnitudes as `double`s.
    static ComplexParts quotient(in ComplexParts a, in ComplexParts b)
        @nogc nothrow pure
    {
        import core.math: fabs;

        if (b.hasRe != b.hasIm) {
            assert(a.hasRe && a.hasIm,
                "semantic types a quotient by a real or imaginary of a "
                ~ "real or imaginary as real or imaginary");
            return b.hasRe
                ? ComplexParts(a.re / b.re, true, a.im / b.re, true)
                : ComplexParts(a.im / b.im, true, -(a.re / b.im), true);
        }

        if (fabs(cast(double) b.re) < fabs(cast(double) b.im)) {
            const r = b.re / b.im;
            const den = b.im + r * b.re;
            return ComplexParts(
                combined(a.re * r, a.hasRe, a.im, a.hasIm) / den, true,
                combined(a.im * r, a.hasIm, -a.re, a.hasRe) / den, true,
            );
        }
        const r = b.im / b.re;
        const den = b.re + r * b.im;
        return ComplexParts(
            combined(a.re, a.hasRe, r * a.im, a.hasIm) / den, true,
            combined(a.im, a.hasIm, -(r * a.re), a.hasRe) / den, true,
        );
    }

    // Semantic rejects a complex divisor, so each half of the complex
    // dividend takes its remainder by the one divisor value.
    static ComplexParts remainder(in ComplexParts a, in ComplexParts b)
        @nogc nothrow pure
    {
        assert(a.hasRe && a.hasIm && b.hasRe != b.hasIm,
            "semantic takes a complex remainder by a real or imaginary");
        const divisor = b.hasRe ? b.re : b.im;
        return ComplexParts(a.re % divisor, true, a.im % divisor, true);
    }
}

// `a + b` where both terms are present, else the one that is.
private real combined(in real a, in bool hasA, in real b, in bool hasB)
    @nogc nothrow pure
{
    assert(hasA || hasB, "each half of a complex result has a term");
    if (hasA && hasB)
        return a + b;
    return hasA ? a : b;
}

pragma(inline, true) public bool complexTruth(
    in void* place,
    in size_t size,
) @nogc nothrow {
    return loadComplexRe(place, size) != 0 || loadComplexIm(place, size) != 0;
}

// Whether an integral width has a native representation handled above.
public bool isIntegralSize(in size_t size) @safe @nogc nothrow pure {
    return size == 1 || size == 2 || size == 4 || size == 8;
}

// The count a shift uses. D leaves a count outside `[0, width)` undefined;
// compiled D on x86-64 answers it with the CPU's own rule, the low 5 bits
// of the count for a shift narrower than 64 bits - 8- and 16-bit shifts
// included - and the low 6 bits for a 64-bit one.
public ulong shiftCount(in ulong count, in size_t operandSize)
        @safe @nogc nothrow pure {
    return count & (operandSize == 8 ? 63 : 31);
}

public enum arrayLengthOffset = 0;
public enum arrayPointerOffset = size_t.sizeof;
public enum arrayValueSize = size_t.sizeof + (void*).sizeof;

// A delegate is `struct { void* ptr; void* funcptr; }`: the context word
// first, the function word after it.
public enum delegateContextOffset = 0;
public enum delegateFunctionOffset = (void*).sizeof;
public enum delegateValueSize = 2 * (void*).sizeof;

// Which byte-level transform a cast performs, once `snakebite.backends.
// casts.classify` has decided it. This is the one enum both
// `snakebite.backends.casts.CastPlan.kind` (classify's own answer,
// while dmd's types are still in scope) and `applyCast`/`applyCastAs`
// below (turning that answer into bytes, once they are not) read -
// `snakebite.backends.bytecode.vm` may not import DMD frontend
// modules, so keeping the enum here, DMD-free, is what lets it name
// the same `CastKind` its own per-kind `opCastAs`/`opCastFixedAs` ops
// are instantiated over. `applyCastAs` below carries out every kind
// except `copy`, `classReference`, and `zero`: each of
// those needs a backend's own control flow (a plain move, a class
// reference adjustment, or a zero fill), so `applyCast`'s own
// `final switch` hits `assert(0)` on any of the three - both backends'
// `compileCast`/`visitUnloweredCast` switches
// handle them directly and never reach `applyCast` with one.
public enum CastKind {
    // Bit-identical representations: a plain move of the destination's
    // own size. Covers class<->class upcasts, class<->pointer, AA<->AA,
    // AA<->pointer, pointer<->pointer, equal-width float<->float,
    // equal-width integral<->integral, delegate<->delegate and
    // equal-element-width array<->array.
    copy,
    // DMD leaves proven upcasts unlowered so code generation can apply
    // the native reference adjustment. Null stays null.
    classReference,
    integralToFloat,
    floatToIntegral,
    floatToPointer,
    pointerToFloat,
    floatToBool,
    floatWidth,
    complexToBool,
    complexToReal,
    complexToImaginary,
    complexToIntegral,
    complexWidth,
    realToComplex,
    integralToComplex,
    imaginaryToComplex,
    sarrayToSlice,
    sarrayToPointer,
    sliceToPointer,
    pointerToArray,
    pointerToIntegral,
    delegateToPointer,
    reinterpretSlice,
    narrow,
    widenSigned,
    widenUnsigned,
    toBool,
    zero,
}

// The DMD-free subset of `snakebite.backends.casts.CastPlan` that
// `applyCast` needs to turn a cast's source bytes into its destination
// bytes - `snakebite.backends.casts.layoutOf` builds one from a
// `CastPlan`. Kept here, next to `applyCast` itself, rather than in
// `casts.d`, because `snakebite.backends.bytecode.vm` may not import
// DMD frontend modules and `casts.d` reaches dmd's own `Type` in its
// `classify`.
public struct CastLayout {
    public CastKind kind;
    public size_t sourceSize;
    public size_t destSize;
    public bool sourceUnsigned;
    public bool destUnsigned;
    public size_t sourceElementSize;
    public size_t destElementSize;
    public size_t staticLength;
}

// Carries out one `CastKind`: reads bytes at `source` and writes
// `layout.destSize` bytes at `destination`, in the native layout every
// backend already shares. `kind` is a compile-time parameter so a
// caller that already knows it - `snakebite.backends.bytecode.vm`'s
// per-`CastKind` cast ops chief among them - pays for no run-time
// dispatch on it: `static if` picks the one arm below that applies,
// the same way `kind`'s own switch arm would have, with the choice
// made once, at compile time, rather than on every execution. This is
// the one definition of every kind's semantics; `applyCast` below is a
// thin run-time-`kind` wrapper around it, for a caller - the
// tree-walking interpreter, and the bytecode compiler's own
// `layoutOf` - that only learns `kind` at run time.
//
// `source` always points at bytes that already hold the value a kind
// reads: an evaluated operand for most of them, or - for
// `sarrayToSlice`/`sarrayToPointer` - a pointer-sized slot holding the
// operand's own address, the shape both backends already produce for
// "the address of an expression" (`addressOf`/`compileAddress`).
//
// `pragma(inline, true)`, like every other primitive in this module:
// `snakebite.backends.bytecode.vm`'s own per-`CastKind` op calls this
// once per execution, and forcing it inline is what lets the optimiser
// see that most of `layout`'s 8 fields are dead at any one `kind` -
// its caller only ever fills in the two or three this arm actually
// reads - rather than spending a real call and a full `CastLayout`
// passed by value on every cast.
pragma(inline, true) public void applyCastAs(CastKind kind)(
    in CastLayout layout,
    in void* source,
    void* destination,
) @nogc nothrow {
    with (CastKind) {
    static if (kind == integralToFloat)
        integralToFloating(destination, source, layout.destSize,
            layout.sourceSize, layout.sourceUnsigned);

    else static if (kind == floatToIntegral)
        floatingToIntegral(destination, source, layout.destSize,
            layout.sourceSize, layout.destUnsigned);

    else static if (kind == floatToPointer)
        floatingToIntegral(destination, source, layout.destSize,
            layout.sourceSize, true);

    else static if (kind == pointerToFloat)
        integralToFloating(destination, source, layout.destSize,
            layout.sourceSize, true);

    else static if (kind == floatToBool)
        floatingToBool(destination, source, layout.sourceSize);

    else static if (kind == floatWidth)
        storeFloating(
            destination, loadFloating(source, layout.sourceSize),
            layout.destSize,
        );

    else static if (kind == complexToBool)
        storeIntegral(
            destination, complexTruth(source, layout.sourceSize),
            layout.destSize,
        );

    else static if (kind == complexToReal)
        storeFloating(
            destination, loadComplexRe(source, layout.sourceSize),
            layout.destSize,
        );

    else static if (kind == complexToImaginary)
        storeFloating(
            destination, loadComplexIm(source, layout.sourceSize),
            layout.destSize,
        );

    else static if (kind == complexToIntegral)
        floatingToIntegral(destination, source, layout.destSize,
            layout.sourceSize / 2, layout.destUnsigned);

    else static if (kind == complexWidth)
        storeComplex(
            destination, loadComplexRe(source, layout.sourceSize),
            loadComplexIm(source, layout.sourceSize), layout.destSize,
        );

    else static if (kind == realToComplex)
        storeComplex(
            destination, loadFloating(source, layout.sourceSize), 0.0L,
            layout.destSize,
        );

    else static if (kind == integralToComplex) {
        const value =
            loadIntegral(source, layout.sourceSize, !layout.sourceUnsigned);
        const re = layout.sourceUnsigned
            ? cast(real) cast(ulong) value : cast(real) value;
        storeComplex(destination, re, 0.0L, layout.destSize);
    }

    else static if (kind == imaginaryToComplex)
        storeComplex(
            destination, 0.0L, loadFloating(source, layout.sourceSize),
            layout.destSize,
        );

    else static if (kind == sarrayToSlice) {
        const address = loadUnsigned(source, size_t.sizeof);
        auto bytes = cast(ubyte*) destination;
        storeIntegral(
            bytes + arrayLengthOffset, layout.staticLength, size_t.sizeof);
        storeIntegral(bytes + arrayPointerOffset, address, size_t.sizeof);
    }

    else static if (kind == sarrayToPointer)
        storeIntegral(
            destination, loadUnsigned(source, size_t.sizeof),
            layout.destSize,
        );

    else static if (kind == sliceToPointer)
        storeIntegral(
            destination,
            loadUnsigned(
                cast(ubyte*) source + arrayPointerOffset, size_t.sizeof),
            layout.destSize,
        );

    else static if (kind == pointerToArray) {
        import core.stdc.string: memcpy;

        const address = loadUnsigned(source, size_t.sizeof);
        memcpy(
            destination, cast(const(void)*) cast(size_t) address,
            layout.destSize,
        );
    }

    else static if (kind == pointerToIntegral)
        storeIntegral(
            destination, loadUnsigned(source, size_t.sizeof),
            layout.destSize,
        );

    else static if (kind == delegateToPointer)
        storeIntegral(
            destination,
            loadUnsigned(
                cast(ubyte*) source + delegateContextOffset, size_t.sizeof),
            layout.destSize,
        );

    else static if (kind == reinterpretSlice) {
        const sourceLength = cast(size_t) loadUnsigned(
            cast(ubyte*) source + arrayLengthOffset, size_t.sizeof);
        const pointer = loadUnsigned(
            cast(ubyte*) source + arrayPointerOffset, size_t.sizeof);
        const newLength =
            sourceLength * layout.sourceElementSize / layout.destElementSize;
        auto bytes = cast(ubyte*) destination;
        storeIntegral(bytes + arrayLengthOffset, newLength, size_t.sizeof);
        storeIntegral(bytes + arrayPointerOffset, pointer, size_t.sizeof);
    }

    else static if (kind == toBool)
        storeIntegral(
            destination, loadUnsigned(source, layout.sourceSize) != 0,
            layout.destSize,
        );

    // A narrowing cast keeps only its destination's own low bytes out
    // of the source's, on this VM's little-endian host - bits sign- or
    // zero-extension would add live only at or above the source's own
    // width, never inside the narrower destination, so `narrow` reads
    // the same regardless of sign. `widenSigned`/`widenUnsigned` fix
    // the sign the extension itself uses at the kind, rather than at
    // `layout.sourceUnsigned` - `snakebite.backends.casts.classify`
    // already chose between them on the source's own signedness, so
    // there is nothing left for `layout` to add.
    else static if (kind == narrow)
        storeIntegral(
            destination,
            cast(ulong) loadIntegral(source, layout.sourceSize, true),
            layout.destSize,
        );

    else static if (kind == widenSigned)
        storeIntegral(
            destination,
            cast(ulong) loadIntegral(source, layout.sourceSize, true),
            layout.destSize,
        );

    else static if (kind == widenUnsigned)
        storeIntegral(
            destination,
            cast(ulong) loadIntegral(source, layout.sourceSize, false),
            layout.destSize,
        );

    else
        static assert(0, "applyCastAs: unhandled CastKind");
    }
}

// The tree-walking interpreter, and the bytecode compiler's own
// `layoutOf`, only learn a cast's `CastKind` at run time, unlike
// `snakebite.backends.bytecode.vm`'s per-`CastKind` cast ops - this is
// their entry point, a plain run-time dispatch to the one arm of
// `applyCastAs` above that `layout.kind` names. `copy`,
// `classReference` and `zero` never reach here: both
// backends' `compileCast`/`visitUnloweredCast` switches handle each of
// the three with their own control flow before either one
// ever calls `applyCast`.
public void applyCast(
    in CastLayout layout,
    in void* source,
    void* destination,
) @nogc nothrow {
    final switch (layout.kind) with (CastKind) {
    case copy:
        assert(0, "applyCast: copy is a backend's own plain move");
    case classReference:
        assert(0,
            "applyCast: classReference needs a backend's own reference "
            ~ "adjustment");
    case zero:
        assert(0, "applyCast: zero needs a backend's own zero fill");
    case integralToFloat:
        return applyCastAs!integralToFloat(layout, source, destination);
    case floatToIntegral:
        return applyCastAs!floatToIntegral(layout, source, destination);
    case floatToPointer:
        return applyCastAs!floatToPointer(layout, source, destination);
    case pointerToFloat:
        return applyCastAs!pointerToFloat(layout, source, destination);
    case floatToBool:
        return applyCastAs!floatToBool(layout, source, destination);
    case floatWidth:
        return applyCastAs!floatWidth(layout, source, destination);
    case complexToBool:
        return applyCastAs!complexToBool(layout, source, destination);
    case complexToReal:
        return applyCastAs!complexToReal(layout, source, destination);
    case complexToImaginary:
        return applyCastAs!complexToImaginary(layout, source, destination);
    case complexToIntegral:
        return applyCastAs!complexToIntegral(layout, source, destination);
    case complexWidth:
        return applyCastAs!complexWidth(layout, source, destination);
    case realToComplex:
        return applyCastAs!realToComplex(layout, source, destination);
    case integralToComplex:
        return applyCastAs!integralToComplex(layout, source, destination);
    case imaginaryToComplex:
        return applyCastAs!imaginaryToComplex(layout, source, destination);
    case sarrayToSlice:
        return applyCastAs!sarrayToSlice(layout, source, destination);
    case sarrayToPointer:
        return applyCastAs!sarrayToPointer(layout, source, destination);
    case sliceToPointer:
        return applyCastAs!sliceToPointer(layout, source, destination);
    case pointerToArray:
        return applyCastAs!pointerToArray(layout, source, destination);
    case pointerToIntegral:
        return applyCastAs!pointerToIntegral(layout, source, destination);
    case delegateToPointer:
        return applyCastAs!delegateToPointer(layout, source, destination);
    case reinterpretSlice:
        return applyCastAs!reinterpretSlice(layout, source, destination);
    case toBool:
        return applyCastAs!toBool(layout, source, destination);
    case narrow:
        return applyCastAs!narrow(layout, source, destination);
    case widenSigned:
        return applyCastAs!widenSigned(layout, source, destination);
    case widenUnsigned:
        return applyCastAs!widenUnsigned(layout, source, destination);
    }
}

// Where a bit field lives and how to read and write it: the storage unit
// is `storageBytes` wide, `offset` bytes into the struct, and the field
// takes `width` bits from bit `shift` of the unit. The unit has the width
// of the field's declared type, so a field never reaches into the bytes of
// a neighbour of another type. `snakebite.nativelayout.bitfieldAccess`
// builds it from a declaration; both runtime backends execute it here.
public struct BitfieldAccess {
    public size_t offset;
    public uint storageBytes;
    public uint shift;
    public uint width;
    public bool isSigned;

    // `unit` is the address of the storage unit, `offset` bytes into the
    // struct.
    public long load(in void* unit) const @nogc nothrow {
        ulong value = (loadUnsigned(unit, storageBytes) >> shift) & mask;
        if (isSigned && width < 64 && value & (1UL << (width - 1)))
            value |= ulong.max << width;
        return cast(long) value;
    }

    // Writes the low `width` bits of `value` and keeps every other bit of
    // the unit.
    public void store(void* unit, in ulong value) const @nogc nothrow {
        const bits = mask << shift;
        const unitValue = (loadUnsigned(unit, storageBytes) & ~bits)
            | ((value << shift) & bits);
        storeIntegral(unit, unitValue, storageBytes);
    }

    // The access in one word for a bytecode instruction operand, with the
    // width the loaded value takes in its destination slot.
    public size_t encode(in size_t resultWidth) const @nogc nothrow {
        return shift | (cast(size_t) width << 16)
            | (isSigned ? 1UL << 32 : 0)
            | (resultWidth << 40) | (cast(size_t) storageBytes << 48);
    }

    public static BitfieldAccess decode(in size_t word) @nogc nothrow {
        return BitfieldAccess(
            0, (word >> 48) & 0xff, word & 0xffff, (word >> 16) & 0xffff,
            (word & (1UL << 32)) != 0);
    }

    public static size_t resultWidth(in size_t word) @nogc nothrow {
        return (word >> 40) & 0xff;
    }

    private ulong mask() const @nogc nothrow {
        return ulong.max >> (64 - width);
    }
}
