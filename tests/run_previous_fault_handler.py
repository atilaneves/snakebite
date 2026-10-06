#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1"]
# ///

"""Check saved signal actions in a native host, without starting ut or sb."""

from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(
    sys.platform != "linux" or platform.machine() != "x86_64",
    reason="fault handlers support Linux x86-64 only",
)

HOST = r"""
#define _GNU_SOURCE
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sched.h>
#include <sys/prctl.h>
#include <unistd.h>

extern int rt_init(void);
extern int install_saved_action(void);
extern int guest_fault(void);
extern void thread_getGCSignals(int *, int *);
static _Atomic int calls;
static int mode, ready[2], wait_forever[2];
static int suspend_signal, resume_signal;
static char alternate[128 * 1024] __attribute__((aligned(16)));
static _Atomic int delay_install, published, attempting, copied;
static pthread_t installer;
static int (*native_sigaction)(int, const struct sigaction *, struct sigaction *);
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "signal counter must be lock-free");

void native_fault(void) { *(volatile int *)0 = 42; }

int sigaction(int sig, const struct sigaction *action, struct sigaction *old) {
    if (!native_sigaction)
        native_sigaction = dlsym(RTLD_NEXT, "sigaction");
    if (!native_sigaction) _exit(90);
    if (sig == SIGSEGV && action && old &&
        atomic_exchange(&delay_install, 0)) {
        struct sigaction captured = {0};
        int result = native_sigaction(sig, action, &captured);
        if (result) return result;
        // glibc can publish the new kernel action before it copies the old
        // action to its caller. Make that real window deterministic.
        atomic_store(&published, 1);
        while (!atomic_load(&attempting)) sched_yield();
        usleep(50000);
        *old = captured;
        atomic_store(&copied, 1);
        return 0;
    }
    return native_sigaction(sig, action, old);
}

static void replacement(int sig) { write(1, "replacement\n", 12); }

static void previous(int sig) {
    int call = atomic_fetch_add(&calls, 1);
    write(1, "previous\n", 9);
    if (mode == 7 && !install_saved_action()) _exit(89);
    if (mode == 6) {
        sigset_t mask;
        sigprocmask(SIG_SETMASK, 0, &mask);
        char bits[] = {'0' + sigismember(&mask, SIGUSR2),
                       '0' + sigismember(&mask, sig),
                       '0' + sigismember(&mask, SIGTERM),
                       '0' + sigismember(&mask, suspend_signal), '\n'};
        write(1, bits, sizeof bits);
    }
    if (mode == 4) {
        struct sigaction action = {0};
        action.sa_handler = replacement;
        sigemptyset(&action.sa_mask);
        if (sigaction(sig, &action, 0)) _exit(92);
    }
    if (mode == 1 && call == 0) {
        raise(sig);
        write(1, "nested returned\n", 16);
    }
    if (mode == 2 && call == 0) {
        char byte;
        write(ready[1], "r", 1);
        read(wait_forever[0], &byte, 1);
    }
}

static void previous_info(int sig, siginfo_t *info, void *context) {
    if (!info || info->si_signo != sig || !context)
        _exit(98);
    previous(sig);
}

static void *first_signal(void *arg) {
    raise(*(int *)arg);
    return 0;
}

static void *during_install(void *arg) {
    while (!atomic_load(&published)) sched_yield();
    atomic_store(&attempting, 1);
    if (mode == 8) {
        if (!install_saved_action() || !atomic_load(&copied)) _exit(87);
        write(1, "install complete\n", 17);
        return 0;
    }
    pthread_kill(installer, SIGSEGV);
    raise(SIGSEGV);
    return 0;
}

int main(int argc, char **argv) {
    prctl(PR_SET_DUMPABLE, 0);
    setenv("SNAKEBITE_NO_FAULT_HANDLER", "1", 1);
    if (!rt_init()) return 97;
    unsetenv("SNAKEBITE_NO_FAULT_HANDLER");
    thread_getGCSignals(&suspend_signal, &resume_signal);
    int sig = atoi(argv[1]);
    mode = atoi(argv[2]);
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_flags = atoi(argv[3]) ? SA_RESETHAND : 0;
    if (argc > 6 && atoi(argv[6])) action.sa_flags |= SA_NODEFER;
    if (argc > 7 && atoi(argv[7])) sigaddset(&action.sa_mask, sig);
    if (mode == 6) {
        sigset_t interrupted;
        sigemptyset(&interrupted);
        sigaddset(&interrupted, SIGTERM);
        if (sigprocmask(SIG_BLOCK, &interrupted, 0)) return 91;
        if (argc > 8 && atoi(argv[8])) sigaddset(&action.sa_mask, SIGUSR2);
    }
    if (atoi(argv[4])) {
        action.sa_flags |= SA_SIGINFO;
        action.sa_sigaction = previous_info;
    } else action.sa_handler = previous;
    if (sigaction(sig, &action, 0)) return 96;
    if (argc > 9 && atoi(argv[9])) {
        stack_t stack = {.ss_sp=alternate, .ss_size=sizeof alternate};
        if (sigaltstack(&stack, 0)) return 90;
    }
    if (mode == 5 && sigaction(SIGBUS, &action, 0)) return 96;
    if (mode == 7 || mode == 8) {
        pthread_t thread;
        installer = pthread_self();
        if (pthread_create(&thread, 0, during_install, 0)) return 94;
        atomic_store(&delay_install, 1);
        if (!install_saved_action()) return 95;
        pthread_join(thread, 0);
        return mode == 8 || atomic_load(&calls) == 2 ? 0 : 88;
    }
    if (atoi(argv[5]) && !install_saved_action()) return 95;
    if (mode == 1 && argc > 6 && atoi(argv[5]) && !guest_fault()) return 93;
    if (mode == 2) {
        pthread_t thread;
        char byte;
        if (pipe(ready) || pipe(wait_forever) ||
            pthread_create(&thread, 0, first_signal, &sig)) return 94;
        read(ready[0], &byte, 1);
        if (atoi(argv[5])) {
            if (!guest_fault()) return 93;
            write(1, "guest recovered\n", 16);
        }
        raise(sig);
        return 99;
    }
    if (mode == 3 && !guest_fault()) return 93;
    raise(sig);
    if (mode == 5) {
        raise(SIGBUS);
        raise(SIGBUS);
        return 99;
    }
    if (mode == 3) {
        if (!guest_fault()) return 93;
        write(1, "guest recovered\n", 16);
    }
    if (mode != 1 && mode != 6) raise(sig);
    return mode == 4 || mode == 6 || atomic_load(&calls) == 2 ? 0 : 99;
}
"""

