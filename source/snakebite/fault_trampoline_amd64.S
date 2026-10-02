/* Where a thread continues after a hardware fault.
 *
 * The signal handler of `snakebite.faultsignal` only records the fault and
 * changes the saved context so that the thread resumes here, on its own
 * stack and outside signal context, where it can throw. This is the
 * technique of druntime's `etc.linux.memoryerror`.
 *
 * `snakebite_fault_trampoline` is entered with the address of the faulting
 * instruction pushed as its return address. That address is the exact
 * instruction, not the one after a call, so the frame is marked as a
 * signal frame: the unwinder does not subtract 1 from it, and druntime's
 * personality routine reads the call site table at the faulting
 * instruction. `snakebite_fault_trampoline_call` is for a call through a
 * bad function pointer: the `call` pushed a normal return address.
 *
 * Neither returns: `snakebite_fault_raise` throws.
 */

#if defined(__x86_64__) && defined(__linux__)

    .text

    .globl  snakebite_fault_trampoline
    .type   snakebite_fault_trampoline, @function
    .align  16
snakebite_fault_trampoline:
    .cfi_startproc
    .cfi_signal_frame
    pushq   %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq    %rsp, %rbp
    .cfi_def_cfa_register %rbp
    andq    $-16, %rsp
    cld
    call    snakebite_fault_raise@PLT
    ud2
    .cfi_endproc
    .size   snakebite_fault_trampoline, . - snakebite_fault_trampoline

    .globl  snakebite_fault_trampoline_call
    .type   snakebite_fault_trampoline_call, @function
    .align  16
snakebite_fault_trampoline_call:
    .cfi_startproc
    pushq   %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq    %rsp, %rbp
    .cfi_def_cfa_register %rbp
    andq    $-16, %rsp
    cld
    call    snakebite_fault_raise@PLT
    ud2
    .cfi_endproc
    .size   snakebite_fault_trampoline_call, . - snakebite_fault_trampoline_call

#endif

    .section .note.GNU-stack,"",@progbits
