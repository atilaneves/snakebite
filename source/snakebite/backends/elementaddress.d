module snakebite.backends.elementaddress;


private:


import snakebite.ffi.abi: Register;


// Compiled D specifies `core.exception.ArrayIndexError`/`ArraySliceError`
// (both a `RangeError`) for an out-of-bounds index or slice - see
// CLAUDE.md's runtime-semantics rule against reimplementing druntime.
// Both backends reach the failure through `PlanCache.rawPlanOf`, keyed by
// this name, rather than raising a backend-specific exception of their
// own: a guest `catch (RangeError)` then sees the same throwable whichever
// backend ran it, and neither backend re-derives druntime's message.
public immutable string indexBoundsHook = "_d_arraybounds_indexp";
public immutable string sliceBoundsHook = "_d_arraybounds_slicep";

// `_d_arraybounds_indexp(const(char)* file, uint line, size_t index,
// size_t length)` - one call site whether the array is dynamic or
// static, since the hook itself only ever runs on the failure path.
public immutable Register[4] indexBoundsRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
];

// `_d_arraybounds_slicep(const(char)* file, uint line, size_t lower,
// size_t upper, size_t length)`.
public immutable Register[5] sliceBoundsRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
];
