"""Strict native-equivalence diagnostics for unresolved failed delivery.

Run explicitly with pytest. These requirements are not part of the bounded
SIGSEGV repair, and their failures must remain visible until implemented.
"""

import signal
import subprocess

import pytest

from run_previous_fault_handler import (
    ABSENT_RESTORER_HOST, PROFILES, absent_restorer_host, build_host, pytestmark,
)


SUSPEND_HOST = ABSENT_RESTORER_HOST.replace(
    "#include <sys/prctl.h>", "#include <sys/prctl.h>\n#include <ucontext.h>",
).replace(
    'static void failure(int sig) { write(1, "failure\\n", 8); }', r"""
static volatile sig_atomic_t failures;
static void failure(int sig, siginfo_t *info, void *opaque) {
    if (sig != SIGSEGV || info->si_code != SI_KERNEL || info->si_addr || !opaque)
        _exit(99);
    if (!sigismember(&((ucontext_t *)opaque)->uc_sigmask, SIGSEGV)) _exit(98);
    ++failures;
    sigaddset(&((ucontext_t *)opaque)->uc_sigmask, SIGTERM);
    write(1, "failure\n", 8);
}
""",
).replace(
    'static void replacement_failure(int sig) { write(1, "replacement\\n", 12); }',
    r"""
static void replacement_failure(int sig, siginfo_t *info, void *opaque) {
    failure(sig, info, opaque);
    write(1, "replacement\n", 12);
}
""",
).replace(
    ".sa_handler=failure", ".sa_sigaction=failure, .sa_flags=SA_SIGINFO",
).replace(
    ".sa_handler=replacement_failure",
    ".sa_sigaction=replacement_failure, .sa_flags=SA_SIGINFO",
).replace(
    """        sigset_t blocked;
        sigemptyset(&blocked);
        sigaddset(&blocked, SIGSEGV);
        if (sigprocmask(SIG_BLOCK, &blocked, 0)) return 96;
""", "",
).replace(
    "    if (atoi(argv[6])) {", """
    sigset_t permanent, temporary;
    sigemptyset(&permanent);
    sigaddset(&permanent, sig);
    sigaddset(&permanent, SIGSEGV);
    if (sigprocmask(SIG_SETMASK, &permanent, 0)) return 96;
    sigemptyset(&temporary);
    if (atoi(argv[6])) {""",
).replace(
    "    return 97;", """
    sigsuspend(&temporary);
    return failures == 1 ? 0 : 97;""",
)


@pytest.mark.parametrize("sig", [signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("alternate", [False, True])
@pytest.mark.parametrize("onstack", [False, True])
@pytest.mark.parametrize("information", [False, True])
@pytest.mark.parametrize("pointer", [False, True])
@pytest.mark.parametrize("restricted", [False, True])
@pytest.mark.parametrize("replacement", [False, True])
def test_absent_restorer_blocked_failure(absent_restorer_host, sig, alternate,
                                        onstack, information, pointer,
                                        restricted, replacement):
    for installed in (False, True):
        result = subprocess.run(
            [str(absent_restorer_host), str(int(installed)), str(int(alternate)),
             str(int(onstack)), str(int(information)), str(int(pointer)),
             str(int(restricted)), str(sig.value), str(int(replacement))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == -signal.SIGSEGV, result
        assert result.stdout == b"", result


@pytest.fixture(scope="module", params=PROFILES)
def suspend_host(request, tmp_path_factory):
    return build_host(request, tmp_path_factory, SUSPEND_HOST)


@pytest.mark.parametrize("sig", [signal.SIGFPE, signal.SIGBUS])
@pytest.mark.parametrize("stack", [(False, False), (True, False), (True, True)])
@pytest.mark.parametrize("restricted", [False, True])
@pytest.mark.parametrize("replacement", [False, True])
def test_sigsuspend_missing_restorer_recovers(suspend_host, sig, stack,
                                             restricted, replacement):
    for installed in (False, True):
        result = subprocess.run(
            [str(suspend_host), str(int(installed)), *map(lambda x: str(int(x)), stack),
             "1", "0", str(int(restricted)), str(sig.value), str(int(replacement))],
            capture_output=True, timeout=5,
        )
        assert result.returncode == 0, result
        expected = b"failure\nreplacement\n" if replacement else b"failure\n"
        assert result.stdout == expected, result
