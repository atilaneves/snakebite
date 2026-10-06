/* Fail the build if the Linux UAPI no longer matches the frame offsets
 * used by faultsignal.d and fault_trampoline_amd64.S.
 */
#if defined(__x86_64__) && defined(__linux__)
#include <stddef.h>
#include <asm/signal.h>
#include <asm/sigcontext.h>
#include <asm/ucontext.h>

_Static_assert(sizeof(sigset_t) == 8, "kernel signal mask size");
_Static_assert(SA_RESTORER == 0x04000000, "signal restorer flag");
_Static_assert(offsetof(struct ucontext, uc_mcontext) == 40, "machine context offset");
_Static_assert(offsetof(struct ucontext, uc_sigmask) == 296, "signal mask offset");
_Static_assert(offsetof(struct sigcontext, fpstate) == 184, "FP pointer offset");
_Static_assert(sizeof(struct _fpstate_64) == 512, "legacy FP image size");
_Static_assert(offsetof(struct _fpstate_64, sw_reserved) == 464, "XSAVE header offset");
_Static_assert(offsetof(struct _fpx_sw_bytes, magic1) == 0, "XSAVE magic offset");
_Static_assert(offsetof(struct _fpx_sw_bytes, extended_size) == 4, "XSAVE length offset");
_Static_assert(FP_XSTATE_MAGIC1 == 0x46505853U, "XSAVE magic value");
#endif
