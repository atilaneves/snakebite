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
