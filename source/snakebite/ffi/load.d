module snakebite.ffi.load;

// How to read one eightbyte's source bytes at call time, precomputed
// once from the argument's `Register` at `buildMoves` time - a single
// flat tag instead of `abi.word`'s two-level switch on `Register.Kind`
// then size. A pointer, an 8-byte signed/unsigned integral and a full
// eightbyte of an INTEGER/SSE-class aggregate all read the same way,
// so they share `word64`; `copy` is the rare aggregate eightbyte
// narrower than 8 bytes, the only case that still needs a byte count.
//
// This module imports nothing, so the bytecode VM can use it without the
// DMD frontend.
enum Load : ubyte {
    word64, zero8, zero16, zero32, sign8, sign16, sign32, copy, copy16,
    address,
}

// The bytes of an argument that `load` reads, for the loads that read
// a whole number of bytes from the start of the argument.
size_t loadWidth(Load load) {
    final switch (load) {
        case Load.word64: return 8;
        case Load.zero8: case Load.sign8: return 1;
        case Load.zero16: case Load.sign16: return 2;
        case Load.zero32: case Load.sign32: return 4;
        case Load.copy: case Load.copy16: case Load.address: return 0;
    }
}

// The word of a `Load` from the `value` of a register: its low bytes, extended
// as `load` says. Only the loads that `directWordCallTarget` yields take part.
pragma(inline, true)
ulong extendWord(ulong value, Load load) @safe pure nothrow @nogc {
    final switch (load) with (Load) {
    case word64: return value;
    case zero32: return cast(uint) value;
    case sign32: return cast(ulong) cast(long) cast(int) value;
    case zero8: return cast(ubyte) value;
    case zero16: return cast(ushort) value;
    case sign8: return cast(ulong) cast(long) cast(byte) value;
    case sign16: return cast(ulong) cast(long) cast(short) value;
    case copy:
    case copy16:
    case address:
        assert(false, "directWordCallTarget yields only word loads");
    }
}

// One argument of a direct word call, read from `place` as `load` says.
pragma(inline, true)
ulong loadWord(const(ubyte)* place, Load load) @system pure nothrow @nogc {
    final switch (load) with (Load) {
    case word64: return *cast(const(ulong)*) place;
    case zero32: case sign32:
        return extendWord(*cast(const(uint)*) place, load);
    case zero8: case sign8: return extendWord(*place, load);
    case zero16: case sign16:
        return extendWord(*cast(const(ushort)*) place, load);
    case copy:
    case copy16:
    case address:
        assert(false, "directWordCallTarget yields only word loads");
    }
}

// The two words that a direct word call returns in the integer registers.
struct WordPair { ulong low, high; }

// Calls the `target` of `directWordCallTarget` with the words of the
// registers.
pragma(inline, true)
WordPair callDirectWordsPair(
    const(void)* target, ulong first, ulong second, ulong third,
) @system {
    alias Direct = extern(C) WordPair function(ulong, ulong, ulong);
    return (cast(Direct) target)(first, second, third);
}

// Stores `result` at `place` as a result of `resultWidth` bytes, and writes
// exactly that many. A width of `0` is no result, and stores nothing.
pragma(inline, true)
void storeWordResult(in WordPair result, size_t resultWidth, void* place)
        @system pure nothrow @nogc {
    switch (resultWidth) {
    case 0: break;
    case 1: *cast(ubyte*) place = cast(ubyte) result.low; break;
    case 2: *cast(ushort*) place = cast(ushort) result.low; break;
    case 4: *cast(uint*) place = cast(uint) result.low; break;
    case 16:
        (cast(ulong*) place)[0] = result.low;
        (cast(ulong*) place)[1] = result.high;
        break;
    case 8: *cast(ulong*) place = result.low; break;
    default:
        // `directWordCallTarget` yields no other width: a result of 3, 5, 6 or
        // 7 bytes is a `partial` store, which it rejects.
        assert(false,
            "a direct word call result is 0, 1, 2, 4, 8 or 16 bytes");
    }
}

// Calls the `target` of `directWordCallTarget` with the words of the
// registers, and stores the result of `resultWidth` bytes at `place`.
pragma(inline, true)
void callDirectWords(
    const(void)* target, ulong first, ulong second, ulong third,
    size_t resultWidth, void* place,
) @system {
    storeWordResult(
        callDirectWordsPair(target, first, second, third), resultWidth, place);
}
