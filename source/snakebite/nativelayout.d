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
