/* Native stack switch for the interpreter's own host-to-guest entry.
 *
 * A host-to-guest entry (`Evaluator.runHostToGuest`, walker.d) can be
 * reached on any native stack a host caller happens to be running on -
 * including a guest-created `core.thread.Fiber`'s own stack, which can
 * be as small as druntime's default (16 KB on Linux x86-64). The
 * interpreter's own recursive tree walk costs far more native stack per
 * nested guest call than compiled D would (issue: `bin/sb -b interpreter
 * dlib` segfault, root-caused to fiber-stack exhaustion by nested
 * `executeCall`/`executeRaw` recursion). `runHostToGuest` therefore runs
 * its whole body on a dedicated, adequately sized stack
 * (`snakebite.backends.interpreter.nativestack.InterpreterStack`) instead
 * of whatever stack it was entered on.
 *
 * `snakebite_interpreter_call_on_stack` is the primitive that makes one
 * nested call run with a different `%rsp`. It anchors this frame's CFA to
 * `%rbp`, exactly like `snakebite_ffi_callback_common`
 * (source/snakebite/ffi/sysv_amd64.S) does, and never moves `%rbp` itself
 * after that: `%rbp` stays pointing at this frame, on the *caller's* own
 * stack, for the whole call, even while `%rsp` points into the dedicated
 * stack underneath `fn`. A DWARF unwinder - the one a D `Throwable`
 * already uses to cross `snakebite_ffi_callback_common` (ADR-0004) -
 * therefore recovers the caller's `%rsp`, `%rbp` and `%rbx` correctly no
 * matter which stack the fault happened on: this frame's CFA is always
 * `%rbp + 16`, on the caller's stack, so unwinding through it lands back
 * on the caller's stack exactly as it would without the switch.
 *
 * This is a general "run this call with a different stack" primitive, not
 * a Fiber implementation: it has no notion of yield/resume, and never
 * saves a context to be resumed later. A real `Fiber.yield()` called from
 * inside `fn` is unaffected: it swaps `%rsp` on its own, via druntime's
 * own (unmodified, real, compiled) `Fiber` machinery, to and from
 * whatever called `Fiber.call()` - this routine is not on that path
 * either way, so it does not need to know it happened. `%rsp` is simply
 * wherever `Fiber.yield()`/`.call()` last left it when `fn` eventually
 * runs to completion (or throws) and control returns here.
 */

#if !(defined(__x86_64__) && defined(__linux__))
#error "snakebite_interpreter_call_on_stack is implemented for Linux x86-64 only"
#endif

    .text
    .globl  snakebite_interpreter_call_on_stack
    .type   snakebite_interpreter_call_on_stack, @function
    .align  16

/* extern(C) void snakebite_interpreter_call_on_stack(
 *     void* newStackTop,             -- %rdi
 *     void function(void*) fn,       -- %rsi
 *     void* arg,                     -- %rdx
 * );
 *
 * Calls `fn(arg)` with `%rsp` set to `newStackTop` (already 16-byte
 * aligned by the caller - `InterpreterStack.top`, nativestack.d) for the
 * duration of that one call, then restores `%rsp` and returns normally.
 * `%rbx` holds the caller's own `%rsp` across the call: it is
 * callee-saved, so `fn` (an ordinary SysV-ABI function) leaves it
 * untouched, exactly like `%rbx`/`%r12` already carry `address`/`frame`
 * across the indirect call in `snakebite_ffi_call_sysv_amd64`
 * (sysv_amd64.S).
 */
snakebite_interpreter_call_on_stack:
    .cfi_startproc

    pushq   %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset rbp, -16
    movq    %rsp, %rbp
    .cfi_def_cfa_register rbp

    pushq   %rbx
    .cfi_offset rbx, -24
    movq    %rsp, %rbx

    movq    %rdi, %rsp
    movq    %rdx, %rdi
    call    *%rsi

    movq    %rbx, %rsp
    popq    %rbx
    .cfi_restore rbx

    popq    %rbp
    .cfi_def_cfa rsp, 8
    .cfi_restore rbp

    ret

    .cfi_endproc
    .size   snakebite_interpreter_call_on_stack, . - snakebite_interpreter_call_on_stack

    .section .note.GNU-stack,"",@progbits
