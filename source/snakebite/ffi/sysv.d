module snakebite.ffi.sysv;


private:


// The register and stack words one call replays. `snakebite_ffi_call_
// sysv_amd64`, in `sysv_amd64.S`, reads and writes this struct at the
// exact byte offsets its `CF_*` constants name - the `static assert`s
// below keep this layout in sync with that file. Change a field here and
// update the matching constant there.
//
// `snakebite.ffi.plan.CallPlan`'s `callAt` fills `integer` and `sse`
// before a call, at the byte offsets `buildMoves` precomputed once at
// prepare time, along with `sseCount`, `stack` and `stackWords` - skipped
// for a plan that chose the integer-only entry below, which never reads
// them - and reads `integerResult`/`sseResult` back after one; this
// struct only defines the shape the stub itself reads and writes.
public struct CallFrame {
    // The first six integer/pointer-class argument words, in the order
    // `%rdi, %rsi, %rdx, %rcx, %r8, %r9` read them.
    public size_t[6] integer;
    // The first eight SSE-class argument words, in the order
    // `%xmm0 .. %xmm7` read them.
    public double[8] sse;
    // How many of `sse` are real arguments - the value the stub loads
    // into `%al` for a variadic callee.
    public size_t sseCount;
    // The words after the sixth integer and eighth SSE argument, in
    // declaration order. Word 0 lands at the lowest address of the
    // stack area the stub allocates, exactly as the callee's own
    // prologue expects to find them.
    public const(size_t)* stack;
    public size_t stackWords;
    // `%rax`, then `%rdx`, as left by the call.
    public size_t[2] integerResult;
    // `%xmm0`, then `%xmm1`, as left by the call.
    public double[2] sseResult;
}

static assert(CallFrame.integer.offsetof == 0);
static assert(CallFrame.sse.offsetof == 48);
static assert(CallFrame.sseCount.offsetof == 112);
static assert(CallFrame.stack.offsetof == 120);
static assert(CallFrame.stackWords.offsetof == 128);
static assert(CallFrame.integerResult.offsetof == 136);
static assert(CallFrame.sseResult.offsetof == 152);

// `snakebite_ffi_call_sysv_amd64`, the general entry, in `sysv_amd64.S`.
// One of two entry points that make a forward call across the barrier
// (ADR-0001) - `snakebite_ffi_call_sysv_amd64_integer` below is the
// other; everything else in this module and in `plan.d` exists to fill
// and read `frame`.
//
// `frame` is `scope` only in intent, not in the type system: the stub
// keeps its address in a callee-saved register for the width of the call,
// never stores it anywhere else, and never lets it escape.
public extern(C) void snakebite_ffi_call_sysv_amd64(
    const(void)* address,
    CallFrame* frame,
) @system;

// The leaner entry for a plan with no SSE argument registers and no
// stack words (issue #334) - see this function's own comment in
// `sysv_amd64.S` for what it skips relative to the general entry above.
// `snakebite.ffi.plan.CallPlan.buildMoves` picks one of these two
// entries once, at prepare time, from `_sseCount`/`_stackWordCount`;
// this is a choice between two generic entries, not per-signature code,
// which ADR-0011 reserves for a measured need.
public extern(C) void snakebite_ffi_call_sysv_amd64_integer(
    const(void)* address,
    CallFrame* frame,
) @system;

// The exact type both entries above share. `plan.d` stores the address
// of whichever one a plan was built for, in this field's own type, so
// its hot call path is one indirect call through that stored address -
// no branch between the two entries at call time, only at prepare time.
//
// No production code calls either entry any other way - `tests/ut/ffi/
// sysv.d` keeps its own thin `@trusted` wrappers, driving each entry
// directly with a hand-filled `CallFrame`, so that convenience stays
// test-only instead of living here unused outside tests.
public alias CallEntry = extern(C) void function(
    const(void)* address,
    CallFrame* frame,
) @system;


// The callback entry template in `sysv_amd64.S` (ADR-0003): a chunk of
// `callbackEntriesPerChunk` position-independent entries, one shared
// dispatch, and a `CallbackTrailer`. `snakebite.ffi.callback` hands out
// entries from this chunk first, and copies its bytes into a fresh
// executable mapping when it needs more. The `static assert`s in
// `snakebite.ffi.callback` check the label distances against these
// constants at start-up, since the assembler's own `CB_*` defines cannot
// be read from D.
//
// 254 makes one whole chunk (254 entries + the 16-byte trailer + the
// dispatch code, padded to one more entry-sized slot) exactly one 4 KiB
// page, so `allocateChunk`'s `mmap`, which already rounds a chunk's size
// up to a whole page, never wastes part of the page it maps. This must
// stay the same number `CB_ENTRIES_PER_CHUNK` names in `sysv_amd64.S`:
// druntime's page size is a run-time value, not a compile-time one, so
// this cannot derive 254 the way the comment there works it out, and
// repeats the literal instead - `shared static this`, below, is the
// cross-check that keeps the two in agreement.
public enum callbackEntriesPerChunk = 254;
public enum callbackEntryBytes = 16;

// The two words at the end of every chunk. `commonDelta` is the signed
// distance from the trailer itself to `snakebite_ffi_callback_common`,
// which the dispatch adds to its own address to reach the common frame.
// `slots` is the chunk's own slot table - null in the template chunk,
// whose table is a static one in `snakebite.ffi.callback`.
public struct CallbackTrailer {
    public ptrdiff_t commonDelta;
    public void* slots;
}

static assert(CallbackTrailer.sizeof == 16);

public extern(C) void snakebite_ffi_callback_chunk() @system;
public extern(C) void snakebite_ffi_callback_chunk_trailer() @system;
public extern(C) void snakebite_ffi_callback_chunk_end() @system;
public extern(C) void snakebite_ffi_callback_common() @system;
