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

// One argument of a direct word call, read from `place` as `load` says. Only
// the loads that `directWordCallTarget` yields take part.
pragma(inline, true)
ulong loadWord(const(ubyte)* place, Load load) @system pure nothrow @nogc {
    final switch (load) with (Load) {
    case word64: return *cast(const(ulong)*) place;
    case zero32: return *cast(const(uint)*) place;
    case sign32: return cast(ulong) cast(long) *cast(const(int)*) place;
    case zero8: return *place;
    case zero16: return *cast(const(ushort)*) place;
    case sign8: return cast(ulong) cast(long) *cast(const(byte)*) place;
    case sign16: return cast(ulong) cast(long) *cast(const(short)*) place;
    case copy:
    case copy16:
    case address:
        assert(false, "directWordCallTarget yields only word loads");
    }
}

// Calls the `target` of `directWordCallTarget` with `words` placed in the
// registers `order` says, and stores the result of `resultWidth` bytes at
// `place`, unless `place` is null.
pragma(inline, true)
void callDirectWords(
    const(void)* target, in ulong[3] words, in ubyte[3] order,
    size_t resultWidth, void* place,
) @system {
    static struct Pair { ulong low, high; }
    alias Direct = extern(C) Pair function(ulong, ulong, ulong);

    const result = (cast(Direct) target)(
        words[order[0]], words[order[1]], words[order[2]]);
    if (place is null)
        return;
    switch (resultWidth) {
    case 1: *cast(ubyte*) place = cast(ubyte) result.low; break;
    case 2: *cast(ushort*) place = cast(ushort) result.low; break;
    case 4: *cast(uint*) place = cast(uint) result.low; break;
    case 16:
        (cast(ulong*) place)[0] = result.low;
        (cast(ulong*) place)[1] = result.high;
        break;
    default: *cast(ulong*) place = result.low; break;
    }
}
