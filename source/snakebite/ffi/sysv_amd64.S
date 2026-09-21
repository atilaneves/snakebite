/* System V AMD64 call stub - ADR-0001.
 *
 * One stub with two entries, chosen at prepare time (issue #334):
 *
 * - `snakebite_ffi_call_sysv_amd64`, the general entry, replays a
 *   plan-built `CallFrame` (offsets below) onto the real integer, SSE
 *   and stack argument registers, calls the target address indirectly,
 *   and writes the raw return registers back into the frame.
 * - `snakebite_ffi_call_sysv_amd64_integer`, the leaner entry, does the
 *   same for the common shape a plan already knows at prepare time it
 *   will never need: no SSE argument registers, no stack words. It
 *   skips the frame pointer, the stack-word test, and the eight SSE
 *   register loads the general entry always pays for.
 *
 * `snakebite.ffi.plan.CallPlan.buildMoves` decides once, per plan, which
 * entry a call uses, and stores its address; this is a prepare-time
 * choice between two generic entries, not per-signature code, which
 * ADR-0011 reserves for a measured need.
 *
 * This file is the only place that makes a forward call across the
 * barrier (ADR-0001). It also holds the callback entry template and the
 * common callback frame, at the end (ADR-0003).
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
#define CF_REAL_RESULT      176 /* real realResult */
#define CF_REAL_RESULT_USED 192 /* bool realResultUsed */

    .text
    .globl  snakebite_ffi_call_sysv_amd64
    .type   snakebite_ffi_call_sysv_amd64, @function
    .align  16

/* extern(C) void snakebite_ffi_call_sysv_amd64(
 *     const void* address, -- %rdi
 *     CallFrame* frame,    -- %rsi
 * );
 *
 * The general entry: used whenever a plan has an SSE argument register,
 * a stack word, or both (`snakebite_ffi_call_sysv_amd64_integer` below
 * is the leaner entry for the common shape that has neither).
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
    cmpb    $0, CF_REAL_RESULT_USED(%r12)
    je      2f
    fstpt   CF_REAL_RESULT(%r12)
2:

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


    .globl  snakebite_ffi_call_sysv_amd64_integer
    .type   snakebite_ffi_call_sysv_amd64_integer, @function
    .align  16

/* extern(C) void snakebite_ffi_call_sysv_amd64_integer(
 *     const void* address, -- %rdi
 *     CallFrame* frame,    -- %rsi
 * );
 *
 * The leaner entry (issue #334): chosen at prepare time, by `plan.d`'s
 * `buildMoves`, only for a plan with no SSE argument registers and no
 * stack words. One push, six integer register loads, the indirect
 * call, and the four result stores - no frame pointer, no stack-word
 * test, no SSE register loads.
 *
 * `%rbx` holds `frame` across the call: callee-saved, so it survives
 * the indirect call to `address` untouched, and is itself saved and
 * restored here. `address` needs no callee-saved register: it is read
 * once, into the caller-saved `%r10`, immediately before `call *%r10`
 * consumes it, so nothing has to preserve it across the call.
 *
 * Entry `%rsp` is 8 mod 16 (SysV ABI); this one push leaves it
 * 16-byte aligned for the `call` below, with no stack area to
 * allocate.
 */
snakebite_ffi_call_sysv_amd64_integer:
    .cfi_startproc

    pushq   %rbx
    .cfi_def_cfa_offset 16
    .cfi_offset rbx, -16

    movq    %rsi, %rbx      /* rbx = frame */
    movq    %rdi, %r10      /* r10 = address (scratch, dead after the call) */

    /* Load the integer argument registers. Always all six; a callee
     * that takes fewer simply never reads the rest - same as the
     * general entry above. */
    movq    CF_INTEGER+0(%rbx), %rdi
    movq    CF_INTEGER+8(%rbx), %rsi
    movq    CF_INTEGER+16(%rbx), %rdx
    movq    CF_INTEGER+24(%rbx), %rcx
    movq    CF_INTEGER+32(%rbx), %r8
    movq    CF_INTEGER+40(%rbx), %r9

    /* `%al` reports 0 SSE registers used, for a variadic callee - this
     * entry is only chosen for a plan with no SSE argument registers,
     * but a variadic callee still reads %al unconditionally (see the
     * `variadicCallee` tests in `tests/ut/ffi/sysv.d`). */
    xorl    %eax, %eax

    call    *%r10

    /* Same four result registers as the general entry above (ADR-0002):
     * a callee may still return in SSE registers even though it took no
     * SSE arguments itself - `double f(long)`, for example. */
    movq    %rax, CF_INTEGER_RESULT+0(%rbx)
    movq    %rdx, CF_INTEGER_RESULT+8(%rbx)
    movsd   %xmm0, CF_SSE_RESULT+0(%rbx)
    movsd   %xmm1, CF_SSE_RESULT+8(%rbx)

    popq    %rbx
    .cfi_def_cfa_offset 8
    .cfi_restore rbx

    ret

    .cfi_endproc
    .size   snakebite_ffi_call_sysv_amd64_integer, . - snakebite_ffi_call_sysv_amd64_integer



