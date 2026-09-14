/* System V AMD64 call stub - ADR-0001.
 *
 * One hand-written function, `snakebite_ffi_call_sysv_amd64`, replays a
 * plan-built `CallFrame` (offsets below) onto the real integer, SSE and
 * stack argument registers, calls the target address indirectly, and
 * writes the raw return registers back into the frame. This file is the
 * only place that makes a forward call across the barrier (ADR-0001).
 *
 * `CallFrame`'s D declaration, with the `static assert`s that keep the
 * offsets below in sync with the struct's real layout, lives in
 * `snakebite/ffi/sysv.d`. Change a field there and update the matching
 * `CF_*` constant here.
 *
 * Full CFI is required, not optional: a D exception thrown by the called
 * function must unwind through this frame exactly like any other native
 * frame (ADR-0004). Compiler inline assembly cannot emit `.cfi_`
 * directives, which is why this lives in its own `.S` file, preprocessed
 * and assembled like any other translation unit.
 */

#if !(defined(__x86_64__) && defined(__linux__))
#error "snakebite_ffi_call_sysv_amd64 is implemented for Linux x86-64 only"
#endif

/* Byte offsets into `snakebite.ffi.sysv.CallFrame` - see that module's
 * `static assert`s for the definitions these must match. */
#define CF_INTEGER         0   /* size_t[6] integer */
#define CF_SSE              48  /* double[8] sse */
#define CF_SSE_COUNT        112 /* size_t sseCount */
#define CF_STACK            120 /* const(size_t)* stack */
#define CF_STACK_WORDS      128 /* size_t stackWords */
#define CF_INTEGER_RESULT   136 /* size_t[2] integerResult */
#define CF_SSE_RESULT       152 /* double[2] sseResult */

    .text
    .globl  snakebite_ffi_call_sysv_amd64
    .type   snakebite_ffi_call_sysv_amd64, @function
    .align  16

/* extern(C) void snakebite_ffi_call_sysv_amd64(
 *     const void* address, -- %rdi
 *     CallFrame* frame,    -- %rsi
 * );
 *
 * `%rbx` holds `address` and `%r12` holds `frame` across the call: both
 * are callee-saved, so they survive the indirect call to `address`
 * untouched, and are themselves saved/restored here.
 */
snakebite_ffi_call_sysv_amd64:
    .cfi_startproc

    /* %rbp stays pushed on every call, even when stackWords == 0 and
     * %rsp would otherwise need no frame pointer to unwind through
     * this function. The stack-word branch below is a runtime test on
     * the same code path, not two copies of this function's prologue,
     * so the `.cfi_` directives below it are static and must describe
     * one CFA rule that holds on both sides of that branch. Splitting
     * the prologue in two to drop this one push on the zero-stack-word
     * path would mean two different CFA descriptions live at the same
     * merged address after the branch, which unwinding (ADR-0004)
     * cannot express - not worth risking for one push. */
    pushq   %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset rbp, -16
    movq    %rsp, %rbp
    .cfi_def_cfa_register rbp

    pushq   %rbx
    .cfi_offset rbx, -24
    pushq   %r12
    .cfi_offset r12, -32

    movq    %rdi, %rbx      /* rbx = address */
    movq    %rsi, %r12      /* r12 = frame */

    /* Copy the stack words in order, word 0 at the lowest address.
     * Almost every call has zero stack words; `rep movsq` still pays a
     * fixed microcode startup cost even when %rcx == 0, which dominated
     * the barrier cost measured for issue #334. A plain test-and-skip
     * plus a movq loop avoids that cost in the common case. The
     * alignment arithmetic and the `subq` against %rsp are dead work
     * for the same common case, so both live under this one test now:
     * with zero stack words, %rsp needs no adjustment at all, since the
     * three pushes above already leave it 16-byte aligned (see the
     * allocation comment below). This also reads `stackWords` once,
     * into %rcx, instead of the separate %rax and %rcx reads of the
     * same field the two computations used before. */
    movq    CF_STACK_WORDS(%r12), %rcx
    testq   %rcx, %rcx
    jz      1f

    /* Allocate frame.stackWords words, rounded so %rsp is 16-byte
     * aligned at the `call` below. `%rsp` is already 16-byte aligned
     * here (three 8-byte pushes since entry, entry itself guaranteed
     * 8 mod 16 by the SysV ABI), so rounding the byte count up to a
     * multiple of 16 keeps it aligned after the subtraction. */
    movq    %rcx, %rax
    shlq    $3, %rax
    addq    $15, %rax
    andq    $-16, %rax
    subq    %rax, %rsp

    movq    CF_STACK(%r12), %rsi
    movq    %rsp, %rdi
