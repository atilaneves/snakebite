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
