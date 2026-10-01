#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1"]
# ///

# Compiler flags change what a whole program means, and a halt ends the
# process, so these tests run whole programs: `native` is the same unittest
# compiled with the same flags by the compiler that built snakebite, and the
# other backends are `bin/sb` on a dub project whose recipe names the flags.

import os
import shutil
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

TIMEOUT = 120

BACKENDS = ["native", "bytecode", "interpreter", "ctfe"]

# CTFE cannot halt: it reports a failed check as a compile-time error.
NO_CTFE_HALT = ["native", "bytecode", "interpreter"]

# CTFE always checks bounds, whatever the function's safety.
NO_CTFE_UNCHECKED = ["native", "bytecode", "interpreter"]

# The abort and its message come from the C runtime, which CTFE cannot call.
NO_CTFE_ABORT = ["native", "bytecode", "interpreter"]

# The program logs through the native `fputs`, which CTFE cannot call, so
# `log` does nothing at compile time and a CTFE run only has an exit status.
PRELUDE = """\
module app;
import core.stdc.stdio: fputs, stderr;
@trusted void log(string text) { if (!__ctfe) fputs(text.ptr, stderr); }
"""

SIGILL = signal.SIGILL.value
SIGABRT = signal.SIGABRT.value


@dataclass(frozen=True)
class Outcome:
    status: int
    output: str


def run_unittests(
    directory: Path, backend: str, flags: list[str], source: str,
) -> Outcome:
    code = PRELUDE + source
    if backend == "native":
        return run_native(directory, flags, code)

    recipe = 'name "app"\ntargetType "library"\n'
    for flag in flags:
        recipe += f'dflags "{flag}"\n'
    (directory / "dub.sdl").write_text(recipe, encoding="utf-8")
    (directory / "source").mkdir()
    (directory / "source" / "app.d").write_text(code, encoding="utf-8")

    return outcome_of(
        subprocess.run(
            [sb_path(), f"--backend={backend}", "--no-optimise-image",
             str(directory)],
            capture_output=True,
            check=False,
            text=True,
            timeout=TIMEOUT,
        ),
    )


def run_native(directory: Path, flags: list[str], code: str) -> Outcome:
    (directory / "app.d").write_text(code, encoding="utf-8")
    compiled = subprocess.run(
        [native_compiler(), "-unittest", "-main",
         f"-of={directory / 'app'}", *flags, str(directory / "app.d")],
        capture_output=True,
        check=False,
        text=True,
        timeout=TIMEOUT,
    )
    assert compiled.returncode == 0, compiled.stdout + compiled.stderr

    return outcome_of(
        subprocess.run(
            [str(directory / "app")],
            capture_output=True,
            check=False,
            text=True,
            timeout=TIMEOUT,
        ),
    )


def outcome_of(result: subprocess.CompletedProcess[str]) -> Outcome:
    return Outcome(result.returncode, result.stdout + result.stderr)


# dmd is the reference: snakebite takes its frontend and its glue layer
# decisions from it, and ldc2 differs from it in some of the cases here.
def native_compiler() -> str:
    return shutil.which("dmd") or "ldc2"


def sb_path() -> str:
    sb = os.path.join(os.getcwd(), "bin", "sb")
    if not os.path.exists(sb):
        pytest.skip("bin/sb does not exist; run `ninja bin/sb` first")

    return sb


# A halt kills the process with SIGILL (`ud2`), so the log ends where the
# halt happened.
def assert_halts_after_start(backend: str, outcome: Outcome) -> None:
    assert outcome.status == -SIGILL, outcome.output
    assert "start" in outcome.output
    assert "after" not in outcome.output


def assert_passes_after_start(backend: str, outcome: Outcome) -> None:
    assert outcome.status == 0, outcome.output
    if backend != "ctfe":
        assert "start" in outcome.output
        assert "after" in outcome.output


def assert_raises_after_start(
    backend: str, outcome: Outcome, message: str,
) -> None:
    assert outcome.status == 1, outcome.output
    if backend != "ctfe":
        assert message in outcome.output
        assert "start" in outcome.output
        assert "after" not in outcome.output