/* Callback entries - ADR-0003.
 *
 * Host code calls a guest function through one of these entries. Each
 * entry is position independent: it only ever computes its own address
 * and its chunk's trailer address relative to `%rip`, so a byte-for-byte
 * copy of the whole chunk works wherever it lands. `snakebite.ffi.
 * callback` grows the pool that way when every slot in the chunks it has
 * is taken: it copies this template chunk into a fresh read-write
 * mapping, patches the two trailer words, and flips the mapping to
 * read-execute. Nothing here embeds an absolute address.
 *
 * Chunk layout, matched by the D side (`snakebite.ffi.sysv`, which
 * `static assert`s the sizes and offsets against the labels below):
 *
 *   entry 0 .. entry CB_ENTRIES_PER_CHUNK-1   CB_ENTRY_BYTES each
 *   trailer                                    two words, see below
 *   dispatch                                   shared by every entry
 *
 * An entry loads its own address into `%r10` and jumps to `dispatch`.
 * `dispatch` loads the trailer's address into `%r11`, adds the trailer's
 * first word to it - the signed distance from the trailer to
 * `snakebite_ffi_callback_common` - and jumps there. The distance is a
 * link-time constant for the chunk in this file, and is patched for a
 * copied chunk. The trailer's second word is the copied chunk's slot
 * table, null for the chunk in this file, which the handler maps to its
 * own static table. `%r10`, `%r11` and `%rax` are scratch under the
 * System V ABI, so touching them clobbers no argument.
 *
 * No entry ever has a frame on the stack: it is a `jmp`, not a `call`,
 * so no unwind information is needed for a copied chunk either. The
 * frame that does exist during a callback is `snakebite_ffi_callback_
 * common`'s, below, which carries full CFI (ADR-0004).
 *
 * CB_ENTRIES_PER_CHUNK is 254 so the whole chunk - entries, trailer and
 * dispatch together - is exactly one 4 KiB page: 254 * CB_ENTRY_BYTES
 * (4064) + the 16-byte trailer + dispatch padded to one more
 * CB_ENTRY_BYTES slot (16) = 4096. `allocateChunk`'s `mmap` already
 * rounds a chunk's size up to a whole page, so this size wastes none of
 * the page it maps; the D side (`snakebite.ffi.sysv.
 * callbackEntriesPerChunk`) cannot derive the same 254 at compile time,
 * since druntime's page size is a run-time value, so it repeats this
 * same literal instead, and `shared static this` in `snakebite.ffi.
 * callback` cross-checks the two against each other at start-up.
 */

#define CB_ENTRIES_PER_CHUNK 254
#define CB_ENTRY_BYTES       16
/* `CallFrame` is 208 bytes, already rounded for 16-byte alignment. */
#define CB_FRAME_BYTES       208

    .globl  snakebite_ffi_callback_chunk
    .type   snakebite_ffi_callback_chunk, @function
    .balign 16
snakebite_ffi_callback_chunk:
    .rept   CB_ENTRIES_PER_CHUNK
0:  leaq    0b(%rip), %r10
    jmp     .Lsnakebite_ffi_callback_dispatch
    .balign CB_ENTRY_BYTES, 0xcc
    .endr

    .globl  snakebite_ffi_callback_chunk_trailer
    .type   snakebite_ffi_callback_chunk_trailer, @object
