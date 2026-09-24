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
// casts.classify` has decided it. This is the one enum both
// `snakebite.backends.casts.CastPlan.kind` (classify's own answer,
// while dmd's types are still in scope) and `applyCast`/`applyCastAs`
// below (turning that answer into bytes, once they are not) read -
// `snakebite.backends.bytecode.vm` may not import DMD frontend
// modules, so keeping the enum here, DMD-free, is what lets it name
// the same `CastKind` its own per-kind `opCastAs`/`opCastFixedAs` ops
// are instantiated over. `applyCastAs` below carries out every kind
// except `copy`, `classReference`, `zero`, and `unsupported`: each of
// those needs a backend's own control flow (a plain move, a class
// reference adjustment, a zero fill) or rejection instead, so
// `applyCast`'s own `final switch` hits `assert(0)` on any of the
// four - both backends' `compileCast`/`visitUnloweredCast` switches
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
    // No kind above applies; the backend rejects the cast itself.
    unsupported,
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
// `classReference`, `zero`, and `unsupported` never reach here: both
// backends' `compileCast`/`visitUnloweredCast` switches handle each of
// the four with their own control flow or rejection before either one
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
    case unsupported:
        assert(0,
            "applyCast: unsupported casts are rejected before reaching "
            ~ "applyCast");
    case integralToFloat:
        return applyCastAs!integralToFloat(layout, source, destination);
    case floatToIntegral:
        return applyCastAs!floatToIntegral(layout, source, destination);
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
