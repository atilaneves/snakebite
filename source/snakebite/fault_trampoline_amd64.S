/* Where a thread continues after a hardware fault.
 *
 * The signal handler of `snakebite.faultsignal` only records the fault and
 * changes the saved context so that the thread resumes here, on its own
 * stack and outside signal context, where it can throw. This is the
 * technique of druntime's `etc.linux.memoryerror`.
 *
 * A fault can interrupt code with a stack alignment that a normal D
 * function entry does not accept. Assembly lets us align the stack and
 * describe the interrupted frame with explicit call frame information.
 * Inline assembly cannot supply these unwind directives (ADR-0004).
 *
 * `snakebite_fault_trampoline` is entered with the address of the faulting
 * instruction pushed as its return address. That address is the exact
 * instruction, not the one after a call, so the frame is marked as a
 * signal frame: the unwinder does not subtract 1 from it. This preserves
 * the faulting PC for any call-site table the compiler kept; it cannot
 * create catch or cleanup entries for loads, stores or divisions.
 * `snakebite_fault_trampoline_call` is for a call through a
 * bad function pointer: the `call` pushed a normal return address.
 *
 * Neither returns: `snakebite_fault_raise` throws.
 */

#if defined(__x86_64__) && defined(__linux__)

#define __ASSEMBLY__ 1
#include <asm/signal.h>
#include <asm/unistd.h>

    .text

    /* The saved action may have work to do before rt_sigreturn. Consume its
     * callback and restorer before unmasking permits nested delivery.
     */
    .macro prepare_saved_action
    testl $SA_RESTORER,136(%r12)
    jz .Lsignal_no_restorer\@
    mov 144(%r12),%rax
    mov %rax,(%rsp)
.Lsignal_action_ready\@:
    mov (%r12),%r12
    .pushsection .text.unlikely,"ax",@progbits
.Lsignal_no_restorer\@:
    cmpl $SIGSEGV,%r15d
    je .Lsignal_fatal_delivery\@
    testq $(1 << (SIGSEGV - 1)),296(%r14)
    jz .Lsignal_action_ready\@
.Lsignal_fatal_delivery\@:
    /* Failed delivery is fatal for SIGSEGV itself, or when the interrupted
     * mask blocks the forced SIGSEGV. Even a current callable disposition
     * cannot override the latter kernel rule. A forced fault while SIGSEGV
     * is still blocked gives the kernel that default-fatal path without
     * another disposition or mask syscall. This address is noncanonical
     * with both four- and five-level paging.
     */
    movabs $0x8000000000000000,%rax
    mov (%rax),%rax
    ud2
    .popsection
    .endm

    /* The compiler must not infer nounwind from the guest body, even with
     * LTO. A tail jump keeps the entry's real call site on the stack without
     * adding an unwind frame or a check to a guest instruction.
     * SysV arguments: context in rdi, body in rsi.
     */
    .globl  snakebite_fault_invoke
    .type   snakebite_fault_invoke, @function
    .align  16
snakebite_fault_invoke:
    .cfi_startproc
    jmp     *%rsi
    .cfi_endproc
    .size   snakebite_fault_invoke, . - snakebite_fault_invoke

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

    /* Every saved callback uses this tail entry. Only a stack change needs
     * placement of the kernel frame. Tail entry keeps the
     * saved restorer as the callback's return address; rt_sigreturn consumes
     * frame only once, including any callback context edits.
     */
    .globl snakebite_fault_signal_entry
    .type snakebite_fault_signal_entry,@function
snakebite_fault_signal_entry:
    .cfi_startproc
    mov %rsp,%rcx
    push %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp,-16
    mov %rsp,%rbp
    .cfi_def_cfa_register %rbp
    mov %rsi,%r13
    mov %rdx,%r14
    mov %edi,%r15d
    cld
    call snakebite_fault_dispatch@PLT
    leave
    .cfi_def_cfa %rsp,8
    .cfi_restore %rbp
    test %rax,%rax
    jz .Lsignal_return
    mov %rax,%rbx
    mov 0(%rax),%r10
    mov 8(%rax),%r12
    mov 176(%rax),%rcx
    mov %r10,%rsp
    test %rcx,%rcx
    jz .Lsignal_unmoved
    mov 16(%rax),%r13
    mov 24(%rax),%r14
    mov 168(%rax),%rsi
    mov %r10,%rdi
    /* Use the normal stack before the first write. A legitimate growing
     * stack gets ordinary user page faults, without a remote-write syscall
     * or permission. All signals remain blocked through placement. A write
     * to an inaccessible stack therefore terminates on its forced hardware
     * fault rather than recursively entering our signal handler.
     * The configured alternate range may share a mapping with this stack,
     * so the two frames can overlap: use memmove order, not memcpy order.
     */
    cmp %rsi,%rdi
    jbe .Lsignal_copy_forward
    mov %rdi,%rax
    sub %rsi,%rax
    cmp %rcx,%rax
    jae .Lsignal_copy_forward
    lea -1(%rsi,%rcx),%rsi
    lea -1(%rdi,%rcx),%rdi
    std
    rep movsb
    cld
    jmp .Lsignal_copy_done
.Lsignal_copy_forward:
    rep movsb
.Lsignal_copy_done:
    mov 184(%rbx),%rax
    mov %rax,224(%r14)
    prepare_saved_action
.Lsignal_unmask:
    lea 40(%rbx),%rsi
    mov $SIG_SETMASK,%edi
    xor %edx,%edx
    mov $8,%r10d
    mov $__NR_rt_sigprocmask,%eax
    syscall
    test %rax,%rax
    jnz .Lsignal_failure
.Lsignal_callback:
    mov %r15d,%edi
    mov %r13,%rsi
    mov %r14,%rdx
    xor %eax,%eax
    jmp *%r12
.Lsignal_unmoved:
    prepare_saved_action
    cmpb $0,32(%rbx)
    je .Lsignal_callback
    jmp .Lsignal_unmask
.Lsignal_return:
    ret
.Lsignal_failure:
    /* Unmasking failed: do not run the callback under the wrong mask. */
    mov $(128 + SIGSEGV),%edi
    mov $__NR_exit_group,%eax
    syscall
    ud2
    .cfi_endproc
    .size snakebite_fault_signal_entry,.-snakebite_fault_signal_entry

    .section .note.GNU-stack,"",@progbits

#endif
