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


@pytest.fixture(scope="module", params=["dmd", "ldc2"])
def host(request, tmp_path_factory):
    compiler = shutil.which(request.param)
    if compiler is None:
        pytest.skip(f"{request.param} is not on PATH")
    directory = tmp_path_factory.mktemp(f"previous-action-{request.param}")
    (directory / "host.c").write_text(HOST)
    (directory / "bridge.d").write_text(BRIDGE)
    checked(["cc", "-std=c11", "-pthread", "-c", "host.c", "-o", "driver.o"],
            directory)
    checked(["cc", "-c", str(ROOT / "source/snakebite/fault_trampoline_amd64.S"),
             "-o", "trampoline.o"], directory)
    sources = [ROOT / "source/snakebite" / name for name in (
        "faultsignal.d", "backends/guestfault.d", "backends/haltprocess.d",
    )]
    flags = ["-O", "-release"]
    shared = ["-defaultlib=phobos2", "-debuglib=phobos2", "-L-lphobos2"]
    if request.param == "ldc2":
        flags += ["-flto=thin", "-gcc=clang"]
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
def test_saved_mask_on_normal_stack(host, sig, with_info, nodefer, block_extra):
    for installed in (False, True):
        result = subprocess.run(
            [str(host), str(sig.value), "6", "1", str(int(with_info)),
             str(int(installed)), str(int(nodefer)), "0", str(int(block_extra))],
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
