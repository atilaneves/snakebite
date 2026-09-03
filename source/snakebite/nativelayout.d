module snakebite.nativelayout;


private:


import snakebite.nativevalue:
    nativeArrayLengthOffset = arrayLengthOffset,
    nativeArrayPointerOffset = arrayPointerOffset,
    nativeArrayValueSize = arrayValueSize,
    nativeDelegateContextOffset = delegateContextOffset,
    nativeDelegateFunctionOffset = delegateFunctionOffset,
    nativeDelegateValueSize = delegateValueSize,
    nativeIsIntegralSize = isIntegralSize,
    nativeLoadIntegral = loadIntegral,
    nativeStoreIntegral = storeIntegral;

public alias arrayLengthOffset = nativeArrayLengthOffset;
public alias arrayPointerOffset = nativeArrayPointerOffset;
public alias arrayValueSize = nativeArrayValueSize;
public alias delegateContextOffset = nativeDelegateContextOffset;
public alias delegateFunctionOffset = nativeDelegateFunctionOffset;
public alias delegateValueSize = nativeDelegateValueSize;

public bool isIntegralSize(in size_t size) {
    return nativeIsIntegralSize(size);
}

// Keep the DMD-facing module's historical error behavior while the actual
// byte operations live in the DMD-free native-value module. Backend code
// that already validated its widths can call that module directly.
public void storeIntegral(void* place, in ulong value, in size_t size) {
    import std.conv: text;

    if (!isIntegralSize(size))
        throw new Exception(
            text("no native layout for an integral of ", size, " byte(s)"),
        );
    nativeStoreIntegral(place, value, size);
}

// Reads `size` bytes at `place`, laid out as compiled D lays them out, and
// widens them to 64 bits: sign-extended if `signed`, zero-extended
// otherwise. The result is a `long` either way - for an unsigned width the
// caller reinterprets it as `ulong`, the same 64 bits, since D has no
// integral type wider than either.
//
// The counterpart to `storeIntegral`: an interpreter comparing two
// integral operands needs the bytes-to-value direction as well as the one
// `storeIntegral` already covers.
public long loadIntegral(in void* place, in size_t size, in bool signed) {
    import std.conv: text;

    if (!isIntegralSize(size))
        throw new Exception(
            text("no native layout for an integral of ", size, " byte(s)"),
        );
    return nativeLoadIntegral(place, size, signed);
}

// What a caller on a hot execution path repeatedly asks a dmd `Type`
// for - its size, its alignment, whether it is integral, and if so
// whether it is signed - decided once and kept, instead of re-entering
// dmd's semantic-analysis machinery (`Type.size`, `TypeBasic.alignsize`,
// `isIntegral`, `isUnsigned`) on every visit of the same node. Shared
// between backends (not owned by the interpreter package) because any
// tree-walking or bytecode backend asks a dmd `Type` the same four
// questions to lay a value out in native memory.
public struct TypeFacts {
    import dmd.mtype: Type;

    public size_t size;
    public uint alignment;
    public bool isIntegral;
    public bool isUnsigned;
    // Whether `type` is a dynamic array (`T[]`) - the native `{length,
    // pointer}` pair, always `arrayValueSize` bytes regardless of `T`. A
    // caller that only moves a value between slots (`opCopy`/`opConstant`,
    // parameter passing, a return) needs nothing more than this and `size`
    // to do so correctly; only a caller that indexes into the array needs
    // `elementSize` as well.
    public bool isDynamicArray;
    // The element type's own size, meaningful only when `isDynamicArray` is
    // `true` - what indexing has to multiply an index by to find an
    // element's byte offset from the array's own pointer word.
    public size_t elementSize;

    // The facts for `type`, read from dmd exactly once by the caller
    // that builds this.
    public static TypeFacts of(Type type) {
        import dmd.astenums: Tarray;
        import dmd.typesem: alignsize, isIntegral, isUnsigned, nextOf, size;

        if (type.ty == Tarray)
            return TypeFacts(
                arrayValueSize, size_t.alignof, false, false, true,
                type.nextOf.size,
            );

        return TypeFacts(
            type.size,
            type.alignsize,
            type.isIntegral,
            type.isUnsigned,
        );
    }
}

