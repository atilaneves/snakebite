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

// `snakebite_ffi_call_sysv_amd64` in `sysv_amd64.S`. The only place a
// forward call across the barrier happens (ADR-0001); everything else in
// this module and in `plan.d` exists to fill and read `frame`.
//
// `frame` is `scope` only in intent, not in the type system: the stub
// keeps its address in a callee-saved register for the width of the call,
// never stores it anywhere else, and never lets it escape.
public extern(C) void snakebite_ffi_call_sysv_amd64(
    const(void)* address,
    CallFrame* frame,
) @system;

// Calls `address` with `frame`'s argument words already filled in,
// leaving its result words in `frame.integerResult`/`frame.sseResult`.
//
// `@trusted`: the stub only ever reads and writes through `frame`, at
// the offsets the `static assert`s above pin down, and calls `address`
// exactly as an ordinary indirect call would - nothing about crossing
// into assembly here needs auditing beyond that struct's layout.
public void call(const(void)* address, ref CallFrame frame) @trusted {
    snakebite_ffi_call_sysv_amd64(address, &frame);
}