0:  movq    (%rsi), %rax
    movq    %rax, (%rdi)
    addq    $8, %rsi
    addq    $8, %rdi
    decq    %rcx
    jnz     0b
1:

    /* Load the integer argument registers. Always all six; a callee
     * that takes fewer simply never reads the rest. */
    movq    CF_INTEGER+0(%r12), %rdi
    movq    CF_INTEGER+8(%r12), %rsi
    movq    CF_INTEGER+16(%r12), %rdx
    movq    CF_INTEGER+24(%r12), %rcx
    movq    CF_INTEGER+32(%r12), %r8
    movq    CF_INTEGER+40(%r12), %r9

    /* Load the SSE argument registers. Always all eight, for the same
     * reason as the integer registers above.
     *
     * A test-and-skip guarding these eight loads (mirroring the
     * stack-word one above) was tried for issue #334: `sseCount`
     * (`buildMoves`' `_sseCount` in `plan.d`) is exactly the number of
     * SSE registers the plan filled, so skipping is safe whenever it is
     * zero. Measured on `at.ffi.cost` (LDC -release -O), it made the
     * call slower, not faster: this branch lands right before the
     * `call *%rbx` below, and the two adjacent branches cost more in
     * front-end/predictor overhead around the indirect call than the
     * eight independent `movsd` loads ever cost - those are cheap for
     * the CPU to execute out-of-order while the call itself is still
     * resolving. Unlike the stack-word copy, an all-zero-register
     * `movsd` here is not paying a fixed microcode startup cost the way
     * `rep movsq` did, so there was nothing expensive here to skip. */
    movsd   CF_SSE+0(%r12), %xmm0
    movsd   CF_SSE+8(%r12), %xmm1
    movsd   CF_SSE+16(%r12), %xmm2
    movsd   CF_SSE+24(%r12), %xmm3
    movsd   CF_SSE+32(%r12), %xmm4
    movsd   CF_SSE+40(%r12), %xmm5
    movsd   CF_SSE+48(%r12), %xmm6
    movsd   CF_SSE+56(%r12), %xmm7

    /* `%al` reports the SSE register count to a variadic callee; a
     * non-variadic callee ignores it. A full-register load, not `movb`,
     * so there is no partial-register merge against a stale %eax before
     * the `call` below. */
    movq    CF_SSE_COUNT(%r12), %rax

    call    *%rbx

    /* Every host call, whatever it actually returns, leaves its result
     * words in these four registers (ADR-0002); the caller in
     * `sysv.d`/`plan.d` reads only the ones its own return shape needs. */
    movq    %rax, CF_INTEGER_RESULT+0(%r12)
    movq    %rdx, CF_INTEGER_RESULT+8(%r12)
    movsd   %xmm0, CF_SSE_RESULT+0(%r12)
    movsd   %xmm1, CF_SSE_RESULT+8(%r12)

    /* `%rbp` itself does not move until the final pop below, so the
     * CFA stays "%rbp + 16" (established above) through both of these
     * pops; only `.cfi_restore` is needed to say where %r12 and %rbx
     * live again. */
    leaq    -16(%rbp), %rsp
    popq    %r12
    .cfi_restore r12
    popq    %rbx
    .cfi_restore rbx

    /* Popping %rbp moves it, so the CFA can no longer be described
     * relative to it: after this pop, %rsp itself points at the
     * return address, eight bytes below the CFA. */
    popq    %rbp
    .cfi_def_cfa rsp, 8
    .cfi_restore rbp

    ret

    .cfi_endproc
    .size   snakebite_ffi_call_sysv_amd64, . - snakebite_ffi_call_sysv_amd64

    .section .note.GNU-stack,"",@progbits
