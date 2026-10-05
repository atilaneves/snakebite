"""Test real fault-handler processes without starting ut or sb."""

import os
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
MODES = [
    ("dmd-debug", "dmd", ["-g", "-debug"]),
    ("dmd-opt", "dmd", ["-release", "-O", "-inline"]),
    ("ldc-debug", "ldc2", ["-g", "-d-debug"]),
    ("ldc-opt", "ldc2", ["-release", "-O"]),
    ("ldc-thin", "ldc2", ["-release", "-O", "-flto=thin", "-gcc=clang"]),
    ("ldc-full", "ldc2", ["-release", "-O", "-flto=full", "-gcc=clang"]),
]


def checked(command, directory):
    result = subprocess.run(
        command, cwd=directory, capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.fixture(scope="module", params=MODES, ids=lambda mode: mode[0])
def binaries(request, tmp_path_factory):
    name, compiler_name, flags = request.param
    compiler = shutil.which(compiler_name)
    if compiler is None:
        pytest.skip(f"{compiler_name} is not on PATH")
    directory = tmp_path_factory.mktemp(name)
    checked(["cc", "-c", str(ROOT / "source/snakebite/fault_trampoline_amd64.S"),
             "-o", "trampoline.o"], directory)
    shared = ["-defaultlib=libphobos2.so"] if compiler_name == "dmd" else [
        "-link-defaultlib-shared",
    ]
    sources = [ROOT / "source/snakebite" / source for source in (
        "faultsignal.d", "backends/guestfault.d", "backends/haltprocess.d",
    )]
    result = {}
    for fixture in ("fault_process", "fault_boundary", "fault_stackoverflow"):
        source = directory / f"{fixture}.d"
        source.write_text((ROOT / "tests/native" / f"{fixture}.d.in").read_text())
        checked([compiler, *flags, *shared, "-preview=dip1000",
                 f"-I={ROOT / 'source'}", str(source), *map(str, sources),
                 "trampoline.o", f"-of={fixture}"], directory)
        result[fixture] = directory / fixture
    return result


SCENARIOS = [
    ("hostNullRead", -signal.SIGSEGV),
    ("hostDivision", -signal.SIGFPE),
    ("hostFaultOnAnotherThread", -signal.SIGSEGV),
    ("hostFaultAfterGuestRun", -signal.SIGSEGV),
    ("sentSignalInGuestRun", -signal.SIGSEGV),
    ("faultInCleanup", -signal.SIGSEGV),
    ("sentSignalWhileIgnored", 77),
    ("faultOnAThreadOfTheGuestAfterCollections", 77),
    ("previousHandler", 43),
    ("guestFaultWithTheHandlersOff", -signal.SIGSEGV),
    ("guestHandler", 42),
    ("halt", -signal.SIGILL),
]


def clean_environment():
    environment = os.environ.copy()
    environment.pop("SNAKEBITE_NO_FAULT_HANDLER", None)
    return environment


@pytest.mark.parametrize("scenario,expected", SCENARIOS)
def test_process_action(binaries, tmp_path, scenario, expected):
    environment = clean_environment()
    if scenario in ("previousHandler", "sentSignalWhileIgnored",
                    "guestFaultWithTheHandlersOff"):
        environment["SNAKEBITE_NO_FAULT_HANDLER"] = "1"
    fixture = tmp_path / "parent-fixture"
    fixture.write_text("must survive native process startup")
    result = subprocess.run(
        [str(binaries["fault_process"]), scenario], cwd=tmp_path,
        env=environment, capture_output=True, timeout=40,
    )
    assert result.returncode == expected, result
    assert fixture.read_text() == "must survive native process startup"
    assert b"internal error" not in result.stderr, result
    if scenario == "faultInCleanup":
        assert b"fault of the guest program: signal 11" in result.stderr, result
    elif scenario in ("hostNullRead", "guestFaultWithTheHandlersOff"):
        assert result.stderr == b"", result


@pytest.mark.parametrize("scenario", [
    "recover", "nested", "fibers", "after-fault", "after-nested",
    "after-return", "after-exception", "after-fibers",
    "recover-direct", "after-fault-direct",
    "after-suspended", "after-other-fiber-suspended",
    "recover-thread", "after-thread", "recover-finalizer", "after-finalizer",
    "fibers-fault-first",
])
def test_recovery_boundary(binaries, tmp_path, scenario):
    result = subprocess.run(
        [str(binaries["fault_boundary"]), scenario], cwd=tmp_path,
        env=clean_environment(), capture_output=True, timeout=15,
    )
    outside = scenario.startswith("after-")
    assert result.returncode == (-signal.SIGSEGV if outside else 0), result
    assert result.stdout == (b"outside-run\n" if outside else b""), result
    assert result.stderr == b"", result


def stack_limit():
    import resource

    resource.setrlimit(resource.RLIMIT_STACK, (256 * 1024, 256 * 1024))


@pytest.mark.parametrize("arguments", [[], ["thread"]], ids=["main", "pthread"])
def test_stack_overflow(binaries, tmp_path, arguments):
    result = subprocess.run(
        [str(binaries["fault_stackoverflow"]), *arguments], cwd=tmp_path,
        env=clean_environment(), capture_output=True, timeout=15,
        preexec_fn=stack_limit,
    )
    assert result.returncode == 1, result
    assert b"snakebite: fatal: stack overflow" in result.stderr, result
