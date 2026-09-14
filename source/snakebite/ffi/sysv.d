module snakebite.ffi.sysv;


private:


// The register and stack words one call replays. `snakebite_ffi_call_
// sysv_amd64`, in `sysv_amd64.S`, reads and writes this struct at the
// exact byte offsets its `CF_*` constants name - the `static assert`s
// below keep this layout in sync with that file. Change a field here and
// update the matching constant there.
//
// A plan (`snakebite.ffi.plan`) fills `integer`, `sse`, `sseCount`,
// `stack` and `stackWords` before a call, and reads `integerResult` and
// `sseResult` after one; that wiring is step 2 of issue #334; this
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
public alias CallEntry = extern(C) void function(
    const(void)* address,
    CallFrame* frame,
) @system;

// Calls `address` with `frame`'s argument words already filled in,
// through the general entry, leaving its result words in
// `frame.integerResult`/`frame.sseResult`.
//
// `@trusted`: the stub only ever reads and writes through `frame`, at
// the offsets the `static assert`s above pin down, and calls `address`
// exactly as an ordinary indirect call would - nothing about crossing
// into assembly here needs auditing beyond that struct's layout.
pragma(inline, true) public void call(
    const(void)* address, ref CallFrame frame,
) @trusted {
    snakebite_ffi_call_sysv_amd64(address, &frame);
}

// As `call`, but through the leaner integer-only entry above. `plan.d`
// itself calls through a stored `CallEntry` instead of this wrapper
// (see `CallEntry`'s own doc) - this exists so a test can drive that
// entry directly with a hand-filled `CallFrame`, the same way the
// existing tests drive `call`.
pragma(inline, true) public void callInteger(
    const(void)* address, ref CallFrame frame,
) @trusted {
    snakebite_ffi_call_sysv_amd64_integer(address, &frame);
}