snakebite_ffi_callback_chunk_trailer:
    .quad   .Lsnakebite_ffi_callback_common - snakebite_ffi_callback_chunk_trailer
    .quad   0

.Lsnakebite_ffi_callback_dispatch:
    leaq    snakebite_ffi_callback_chunk_trailer(%rip), %r11
    movq    (%r11), %rax
    addq    %r11, %rax
    jmp     *%rax
    /* Pads dispatch (15 bytes) up to one CB_ENTRY_BYTES slot, so the
     * chunk's total size comes out to a whole number of pages - see
     * this section's own comment above. */
    .balign CB_ENTRY_BYTES, 0xcc

    .globl  snakebite_ffi_callback_chunk_end
    .type   snakebite_ffi_callback_chunk_end, @object
snakebite_ffi_callback_chunk_end:
    .size   snakebite_ffi_callback_chunk, . - snakebite_ffi_callback_chunk


    .globl  snakebite_ffi_callback_common
    .type   snakebite_ffi_callback_common, @function
    .balign 16

/* Reached by `jmp` from a chunk's dispatch with the host caller's return
 * address still on top of the stack, `%r10` = the entry's address and
 * `%r11` = the chunk's trailer address. Spills the argument registers
 * into a `CallFrame` (the same struct the forward stub reads, so the
 * handler can replay a plan's moves in reverse), records where the
 * caller's stack arguments start, and calls
 *
 *     extern(C) void snakebite_ffi_callback_handler(
 *         const void* entry,    -- %rdi
 *         const void* trailer,  -- %rsi
 *         CallFrame* frame,     -- %rdx
 *     );
 *
 * which runs the guest function and leaves its result in the frame's
 * result words. Those are loaded into the return registers exactly as a
 * compiled callee would leave them (ADR-0002).
 */
snakebite_ffi_callback_common:
.Lsnakebite_ffi_callback_common:
    .cfi_startproc

    pushq   %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset rbp, -16
    movq    %rsp, %rbp
    .cfi_def_cfa_register rbp

    subq    $CB_FRAME_BYTES, %rsp

    movq    %rdi, CF_INTEGER+0(%rsp)
    movq    %rsi, CF_INTEGER+8(%rsp)
    movq    %rdx, CF_INTEGER+16(%rsp)
    movq    %rcx, CF_INTEGER+24(%rsp)
    movq    %r8, CF_INTEGER+32(%rsp)
    movq    %r9, CF_INTEGER+40(%rsp)

    movsd   %xmm0, CF_SSE+0(%rsp)
    movsd   %xmm1, CF_SSE+8(%rsp)
    movsd   %xmm2, CF_SSE+16(%rsp)
    movsd   %xmm3, CF_SSE+24(%rsp)
    movsd   %xmm4, CF_SSE+32(%rsp)
    movsd   %xmm5, CF_SSE+40(%rsp)
    movsd   %xmm6, CF_SSE+48(%rsp)
    movsd   %xmm7, CF_SSE+56(%rsp)

    /* The caller's stack arguments start right above its return address:
     * `[%rbp]` is the saved `%rbp`, `[%rbp + 8]` the return address. */
    leaq    16(%rbp), %rax
    movq    %rax, CF_STACK(%rsp)

    movq    %r10, %rdi
    movq    %r11, %rsi
    movq    %rsp, %rdx
    call    snakebite_ffi_callback_handler@PLT

    movq    CF_INTEGER_RESULT+0(%rsp), %rax
    movq    CF_INTEGER_RESULT+8(%rsp), %rdx
    movsd   CF_SSE_RESULT+0(%rsp), %xmm0
    movsd   CF_SSE_RESULT+8(%rsp), %xmm1
    cmpb    $0, CF_REAL_RESULT_USED(%rsp)
    je      3f
    fldt    CF_REAL_RESULT(%rsp)
3:

    movq    %rbp, %rsp
    popq    %rbp
    .cfi_def_cfa rsp, 8
    .cfi_restore rbp

    ret

    .cfi_endproc
    .size   snakebite_ffi_callback_common, . - snakebite_ffi_callback_common

    .section .note.GNU-stack,"",@progbits
