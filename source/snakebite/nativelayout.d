module snakebite.nativelayout;


private:


// Stores `value`'s low `size` bytes at `place`, laid out as compiled D
// lays them out.
//
// The one place that knows how an integral of a given width sits in
// memory. Both the interpreter, writing a literal into a frame slot, and
// the FFI, writing a callee's return register into its destination, do
// exactly this - they differ only in where the value came from, not in
// what happens to it, so the widths live here rather than in each.
public void storeIntegral(void* place, in ulong value, in size_t size) {
    import std.conv: text;

    switch (size) {
        case 1: *cast(ubyte*) place = cast(ubyte) value; return;
        case 2: *cast(ushort*) place = cast(ushort) value; return;
        case 4: *cast(uint*) place = cast(uint) value; return;
        case 8: *cast(ulong*) place = value; return;
        default:
            throw new Exception(
                text("no native layout for an integral of ", size,
                    " byte(s)"),
            );
    }
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

    if (signed)
        switch (size) {
            case 1: return *cast(const(byte)*) place;
            case 2: return *cast(const(short)*) place;
            case 4: return *cast(const(int)*) place;
            case 8: return *cast(const(long)*) place;
            default: break;
        }
    else
        switch (size) {
            case 1: return *cast(const(ubyte)*) place;
            case 2: return *cast(const(ushort)*) place;
            case 4: return *cast(const(uint)*) place;
            case 8: return cast(long) *cast(const(ulong)*) place;
            default: break;
        }

    throw new Exception(
        text("no native layout for an integral of ", size, " byte(s)"),
    );
}

// Where a dynamic array's two fields sit in the value compiled D lays out
// for it, and how many bytes that value is. Field offsets, so reading
// `arr.length` is the fixed-offset read of a field within a value, the
// same operation any other aggregate's field is.
public enum arrayLengthOffset = 0;
public enum arrayPointerOffset = size_t.sizeof;
public enum arrayValueSize = size_t.sizeof + (void*).sizeof;

// Whether `storeIntegral` has a layout for that width, so a caller that
// must decide before it has a value to store asks the same question the
// store itself would.
public bool isIntegralSize(in size_t size) {
    return size == 1 || size == 2 || size == 4 || size == 8;
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

    // The facts for `type`, read from dmd exactly once by the caller
    // that builds this.
    public static TypeFacts of(Type type) {
        import dmd.typesem: size;

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
// This is the one direction that has to know what a value looks like:
// bytes already in native layout are copied from slot to slot, and only a
// value a dmd node stands for has to be made into bytes here.
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
    import dmd.astenums: Tarray, Tfloat32, Tfloat64;
    import std.conv: text;

    // `null` is all-zero bytes in native layout whatever it is stored as -
    // a pointer, a dynamic array's two words, a class reference - so the
    // destination's own width is all this needs to know.
    if (value.isNullExp) {
        memset(place, 0, facts.size);
        return;
    }

    // A string literal's code units live in dmd's own memory for as long
    // as the module holding them does, the way a compiled program's live
    // in its read-only data, so the array points straight at them.
    // Nothing is copied and nothing is allocated.
    if (auto literal = value.isStringExp) {
        if (type.ty != Tarray || facts.size != arrayValueSize)
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

    if (facts.isIntegral) {
        storeIntegral(place, value.toInteger, facts.size);
        return;
    }

    throw new Exception(
        text("no native layout for a value of type `", type.toString, "`"),
    );
}