// Rounds `offset` up to the next multiple of `alignment`, by way of dmd's
// default field-alignment rule (`aggregate.alignmember`, the same one it
// uses to lay out a struct's fields), rather than reimplementing it: no
// generic round-up-to-alignment helper exists anywhere else in the dmd
// frontend sources. Parameter frame offsets are ordinarily assigned far
// downstream of this, in dmd's machine-code backend, which this project
// does not use - laying out frames here is unavoidable, not a case of
// redoing work dmd already did for us at this stage.
public size_t alignUp(in size_t offset, in uint alignment) {
    import dmd.aggregate: alignmember;

    return alignmember(defaultAlignment, alignment, cast(uint) offset);
}

// `alignmember` takes a `structalign_t` for cases with an explicit
// `align(N)`; there is none here, so `defaultAlignment` is always the
// type's own natural alignment - and it is built once at module load,
// not on every call, since this runs on every parameter offset and every
// frame stack push.
private imported!"dmd.astenums".structalign_t defaultAlignment;

shared static this() {
    defaultAlignment.setDefault;
}

// Writes a dmd constant-folded `value` into `place` as `type`'s native
// layout: `null` as zero bytes, a string literal as the two words of a
// dynamic array over the literal's own code units, a `float` or `double`
// cast for the floating point widths, an integral by way of
// `storeIntegral`.
//
// The interpreter, writing a literal into a frame slot, and the CTFE
// backend, writing a call's result into its caller's return place, both
// convert a dmd value to native bytes this same way, differing only in
// where `type` and `value` come from. Neither caller has `type`'s facts
// in hand at this call site, so this derives them itself, once.
public void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, TypeFacts.of(type), value, place);
}

// As above, but for a caller - the interpreter's hot literal-evaluation
// path - that already holds `type`'s facts, so this does not re-derive
// `isIntegral`/`size` from `type` a second time.
public void storeValue(
    imported!"dmd.mtype".Type type,
    in TypeFacts facts,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    import core.stdc.string: memset;
    import dmd.astenums: Tarray, Tfloat32, Tfloat64, Tfloat80, Tsarray;
    import dmd.expressionsem: toInteger, toReal;
    import dmd.typesem: nextOf;
    import std.conv: text;

    // `null` is all-zero bytes whatever it is stored as - a pointer, a
    // dynamic array's two words, a class reference - so the destination's
    // width is all this needs to know.
    if (value.isNullExp) {
        memset(place, 0, facts.size);
        return;
    }

    // The array points straight at the literal's own code units instead
    // of copying them: they live in dmd's memory, kept alive by the module
    // that holds them, for as long as that module is reachable. Nothing
    // the guest holds is a root - a frame slot is unscanned host memory
    // and a static slot is `NO_SCAN` - so a guest slice of a literal stays
    // valid only while dmd keeps the module.
    if (auto literal = value.isStringExp) {
        // The literal's code-unit width has to match the destination's
        // element width, or `literal.len` would be the wrong length for
        // the bytes the pointer aims at. dmd inserts a `CastExp` for any
        // change of width, and the backends refuse those, so this refuses
        // by name rather than trusting the destination.
        import dmd.typesem: size;

        auto element = type.nextOf;
        if (type.ty != Tarray || facts.size != arrayValueSize
                || element is null || literal.sz != element.size)
            throw new Exception(
                text("no native layout for the string literal `",
                    value.toString, "` as a `", type.toString, "`"),
            );

        auto bytes = cast(ubyte*) place;
        storeIntegral(bytes + arrayLengthOffset, literal.len, size_t.sizeof);
        *cast(const(void)**) (bytes + arrayPointerOffset) =
            literal.peekData.ptr;
        return;
    }

    if (type.ty == Tfloat32) {
        *cast(float*) place = cast(float) value.toReal;
        return;
    }

    if (type.ty == Tfloat64) {
        *cast(double*) place = cast(double) value.toReal;
        return;
    }

    // `real` is dmd's own constant-folding type - `toReal` already returns
    // one - so this is a plain store, unlike the `float`/`double` cases
    // above, which narrow it.
    if (type.ty == Tfloat80) {
        *cast(real*) place = value.toReal;
        return;
    }

    // A static array's `.init` is every element's own `.init`, but for a
    // zero integer value that is the same all-zero bytes regardless of
    // the element type - the same shortcut already taken for a struct's
    // zero `.init` above, rather than recursing element by element to
    // reach the same bytes.
    if ((type.isTypeStruct !is null || type.ty == Tsarray)
            && value.isIntegerExp && value.toInteger == 0) {
        memset(place, 0, facts.size);
        return;
    }

    if (facts.isIntegral) {
        storeIntegral(place, value.toInteger, facts.size);
        return;
    }

    throw new Exception(
        text("no native layout for a value of type `", type.toString, "`"),
    );
}
