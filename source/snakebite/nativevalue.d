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

pragma(inline, true) public void floatingToIntegral(
    void* destination,
    in void* source,
    in size_t destinationSize,
    in size_t sourceSize,
    in bool unsignedDestination,
) @nogc nothrow {
    const value = loadFloating(source, sourceSize);
    const converted = unsignedDestination
        ? cast(long) cast(ulong) value
        : cast(long) value;
    storeIntegral(destination, cast(ulong) converted, destinationSize);
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

public enum arrayLengthOffset = 0;
public enum arrayPointerOffset = size_t.sizeof;
public enum arrayValueSize = size_t.sizeof + (void*).sizeof;

// A delegate is `struct { void* ptr; void* funcptr; }`: the context word
// first, the function word after it.
public enum delegateContextOffset = 0;
public enum delegateFunctionOffset = (void*).sizeof;
public enum delegateValueSize = 2 * (void*).sizeof;

// Which byte-level transform a cast performs, once `snakebite.backends.
// casts.classify` has decided it. `applyCast` below carries out every
// kind in this enum with no control flow of its own beyond a `final
// switch` - `classReference`, `zero`, and `unsupported` each need a
// backend's own control flow or rejection handling instead, so
// `snakebite.backends.casts.layoutOf` never produces one of those
// three, and this enum carries no member for any of them.
public enum CastKind {
    integralToFloat,
    floatToIntegral,
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

// Executes every `CastKind` above: reads bytes at `source` and writes
// `layout.destSize` bytes at `destination`, in the native layout every
// backend already shares - the one place this decision is made,
// instead of once per backend. The tree-walking interpreter and the
// bytecode VM both call this directly; the bytecode compiler only ever
// builds the `CastLayout` that call reads at run time.
//
// `source` always points at bytes that already hold the value a kind
// reads: an evaluated operand for most of them, or - for
// `sarrayToSlice`/`sarrayToPointer` - a pointer-sized slot holding the
// operand's own address, the shape both backends already produce for
// "the address of an expression" (`addressOf`/`compileAddress`).
public void applyCast(
    in CastLayout layout,
    in void* source,
    void* destination,
) @nogc nothrow {
    final switch (layout.kind) with (CastKind) {
    case integralToFloat:
        integralToFloating(destination, source, layout.destSize,
            layout.sourceSize, layout.sourceUnsigned);
        return;

    case floatToIntegral:
        floatingToIntegral(destination, source, layout.destSize,
            layout.sourceSize, layout.destUnsigned);
        return;

    case floatToBool:
        floatingToBool(destination, source, layout.sourceSize);
        return;

    case floatWidth:
        storeFloating(
            destination, loadFloating(source, layout.sourceSize),
            layout.destSize,
        );
        return;

    case complexToBool:
        storeIntegral(
            destination, complexTruth(source, layout.sourceSize),
            layout.destSize,
        );
        return;

    case complexToReal:
        storeFloating(
            destination, loadComplexRe(source, layout.sourceSize),
            layout.destSize,
        );
        return;

    case complexToImaginary:
        storeFloating(
            destination, loadComplexIm(source, layout.sourceSize),
            layout.destSize,
        );
        return;

    case complexToIntegral:
        floatingToIntegral(destination, source, layout.destSize,
            layout.sourceSize / 2, layout.destUnsigned);
        return;

    case complexWidth:
        storeComplex(
            destination, loadComplexRe(source, layout.sourceSize),
            loadComplexIm(source, layout.sourceSize), layout.destSize,
        );
        return;

    case realToComplex:
        storeComplex(
            destination, loadFloating(source, layout.sourceSize), 0.0L,
            layout.destSize,
        );
        return;

    case integralToComplex: {
        const value =
            loadIntegral(source, layout.sourceSize, !layout.sourceUnsigned);
        const re = layout.sourceUnsigned
            ? cast(real) cast(ulong) value : cast(real) value;
        storeComplex(destination, re, 0.0L, layout.destSize);
        return;
    }

    case imaginaryToComplex:
        storeComplex(
            destination, 0.0L, loadFloating(source, layout.sourceSize),
            layout.destSize,
        );
        return;

    case sarrayToSlice: {
        const address = loadUnsigned(source, size_t.sizeof);
        auto bytes = cast(ubyte*) destination;
        storeIntegral(
            bytes + arrayLengthOffset, layout.staticLength, size_t.sizeof);
        storeIntegral(bytes + arrayPointerOffset, address, size_t.sizeof);
        return;
    }

    case sarrayToPointer:
        storeIntegral(
            destination, loadUnsigned(source, size_t.sizeof),
            layout.destSize,
        );
        return;

    case sliceToPointer:
        storeIntegral(
            destination,
            loadUnsigned(
                cast(ubyte*) source + arrayPointerOffset, size_t.sizeof),
            layout.destSize,
        );
        return;

    case pointerToArray: {
        import core.stdc.string: memcpy;

        const address = loadUnsigned(source, size_t.sizeof);
        memcpy(
            destination, cast(const(void)*) cast(size_t) address,
            layout.destSize,
        );
        return;
    }

    case pointerToIntegral:
        storeIntegral(
            destination, loadUnsigned(source, size_t.sizeof),
            layout.destSize,
        );
        return;

    case delegateToPointer:
        storeIntegral(
            destination,
            loadUnsigned(
                cast(ubyte*) source + delegateContextOffset, size_t.sizeof),
            layout.destSize,
        );
        return;

    case reinterpretSlice: {
        const sourceLength = cast(size_t) loadUnsigned(
            cast(ubyte*) source + arrayLengthOffset, size_t.sizeof);
        const pointer = loadUnsigned(
            cast(ubyte*) source + arrayPointerOffset, size_t.sizeof);
        const newLength =
            sourceLength * layout.sourceElementSize / layout.destElementSize;
        auto bytes = cast(ubyte*) destination;
        storeIntegral(bytes + arrayLengthOffset, newLength, size_t.sizeof);
        storeIntegral(bytes + arrayPointerOffset, pointer, size_t.sizeof);
        return;
    }

    case toBool:
        storeIntegral(
            destination, loadUnsigned(source, layout.sourceSize) != 0,
            layout.destSize,
        );
        return;

    case narrow:
    case widenSigned:
    case widenUnsigned:
        storeIntegral(
            destination,
            cast(ulong) loadIntegral(
                source, layout.sourceSize, !layout.sourceUnsigned),
            layout.destSize,
        );
        return;
    }
}