@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_failed_assert_halts_the_process(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        unittest {
            int x = 1;
            log("start\\n");
            assert(x == 2);
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


# The halt form of `assert(e)` is `e || halt`: it never reaches the
# invariant call that the default form makes after the test passes.
@pytest.mark.parametrize("backend", BACKENDS)
def test_checkaction_halt_failed_assert_on_class_skips_its_invariant(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        class C {
            int x = 1;
            invariant { assert(x > 0); }
        }
        unittest {
            auto c = new C;
            c.x = -1;
            log("start\\n");
            assert(c);
            log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_final_switch_on_non_member_halts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        enum E { a, b }
        unittest {
            E e = cast(E) 7;
            log("start\\n");
            final switch (e) { case E.a: break; case E.b: break; }
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_index_out_of_bounds_halts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            auto value = slice[3];
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_slice_out_of_bounds_halts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            auto value = slice[0 .. 3];
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


# A slice copy with different lengths is a bounds failure: compiled code
# halts as it does for an index.
@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_slice_copy_length_mismatch_halts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        unittest {
            int[4] target;
            int[4] source = [1, 2, 3, 4];
            int[] to = target[0 .. 3];
            int[] from = source[0 .. 2];
            log("start\\n");
            to[] = from[];
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


# `dmd -unittest -release` keeps `assert`: unittest mode turns assertions
# on before `-release` turns them off.
@pytest.mark.parametrize("backend", BACKENDS)
def test_release_assert_stays_on_in_unittests(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        unittest {
            int x = 1;
            log("start\\n");
            assert(x == 2);
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "AssertError")


@pytest.mark.parametrize("backend", BACKENDS)
def test_release_precondition_is_not_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        int positive(int x) in (x > 0) { return x; }
        unittest {
            log("start\\n");
            positive(-1);
            log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


@pytest.mark.parametrize("backend", BACKENDS)
def test_release_postcondition_is_not_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        int positive(int x) out (result; result > 0) { return x; }
        unittest {
            log("start\\n");
            positive(-1);
            log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


@pytest.mark.parametrize("backend", BACKENDS)
def test_release_invariant_is_not_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        class C {
            int x = 1;
            invariant { assert(x > 0); }
            void set(int value) { x = value; }
        }
        unittest {
            auto c = new C;
            log("start\\n");
            c.set(-1);
            log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


@pytest.mark.parametrize("backend", BACKENDS)
def test_release_assert_on_class_does_not_check_its_invariant(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        class C {
            int x = 1;
            invariant { assert(x > 0); }
        }
        unittest {
            auto c = new C;
            c.x = -1;
            log("start\\n");
            assert(c);
            log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


# The guest asserts the identifiers instead of logging them, so that a
# CTFE run, which has no log, checks the same thing.
@pytest.mark.parametrize("backend", BACKENDS)
def test_release_contract_versions_are_undefined(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        unittest {
            version (D_PreConditions) assert(0, "D_PreConditions is defined");
            version (D_PostConditions) assert(0, "D_PostConditions is defined");
            version (D_Invariants) assert(0, "D_Invariants is defined");
            version (assert) {} else assert(0, "assert is not defined");
        }
    """)
    assert outcome.status == 0, outcome.output


@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_release_final_switch_on_non_member_halts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        enum E { a, b }
        @system unittest {
            E e = cast(E) 7;
            log("start\\n");
            final switch (e) { case E.a: break; case E.b: break; }
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


@pytest.mark.parametrize("backend", BACKENDS)
def test_release_index_out_of_bounds_in_safe_code_is_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        @safe unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            auto value = slice[3];
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "ArrayIndexError")


# The slice stops at 2 but the storage behind it has a fourth element, so
# the unchecked read is well defined.
@pytest.mark.parametrize("backend", NO_CTFE_UNCHECKED)
def test_release_index_out_of_bounds_in_system_code_is_not_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        @system unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            if (slice[3] == 4)
                log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


@pytest.mark.parametrize("backend", BACKENDS)
def test_release_slice_out_of_bounds_in_safe_code_is_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        @safe unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            auto value = slice[0 .. 3];
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "ArraySliceError")


@pytest.mark.parametrize("backend", NO_CTFE_UNCHECKED)
def test_release_slice_out_of_bounds_in_system_code_is_not_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        @system unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            if (slice[0 .. 3].length == 3)
                log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_failed_assert_aborts_with_the_c_message(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], """
        unittest {
            int x = 1;
            log("start\\n");
            assert(x == 2);
            log("after\\n");
        }
    """)
    assert outcome.status == -SIGABRT, outcome.output
    assert "Assertion `x == 2' failed" in outcome.output
    assert "after" not in outcome.output


@pytest.mark.parametrize("backend", BACKENDS)
def test_checkaction_context_failed_assert_prints_the_operands(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=context"], """
        unittest {
            int x = 1;
            log("start\\n");
            assert(x == 2);
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "1 != 2")


# The message of a failed assert is an expression: it runs when the
# assert fails.
@pytest.mark.parametrize("backend", BACKENDS)
def test_failed_assert_evaluates_its_message_expression(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, [], """
        string message() { return "dynamic"; }
        unittest {
            log("start\\n");
            assert(false, message());
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "dynamic")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