BRIDGE = """
module previous_action_bridge;
import snakebite.faultsignal:
    GuestRun, HardwareFault, installFaultHandlers, takeFault;

extern(C) void native_fault();

extern(C) int install_saved_action() {
    return installFaultHandlers;
}

extern(C) int guest_fault() {
    try {
        auto run = GuestRun.begin;
        native_fault();
    } catch (HardwareFault fault) {
        takeFault(fault);
        return 1;
    }
    return 0;
}
"""


def checked(command, directory):
    result = subprocess.run(
        command, cwd=directory, capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr


PROFILES = ["dmd-debug", "dmd", "ldc2-debug", "ldc2-opt", "ldc2-full", "ldc2"]


@pytest.fixture(scope="module", params=PROFILES)
def host(request, tmp_path_factory):
    return build_host(request, tmp_path_factory, HOST)


def build_host(request, tmp_path_factory, source, bridge=None):
    compiler_name = request.param.split("-")[0]
    compiler = shutil.which(compiler_name)
    if compiler is None:
        pytest.skip(f"{request.param} is not on PATH")
    directory = tmp_path_factory.mktemp(f"previous-action-{request.param}")
    (directory / "host.c").write_text(source)
    (directory / "bridge.d").write_text(BRIDGE if bridge is None else bridge)
    checked(["cc", "-std=c11", "-pthread", "-c", "host.c", "-o", "driver.o"],
            directory)
    checked(["cc", "-c", str(ROOT / "source/snakebite/fault_trampoline_amd64.S"),
             "-o", "trampoline.o"], directory)
    checked(["cc", "-c", str(ROOT / "source/snakebite/fault_signal_abi.c"),
             "-o", "signal_abi.o"], directory)
    sources = [ROOT / "source/snakebite" / name for name in (
        "faultsignal.d", "backends/guestfault.d", "backends/haltprocess.d",
    )]
    flags = ["-O", "-release"]
    if request.param.endswith("-debug"):
        flags = ["-g", "-debug"] if compiler_name == "dmd" else ["-g", "-O0"]
    shared = ["-defaultlib=phobos2", "-debuglib=phobos2", "-L-lphobos2"]
    if compiler_name == "ldc2":
        flags += ["-gcc=clang"]
        if request.param == "ldc2":
            flags += ["-flto=thin"]
        elif request.param == "ldc2-full":
            flags += ["-flto=full"]
        shared = ["-link-defaultlib-shared"]
    checked([compiler, *flags, *shared, f"-I={ROOT / 'source'}", "bridge.d",
             *map(str, sources), "driver.o", "trampoline.o", "-L-lpthread",
             "-of=host"], directory)
    return directory / "host"


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("with_info", [False, True])
@pytest.mark.parametrize("mode", [0, 1, 2])
def test_one_shot(host, sig, with_info, mode):
    for installed in (False, True):
        result = subprocess.run(
            [str(host), str(sig.value), str(mode), "1", str(int(with_info)),
             str(int(installed))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == -sig.value, result
        expected = b"previous\n"
        if mode == 1:
            expected += b"nested returned\n"
        if mode == 2 and installed:
            expected += b"guest recovered\n"
        assert result.stdout == expected, result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("with_info", [False, True])
def test_repeated_action(host, sig, with_info):
    result = subprocess.run(
        [str(host), str(sig.value), "0", "0", str(int(with_info)), "1"],
        capture_output=True, timeout=5,
    )
    assert result.returncode == 0, result
    assert result.stdout == b"previous\nprevious\n", result


def test_guest_fault_does_not_use_saved_one_shot(host):
    result = subprocess.run(
        [str(host), str(signal.SIGSEGV.value), "3", "1", "0", "1"],
        capture_output=True, timeout=5,
    )
    assert result.returncode == -signal.SIGSEGV.value, result
    assert result.stdout == b"previous\nguest recovered\n", result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("with_info", [False, True])
def test_one_shot_can_install_a_replacement(host, sig, with_info):
    for installed in (False, True):
        result = subprocess.run(
            [str(host), str(sig.value), "4", "1", str(int(with_info)),
             str(int(installed))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result
        assert result.stdout == b"previous\nreplacement\n", result


@pytest.mark.parametrize("with_info", [False, True])
def test_one_shot_state_is_per_signal(host, with_info):
    result = subprocess.run(
        [str(host), str(signal.SIGSEGV.value), "5", "1", str(int(with_info)),
         "1"],
        capture_output=True, timeout=5,
    )
    assert result.returncode == -signal.SIGBUS.value, result
    assert result.stdout == b"previous\nprevious\n", result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("with_info", [False, True])
@pytest.mark.parametrize("block_self", [False, True])
def test_one_shot_nodefer(host, sig, with_info, block_self):
    for installed in (False, True):
        result = subprocess.run(
            [str(host), str(sig.value), "1", "1", str(int(with_info)),
             str(int(installed)), "1", str(int(block_self))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == -sig.value, result
        expected = b"previous\n"
        if block_self:
            expected += b"nested returned\n"
        assert result.stdout == expected, result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("with_info", [False, True])
@pytest.mark.parametrize("nodefer", [False, True])
@pytest.mark.parametrize("block_extra", [False, True])
@pytest.mark.parametrize("alternate", [False, True])
def test_saved_mask_on_normal_stack(host, sig, with_info, nodefer, block_extra,
                                   alternate):
    for installed in (False, True):
        result = subprocess.run(
            [str(host), str(sig.value), "6", "1", str(int(with_info)),
             str(int(installed)), str(int(nodefer)), "0", str(int(block_extra)),
             str(int(alternate))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result
        expected = f"previous\n{int(block_extra)}{int(not nodefer)}10\n"
        assert result.stdout == expected.encode(), result


@pytest.mark.parametrize("with_info", [False, True])
def test_install_publishes_the_complete_saved_action(host, with_info):
    result = subprocess.run(
        [str(host), str(signal.SIGSEGV.value), "7", "0", str(int(with_info)),
         "1"],
        capture_output=True, timeout=5,
    )
    assert result.returncode == 0, result
    assert result.stdout == b"previous\nprevious\n", result


def test_concurrent_install_returns_only_after_installation(host):
    result = subprocess.run(
        [str(host), str(signal.SIGSEGV.value), "8", "0", "0", "1"],
        capture_output=True, timeout=5,
    )
    assert result.returncode == 0, result
    assert result.stdout == b"install complete\n", result


NORMAL_HOST = r"""
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <ucontext.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <stdatomic.h>
#include <sched.h>
#include <time.h>
extern int rt_init(void);
extern int install_saved_action(void);
extern void start_collector(void);
extern void suspend_guest_entry(void);
extern void resume_guest_entry(void);
static void *alternate, *replacement;
enum { stack_size = 128 * 1024 };
static int mode, target, stack_flags;
static volatile sig_atomic_t calls, depth, failures;
static _Atomic int entered, collected;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "signal state must be lock-free");
void wait_for_handler(void) {
    while (!atomic_load(&entered)) sched_yield();
}
void finish_gc(void) { atomic_store(&collected, 1); }
static uint64_t first[4] = {1,2,3,4}, last[4] = {11,12,13,14};
static uint64_t restored[6];
extern void register_signal(long, long, long);
__asm__(".text\n"
        ".globl register_signal\n"
        "register_signal:\n"
        "push %rbx\n push %rbp\n push %r12\n push %r13\n"
        "push %r14\n push %r15\n"
        "mov $137,%rbx\n mov $439,%rbp\n mov $523,%r12\n"
        "mov $527,%r13\n mov $530,%r14\n mov $531,%r15\n"
        "mov $234,%eax\n syscall\n"
        "mov %rbx,restored(%rip)\n"
        "mov %rbp,restored+8(%rip)\n"
        "mov %r12,restored+16(%rip)\n"
        "mov %r13,restored+24(%rip)\n"
        "mov %r14,restored+32(%rip)\n"
        "mov %r15,restored+40(%rip)\n"
        "pop %r15\n pop %r14\n pop %r13\n pop %r12\n"
        "pop %rbp\n pop %rbx\n ret\n");
void native_fault(void) { *(volatile int *)0 = 42; }
static void previous(int sig, siginfo_t *info, void *opaque) {
    ucontext_t *context = opaque;
    volatile uint64_t marker = 0x123456789abcdef0UL;
    ++calls;
    if (sig != target || (info && info->si_signo != target)) ++failures;
    int on_alternate = (uintptr_t)&marker >= (uintptr_t)alternate &&
        (uintptr_t)&marker < (uintptr_t)alternate + stack_size;
    if (on_alternate != (mode == 9)) ++failures;
    if (mode == 0) {
        stack_t stack;
        if (sigaltstack(0, &stack)) _exit(90);
        // Linux disarms on every signal delivery, not only SA_ONSTACK.
        int disarmed = !!(stack_flags & 0x80000000);
        if (stack.ss_flags != (disarmed ? SS_DISABLE : 0) ||
            stack.ss_sp != (disarmed ? 0 : alternate)) ++failures;
    } else if (mode == 1 || mode == 9) {
        sigaddset(&context->uc_sigmask, SIGUSR2);
        context->uc_mcontext.fpregs->mxcsr =
            (context->uc_mcontext.fpregs->mxcsr & ~0x6000u) | 0x4000u;
    } else if (mode == 2 && depth < 24) {
        ++depth;
        raise(sig);
        --depth;
    } else if (mode == 3 || mode == 11) {
        context->uc_mcontext.gregs[REG_RIP] = context->uc_mcontext.gregs[REG_R12];
        context->uc_mcontext.gregs[REG_RAX] = 137;
    } else if (mode == 4) {
        stack_t next = {.ss_sp=replacement, .ss_size=stack_size,
                        .ss_flags=stack_flags};
        if (sigaltstack(&next, 0)) _exit(91);
        context->uc_stack = next;
        if (munmap(alternate, stack_size)) _exit(92);
    } else if (mode == 5) {
        unsigned char *fp = (void *)context->uc_mcontext.fpregs;
        uint64_t *xmm0 = (void *)(fp + 160);
        uint64_t *ymm0 = (void *)(fp + 576);
        uint64_t *ymm15 = (void *)(fp + 576 + 15 * 16);
        if (xmm0[0] != 1 || xmm0[1] != 2 || ymm0[0] != 3 ||
            ymm0[1] != 4 || ymm15[0] != 13 || ymm15[1] != 14) ++failures;
        ymm0[0] = 137;
        ymm15[1] = 439;
    } else if (mode == 7) {
        atomic_store(&entered, 1);
        struct timespec now, end;
        clock_gettime(CLOCK_MONOTONIC, &end);
        ++end.tv_sec;
        do {
            if (atomic_load(&collected)) break;
            sched_yield();
            clock_gettime(CLOCK_MONOTONIC, &now);
        } while (now.tv_sec < end.tv_sec ||
                 (now.tv_sec == end.tv_sec && now.tv_nsec < end.tv_nsec));
        if (!atomic_load(&collected)) ++failures;
    } else if (mode == 8) {
        const uint64_t expected[6] = {137,439,523,527,530,531};
        const int registers[6] = {REG_RBX,REG_RBP,REG_R12,REG_R13,REG_R14,REG_R15};
        for (int i=0; i<6; ++i) {
            if (context->uc_mcontext.gregs[registers[i]] != expected[i]) ++failures;
            context->uc_mcontext.gregs[registers[i]] = expected[i] + 1;
        }
    }
    if (marker != 0x123456789abcdef0UL) ++failures;
}
static void simple(int sig) { previous(sig, 0, 0); }
__attribute__((target("avx"))) static int vector_signal(void) {
    long pid=getpid(), tid=syscall(SYS_gettid), result=SYS_tgkill;
    uint64_t out_first[4], out_last[4];
    __asm__ volatile("vmovdqu (%[first]),%%ymm0\n\t"
                     "vmovdqu (%[last]),%%ymm15\n\t"
                     "syscall\n\t"
                     "vmovdqu %%ymm0,(%[out_first])\n\t"
                     "vmovdqu %%ymm15,(%[out_last])\n\t"
                     : "+a"(result)
                     : "D"(pid), "S"(tid), "d"((long)target),
                       [first]"r"(first), [last]"r"(last),
                       [out_first]"r"(out_first), [out_last]"r"(out_last)
                     : "rcx", "r11", "ymm0", "ymm15", "memory");
    return out_first[0] != 1 || out_first[1] != 2 || out_first[2] != 137 ||
           out_first[3] != 4 || out_last[0] != 11 || out_last[1] != 12 ||
           out_last[2] != 13 || out_last[3] != 439;
}
static long host_fault_result(int sig) {
    long result;
    if (sig == SIGFPE) {
        __asm__ volatile("lea 1f(%%rip),%%r12\n\t"
                         "mov $1,%%eax\n\t"
                         "xor %%edx,%%edx\n\t"
                         "xor %%ecx,%%ecx\n\t"
                         "idiv %%ecx\n\t1:"
                         : "=a"(result) : : "rcx", "rdx", "r12", "memory");
    } else if (sig == SIGBUS) {
        long page = sysconf(_SC_PAGESIZE);
        int fd = memfd_create("host-fault", 0);
        if (fd < 0 || ftruncate(fd, page)) _exit(89);
        void *mapping = mmap(0, page, PROT_READ, MAP_SHARED, fd, 0);
        if (mapping == MAP_FAILED || ftruncate(fd, 0)) _exit(88);
        __asm__ volatile("lea 1f(%%rip),%%r12\n\t"
                         "mov (%[mapping]),%%rax\n\t1:"
                         : "=a"(result) : [mapping]"r"(mapping) : "r12", "memory");
        if (munmap(mapping, page) || close(fd)) _exit(87);
    } else {
        __asm__ volatile("lea 1f(%%rip),%%r12\n\t"
                         "xor %%eax,%%eax\n\t"
                         "mov (%%rax),%%rax\n\t1:"
                         : "=a"(result) : : "r12", "memory");
    }
    return result;
}
int main(int argc, char **argv) {
    prctl(PR_SET_DUMPABLE, 0);
    setenv("SNAKEBITE_NO_FAULT_HANDLER", "1", 1);
    if (!rt_init()) return 97;
    unsetenv("SNAKEBITE_NO_FAULT_HANDLER");
    target=atoi(argv[1]); mode=atoi(argv[2]);
    if (mode == 5 && !__builtin_cpu_supports("avx")) return 77;
    alternate=mmap(0, stack_size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    replacement=mmap(0, stack_size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (alternate == MAP_FAILED || replacement == MAP_FAILED) return 96;
    stack_flags = argc > 5 ? (int)strtoul(argv[5], 0, 0) : 0;
    stack_t stack = {.ss_sp=alternate, .ss_size=stack_size,
                     .ss_flags=stack_flags};
    if (sigaltstack(&stack, 0)) return 95;
    struct sigaction action = {0};
    int information=atoi(argv[3]);
    if (information) action.sa_sigaction=previous;
    else action.sa_handler=simple;
    action.sa_flags=(information ? SA_SIGINFO : 0) |
                    (mode == 2 ? SA_NODEFER : 0) |
                    (mode == 9 ? SA_ONSTACK : 0);
    sigemptyset(&action.sa_mask);
    if (mode == 9) sigfillset(&action.sa_mask);
    if (sigaction(target, &action, 0)) return 94;
    if (atoi(argv[4]) && !install_saved_action()) return 93;
    if (mode == 7) start_collector();
    if (mode == 11) {
        suspend_guest_entry();
        if (host_fault_result(target) != 137) ++failures;
        resume_guest_entry();
    } else if (mode == 3) {
        long value;
        __asm__ volatile("lea 1f(%%rip),%%r12\n\t"
                         "xor %%eax,%%eax\n\t"
                         "mov (%%rax),%%rax\n\t1:"
                         : "=a"(value) : : "r12", "memory");
        if (value != 137) ++failures;
    } else if (mode == 6) {
        // Kernel signal-frame placement must fail on this exhausted normal
        // stack. The wrapper must fail with the same signal, not recurse.
        long pid=getpid(), tid=syscall(SYS_gettid), result=SYS_tgkill;
        long page=sysconf(_SC_PAGESIZE);
        char *guard=mmap(0, 2 * page, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (guard == MAP_FAILED || mprotect(guard, page, PROT_NONE)) return 91;
        void *sp=guard + page + 256;
        __asm__ volatile("mov %%rsp,%%r12\n\t"
                         "mov %[sp],%%rsp\n\t"
                         "syscall\n\t"
                         "mov %%r12,%%rsp"
                         : "+a"(result)
                         : "D"(pid), "S"(tid), "d"((long)target), [sp]"r"(sp)
                         : "rcx", "r11", "r12", "memory");
        return 90;
    } else if (mode == 5) failures += vector_signal();
    else if (mode == 8) {
        register_signal(getpid(), syscall(SYS_gettid), target);
        const uint64_t expected[6] = {138,440,524,528,531,532};
        for (int i=0; i<6; ++i) if (restored[i] != expected[i]) ++failures;
    }
    else raise(target);
    if (mode == 7) while (!atomic_load(&collected)) sched_yield();
    if (mode == 1 || mode == 9) {
        sigset_t mask;
        unsigned mxcsr;
        sigprocmask(SIG_SETMASK, 0, &mask);
        __asm__ volatile("stmxcsr %0" : "=m"(mxcsr));
        if (!sigismember(&mask, SIGUSR2) || (mxcsr & 0x6000) != 0x4000)
            ++failures;
    }
    if (sigaltstack(0, &stack)) return 92;
    if (stack.ss_flags != stack_flags || stack.ss_size != stack_size ||
        stack.ss_sp != (mode == 4 ? replacement : alternate)) ++failures;
    if (calls != (mode == 2 ? 25 : 1)) ++failures;
    return failures ? 99 : 0;
}
"""


NORMAL_BRIDGE = BRIDGE + r"""
import core.thread: Thread;
import core.thread.fiber: Fiber;
import core.memory: GC;
import snakebite.faultsignal: runGuest;
private Fiber _suspended;
extern(C) void suspend_guest_entry() {
    _suspended = new Fiber({ runGuest({ Fiber.yield; }); });
    _suspended.call;
}
extern(C) void resume_guest_entry() {
    _suspended.call;
    assert(_suspended.state == Fiber.State.TERM);
    _suspended = null;
}
extern(C) void wait_for_handler();
extern(C) void finish_gc();
extern(C) void start_collector() {
    (new Thread({ wait_for_handler(); GC.collect(); finish_gc(); })).start();
}
"""


@pytest.fixture(scope="module", params=PROFILES)
def normal_host(request, tmp_path_factory):
    return build_host(request, tmp_path_factory, NORMAL_HOST, NORMAL_BRIDGE)


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("mode", [0, 1, 2, 4, 5])
@pytest.mark.parametrize("autodisarm", [False, True])
def test_normal_stack_callback_and_context(normal_host, sig, mode, autodisarm):
    for installed in (False, True):
        signatures = (False, True) if mode in (0, 2) else (True,)
        for information in signatures:
            result = subprocess.run(
                [str(normal_host), str(sig.value), str(mode),
                 str(int(information)), str(int(installed)),
                 str(0x80000000 if autodisarm else 0)],
                capture_output=True, timeout=5,
            )
            if mode == 5 and result.returncode == 77:
                pytest.skip("AVX state is not available")
            assert result.returncode == 0, result


def test_normal_stack_callback_can_edit_fault_pc_and_result(normal_host):
    for installed in (False, True):
        result = subprocess.run(
            [str(normal_host), str(signal.SIGSEGV.value), "3", "1",
             str(int(installed))], capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
def test_suspended_guest_fiber_does_not_own_host_fault(normal_host, sig):
    for installed in (False, True):
        result = subprocess.run(
            [str(normal_host), str(sig.value), "11", "1", str(int(installed))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
def test_failed_normal_stack_delivery_has_the_native_signal(normal_host, sig):
    for installed in (False, True):
        result = subprocess.run(
            [str(normal_host), str(sig.value), "6", "1", str(int(installed))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == -signal.SIGSEGV.value, result


def test_collection_can_finish_inside_the_normal_stack_callback(normal_host):
    for installed in (False, True):
        result = subprocess.run(
            [str(normal_host), str(signal.SIGSEGV.value), "7", "1",
             str(int(installed))], capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
def test_callback_context_edits_restore_callee_saved_registers(normal_host, sig):
    for installed in (False, True):
        result = subprocess.run(
            [str(normal_host), str(sig.value), "8", "1", str(int(installed))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("autodisarm", [False, True])
def test_onstack_callback_context_and_mask_edits(normal_host, sig, autodisarm):
    for installed in (False, True):
        result = subprocess.run(
            [str(normal_host), str(sig.value), "9", "1", str(int(installed)),
             str(0x80000000 if autodisarm else 0)],
            capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result


PLACEMENT_HOST = r"""
#define _GNU_SOURCE
#include <signal.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <stddef.h>
#include <errno.h>
extern int rt_init(void);
extern int install_saved_action(void);
void native_fault(void) { *(volatile int *)0 = 42; }
static char alternate[128 * 1024] __attribute__((aligned(64)));
static volatile sig_atomic_t calls;
static void previous(int sig) { ++calls; write(1, "callback\n", 9); }
int main(int argc, char **argv) {
    prctl(PR_SET_DUMPABLE, 0);
    setenv("SNAKEBITE_NO_FAULT_HANDLER", "1", 1);
    if (!rt_init()) return 97;
    unsetenv("SNAKEBITE_NO_FAULT_HANDLER");
    int target=atoi(argv[3]);
    struct sigaction action={0};
    action.sa_handler=previous;
    if (sigaction(target, &action, 0)) return 96;
    int mode=atoi(argv[2]);
    stack_t alt={.ss_sp=alternate, .ss_size=sizeof alternate};
    char *shared=0;
    if (mode == 3) {
        shared=mmap(0, sizeof alternate + 4096, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (shared == MAP_FAILED) return 93;
        alt.ss_sp=shared;
    }
    if (sigaltstack(&alt, 0)) return 95;
    if (atoi(argv[1]) && !install_saved_action()) return 94;
    if (mode == 1 || mode == 3 || mode == 4) {
        size_t extent=2 * 1024 * 1024, page=sysconf(_SC_PAGESIZE);
        char *reserve=mmap(0, extent, PROT_NONE,
                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (reserve == MAP_FAILED || munmap(reserve, extent)) return 93;
        void *sp;
        if (mode == 3) {
            // The two stack ranges share one mapping. The original kernel
            // frame and the destination overlap when the normal RSP is just
            // above the configured alternate range. This requires memmove.
            sp=shared + sizeof alternate + 512;
        } else {
            char *stack=mmap(reserve + extent - page, page,
                             mode == 4 ? PROT_READ : PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE |
                             (mode == 1 ? MAP_GROWSDOWN : 0), -1, 0);
            if (stack == MAP_FAILED) return 92;
            sp=stack + 512;
        }
        long pid=getpid(), tid=syscall(SYS_gettid), result=SYS_tgkill;
        __asm__ volatile("mov %%rsp,%%r12\n\t"
                         "mov %[sp],%%rsp\n\t"
                         "syscall\n\t"
                         "mov %%r12,%%rsp"
                         : "+a"(result)
                         : "D"(pid), "S"(tid), "d"((long)target), [sp]"r"(sp)
                         : "rcx", "r11", "r12", "memory");
    } else {
        if (mode == 2) {
            struct sock_filter filter[]={
                BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, nr)),
                BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_process_vm_writev, 0, 1),
                BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
                BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)};
            struct sock_fprog program={.len=4, .filter=filter};
            if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
                prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) return 91;
        }
        raise(target);
    }
    return calls == 1 ? 0 : 90;
}
"""


@pytest.fixture(scope="module", params=PROFILES)
def placement_host(request, tmp_path_factory):
    return build_host(request, tmp_path_factory, PLACEMENT_HOST)


@pytest.mark.parametrize("sig", [signal.SIGSEGV, signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("mode", [0, 1, 2, 3, 4])
def test_native_normal_stack_placement(placement_host, sig, mode):
    for installed in (False, True):
        result = subprocess.run(
            [str(placement_host), str(int(installed)), str(mode), str(sig.value)],
            capture_output=True, timeout=5,
        )
        if mode == 4:
            assert result.returncode == -signal.SIGSEGV.value, result
            assert result.stdout == b"", result
        else:
            assert result.returncode == 0, result
            assert result.stdout == b"callback\n", result
