#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1"]
# ///

# Compiler flags change what a whole program means, and a halt ends the
# process, so these tests run whole programs: `native` is the same unittest
# compiled with the same flags by dmd, the reference compiler, and the other
# backends are `bin/sb` on a dub project whose recipe names the flags.

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
    dmd = shutil.which("dmd")
    if dmd is None:
        pytest.skip("dmd, the reference compiler, is not on PATH")

    return dmd


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


# The C runtime's abort is what `assert` becomes under `-checkaction=C`, and
# so is `assert(0)` in the default of a `final switch`.
@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_final_switch_on_non_member_aborts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], """
        enum E { a, b }
        unittest {
            E e = cast(E) 7;
            log("start\\n");
            final switch (e) { case E.a: break; case E.b: break; }
            log("after\\n");
        }
    """)
    assert outcome.status == -SIGABRT, outcome.output
    assert "Assertion `0' failed" in outcome.output
    assert "after" not in outcome.output


# The slices have different lengths, but the storage behind the source has
# a third element, so the unchecked copy of `to.length` elements is well
# defined.
@pytest.mark.parametrize("backend", NO_CTFE_UNCHECKED)
def test_release_slice_copy_length_mismatch_in_system_code_is_not_checked(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        @system unittest {
            int[4] target;
            int[4] source = [1, 2, 3, 4];
            int[] to = target[0 .. 3];
            int[] from = source[0 .. 2];
            log("start\\n");
            to[] = from[];
            if (target == [1, 2, 3, 0])
                log("after\\n");
        }
    """)
    assert_passes_after_start(backend, outcome)


# A slice copy onto an overlapping slice is a bounds failure, as a length
# mismatch is.
@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_overlapping_slice_copy_halts(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], """
        unittest {
            int[5] storage;
            int[] to = storage[0 .. 3];
            int[] from = storage[1 .. 4];
            log("start\\n");
            to[] = from[];
            log("after\\n");
        }
    """)
    assert_halts_after_start(backend, outcome)


def assert_aborts_after_start(outcome: Outcome, message: str) -> None:
    assert outcome.status == -SIGABRT, outcome.output
    assert f"Assertion `{message}' failed" in outcome.output
    assert "start" in outcome.output
    assert "after" not in outcome.output


@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_index_out_of_bounds_aborts_with_the_c_message(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], """
        unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            auto value = slice[3];
            log("after\\n");
        }
    """)
    assert_aborts_after_start(outcome, "array index out of bounds")


@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_slice_out_of_bounds_aborts_with_the_c_message(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], """
        unittest {
            int[4] storage = [1, 2, 3, 4];
            int[] slice = storage[0 .. 2];
            log("start\\n");
            auto value = slice[0 .. 3];
            log("after\\n");
        }
    """)
    assert_aborts_after_start(outcome, "array slice out of bounds")


@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_slice_copy_length_mismatch_aborts_with_the_c_message(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], """
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
    assert_aborts_after_start(outcome, "array overflow")


# The C runtime gets the message of `assert(e, message)` instead of the
# text of `e`.
@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_failed_assert_aborts_with_its_message_expression(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], """
        string message() { return "dynamic"; }
        unittest {
            int x = 1;
            log("start\\n");
            assert(x == 2, message());
            log("after\\n");
        }
    """)
    assert_aborts_after_start(outcome, "dynamic")


# A failed `assert` in a `unittest` block has its own default message.
@pytest.mark.parametrize("backend", BACKENDS)
def test_failed_assert_in_a_unittest_says_unittest_failure(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, [], """
        unittest {
            int x = 1;
            log("start\\n");
            assert(x == 2);
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "unittest failure")


# Outside a `unittest` block the default message is druntime's.
@pytest.mark.parametrize("backend", BACKENDS)
def test_failed_assert_in_a_function_says_assertion_failure(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, [], """
        void check(int x) { assert(x == 2); }
        unittest {
            log("start\\n");
            check(1);
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "Assertion failure")


# A slice copy that fails its check is a `RangeError`, as any bounds
# failure is.
@pytest.mark.parametrize("backend", BACKENDS)
def test_slice_copy_length_mismatch_raises_a_range_error(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, [], """
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
    assert_raises_after_start(backend, outcome, "RangeError")


# `-release` keeps the check in `@safe` code.
@pytest.mark.parametrize("backend", BACKENDS)
def test_release_slice_copy_length_mismatch_in_safe_code_raises(
    tmp_path: Path, backend: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-release"], """
        @safe unittest {
            int[4] target;
            int[4] source = [1, 2, 3, 4];
            int[] to = target[0 .. 3];
            int[] from = source[0 .. 2];
            log("start\\n");
            to[] = from[];
            log("after\\n");
        }
    """)
    assert_raises_after_start(backend, outcome, "RangeError")


# A static array target has a length that the source must match, however
# the copy is written.
STATIC_COPIES = [
    "target[] = from[];",
    "target = from;",
    "int[4] copy = from;",
]


@pytest.mark.parametrize("statement", STATIC_COPIES)
@pytest.mark.parametrize("backend", BACKENDS)
def test_static_array_copy_from_a_shorter_slice_raises(
    tmp_path: Path, backend: str, statement: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, [], f"""
        unittest {{
            int[4] target;
            int[] from = [1, 2, 3];
            log("start\\n");
            {statement}
            log("after\\n");
        }}
    """)
    assert_raises_after_start(backend, outcome, "RangeError")


@pytest.mark.parametrize("statement", STATIC_COPIES)
@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_checkaction_halt_static_array_copy_from_a_shorter_slice_halts(
    tmp_path: Path, backend: str, statement: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=halt"], f"""
        unittest {{
            int[4] target;
            int[] from = [1, 2, 3];
            log("start\\n");
            {statement}
            log("after\\n");
        }}
    """)
    assert_halts_after_start(backend, outcome)


@pytest.mark.parametrize("statement", STATIC_COPIES)
@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_checkaction_c_static_array_copy_from_a_shorter_slice_aborts(
    tmp_path: Path, backend: str, statement: str,
) -> None:
    outcome = run_unittests(tmp_path, backend, ["-checkaction=C"], f"""
        unittest {{
            int[4] target;
            int[] from = [1, 2, 3];
            log("start\\n");
            {statement}
            log("after\\n");
        }}
    """)
    assert_aborts_after_start(outcome, "array overflow")


# `dmd` refuses a `-checkaction=` value that it does not know, and so does
# every backend, before it runs anything.
@pytest.mark.parametrize("backend", BACKENDS)
def test_unknown_checkaction_value_is_an_error(
    tmp_path: Path, backend: str,
) -> None:
    if backend == "native":
        result = subprocess.run(
            [native_compiler(), "-checkaction=bogus", "-o-", "-"],
            input="void main() {}",
            capture_output=True,
            check=False,
            text=True,
            timeout=TIMEOUT,
        )
    else:
        (tmp_path / "dub.sdl").write_text(
            'name "app"\ntargetType "library"\ndflags "-checkaction=bogus"\n',
            encoding="utf-8",
        )
        (tmp_path / "source").mkdir()
        (tmp_path / "source" / "app.d").write_text(
            "module app;\nunittest {}\n", encoding="utf-8",
        )
        result = subprocess.run(
            [sb_path(), f"--backend={backend}", "--no-optimise-image",
             str(tmp_path)],
            capture_output=True,
            check=False,
            text=True,
            timeout=TIMEOUT,
        )

    output = result.stdout + result.stderr
    assert result.returncode == 1, output
    assert "switch `-checkaction=bogus` is invalid" in output


# What a program does when a check is on and fails, or off and does not.
PASSES = ("pass", "")
HALTS = ("halt", "")

# CTFE evaluates every `assert` that dmd's interpreter reaches, whatever the
# assert check says: a row marked with it does not run there.
EVALUATES_ASSERTS = "evaluates asserts"


def raises(message: str) -> tuple[str, str]:
    return ("raise", message)


def aborts(message: str) -> tuple[str, str]:
    return ("abort", message)


def assert_outcome(
    backend: str, outcome: Outcome, expected: tuple[str, str],
) -> None:
    kind, message = expected
    if kind == "pass":
        assert_passes_after_start(backend, outcome)
    elif kind == "halt":
        assert_halts_after_start(backend, outcome)
    elif kind == "raise":
        assert_raises_after_start(backend, outcome, message)
    else:
        assert_aborts_after_start(outcome, message)


# CTFE has no halt and no abort, and always checks bounds.
def backends_for(expected: tuple[str, str], unchecked: bool = False) -> list[str]:
    if expected[0] in ("halt", "abort") or unchecked:
        return [b for b in BACKENDS if b != "ctfe"]

    return BACKENDS


def cases(table: list[tuple], ctfe: bool = True) -> list:
    return [
        pytest.param(
            backend, row[0], row[1],
            id=f"{backend}-{' '.join(row[0]) or 'none'}",
        )
        for row in table
        for backend in backends_for(row[1], len(row) > 2 or not ctfe)
    ]


def run_program(
    tmp_path: Path, backend: str, flags: list[str], program: str,
    expected: tuple[str, str],
) -> None:
    assert_outcome(
        backend, run_unittests(tmp_path, backend, flags, program), expected,
    )


ASSERT_PROGRAM = """
    unittest {
        int x = 1;
        log("start\\n");
        assert(x == 2);
        log("after\\n");
    }
"""

ASSERT_CASES = [
    ([], raises("unittest failure")),
    (["-check=assert"], raises("unittest failure")),
    (["-check=assert=on"], raises("unittest failure")),
    (["-check=assert=off"], PASSES, EVALUATES_ASSERTS),
    (["-check=off"], PASSES, EVALUATES_ASSERTS),
    (["-check=on"], raises("unittest failure")),
    (["-check=assert=off", "-check=assert=on"], raises("unittest failure")),
    (["-check=assert=on", "-check=assert=off"], PASSES, EVALUATES_ASSERTS),
    (["-check=on", "-check=assert=off"], PASSES, EVALUATES_ASSERTS),
    (["-check=assert=off", "-check=on"], raises("unittest failure")),
    (["-check=off", "-check=assert=on"], raises("unittest failure")),
    (["-release", "-check=assert=off"], PASSES, EVALUATES_ASSERTS),
    (["-release", "-check=assert=on"], raises("unittest failure")),
    (["-check=bounds=off"], raises("unittest failure")),
    (["-check=assert=on", "-checkaction=halt"], HALTS),
    (["-check=assert=off", "-checkaction=halt"], PASSES, EVALUATES_ASSERTS),
    (["-check=assert=on", "-checkaction=C"], aborts("x == 2")),
    (["-check=assert=off", "-checkaction=C"], PASSES, EVALUATES_ASSERTS),
]


@pytest.mark.parametrize("backend,flags,expected", cases(ASSERT_CASES))
def test_check_assert(
    tmp_path: Path, backend: str, flags: list[str], expected: tuple[str, str],
) -> None:
    run_program(tmp_path, backend, flags, ASSERT_PROGRAM, expected)


# The operands of an assert that is off are not evaluated.
@pytest.mark.parametrize("backend", NO_CTFE_UNCHECKED)
def test_check_assert_off_does_not_evaluate_the_condition(
    tmp_path: Path, backend: str,
) -> None:
    run_program(tmp_path, backend, ["-check=assert=off"], """
        int fail() { assert(0, "evaluated"); return 0; }
        unittest {
            log("start\\n");
            assert(fail() == 1);
            log("after\\n");
        }
    """, PASSES)


IN_PROGRAM = """
    int positive(int x) in (x > 0) { return x; }
    unittest {
        log("start\\n");
        positive(-1);
        log("after\\n");
    }
"""

IN_CASES = [
    ([], raises("AssertError")),
    (["-check=in"], raises("AssertError")),
    (["-check=in=on"], raises("AssertError")),
    (["-check=in=off"], PASSES),
    (["-check=off"], PASSES),
    (["-check=on"], raises("AssertError")),
    (["-check=out=off"], raises("AssertError")),
    (["-check=assert=off"], PASSES, EVALUATES_ASSERTS),
    (["-release"], PASSES),
    (["-release", "-check=in=on"], raises("AssertError")),
    (["-release", "-check=in"], raises("AssertError")),
    (["-check=in=off", "-check=in=on"], raises("AssertError")),
    (["-check=in=on", "-check=in=off"], PASSES),
    # A contract is an assert: with the assert check off, nothing is left
    # of it.
    (["-check=off", "-check=in=on"], PASSES, EVALUATES_ASSERTS),
    (["-check=in=off", "-check=on"], raises("AssertError")),
    (["-check=in=on", "-checkaction=halt"], HALTS),
    (["-check=in=off", "-checkaction=halt"], PASSES),
    (["-check=in=on", "-checkaction=C"], aborts("x > 0")),
]


@pytest.mark.parametrize("backend,flags,expected", cases(IN_CASES))
def test_check_in(
    tmp_path: Path, backend: str, flags: list[str], expected: tuple[str, str],
) -> None:
    run_program(tmp_path, backend, flags, IN_PROGRAM, expected)


OUT_PROGRAM = """
    int positive(int x) out (result; result > 0) { return x; }
    unittest {
        log("start\\n");
        positive(-1);
        log("after\\n");
    }
"""

OUT_CASES = [
    ([], raises("AssertError")),
    (["-check=out"], raises("AssertError")),
    (["-check=out=on"], raises("AssertError")),
    (["-check=out=off"], PASSES),
    (["-check=off"], PASSES),
    (["-check=on"], raises("AssertError")),
    (["-check=in=off"], raises("AssertError")),
    (["-check=assert=off"], PASSES, EVALUATES_ASSERTS),
    (["-release"], PASSES),
    (["-release", "-check=out=on"], raises("AssertError")),
    (["-check=out=off", "-check=out=on"], raises("AssertError")),
    (["-check=out=on", "-check=out=off"], PASSES),
    (["-check=off", "-check=out=on"], PASSES, EVALUATES_ASSERTS),
    (["-check=out=off", "-check=on"], raises("AssertError")),
    (["-check=out=on", "-checkaction=halt"], HALTS),
    (["-check=out=off", "-checkaction=halt"], PASSES),
]


@pytest.mark.parametrize("backend,flags,expected", cases(OUT_CASES))
def test_check_out(
    tmp_path: Path, backend: str, flags: list[str], expected: tuple[str, str],
) -> None:
    run_program(tmp_path, backend, flags, OUT_PROGRAM, expected)


INVARIANT_PROGRAM = """
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
"""

INVARIANT_CASES = [
    ([], raises("AssertError")),
    (["-check=invariant"], raises("AssertError")),
    (["-check=invariant=on"], raises("AssertError")),
    (["-check=invariant=off"], PASSES),
    (["-check=off"], PASSES),
    (["-check=on"], raises("AssertError")),
    (["-check=in=off", "-check=out=off"], raises("AssertError")),
    (["-release"], PASSES),
    (["-release", "-check=invariant=on"], raises("AssertError")),
    (["-check=invariant=off", "-check=invariant=on"], raises("AssertError")),
    (["-check=invariant=on", "-check=invariant=off"], PASSES),
    (["-check=off", "-check=invariant=on"], PASSES, EVALUATES_ASSERTS),
    (["-check=invariant=off", "-check=on"], raises("AssertError")),
    (["-check=invariant=on", "-checkaction=halt"], HALTS),
    (["-check=invariant=off", "-checkaction=halt"], PASSES),
]


@pytest.mark.parametrize("backend,flags,expected", cases(INVARIANT_CASES))
def test_check_invariant(
    tmp_path: Path, backend: str, flags: list[str], expected: tuple[str, str],
) -> None:
    run_program(tmp_path, backend, flags, INVARIANT_PROGRAM, expected)


# `assert(c)` on a class reference calls its invariant: that is the
# invariant check, not the assert check.
@pytest.mark.parametrize("backend", BACKENDS)
def test_check_invariant_off_skips_the_invariant_of_assert_on_a_class(
    tmp_path: Path, backend: str,
) -> None:
    run_program(tmp_path, backend, ["-check=invariant=off"], """
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
    """, PASSES)


# No member of the enum matches, so a `final switch` has nothing to run.
SWITCH_PROGRAM = """
    enum E { a, b }
    @system unittest {
        E e = cast(E) 7;
        log("start\\n");
        final switch (e) { case E.a: break; case E.b: break; }
        log("after\\n");
    }
"""

SWITCH_CASES = [
    ([], raises("SwitchError")),
    (["-check=switch"], raises("SwitchError")),
    (["-check=switch=on"], raises("SwitchError")),
    (["-check=switch=off"], HALTS),
    (["-check=off"], HALTS),
    (["-check=on"], raises("SwitchError")),
    (["-release"], HALTS),
    (["-release", "-check=switch=on"], raises("SwitchError")),
    (["-check=switch=off", "-check=switch=on"], raises("SwitchError")),
    (["-check=switch=on", "-check=switch=off"], HALTS),
    (["-check=off", "-check=switch=on"], raises("SwitchError")),
    (["-check=switch=off", "-check=on"], raises("SwitchError")),
    (["-check=assert=off"], raises("SwitchError")),
    (["-check=switch=on", "-checkaction=halt"], HALTS),
    (["-check=switch=on", "-checkaction=C"], aborts("0")),
    (["-check=switch=off", "-checkaction=C"], HALTS),
    (["-check=assert=off", "-check=switch=off"], HALTS),
]


# CTFE does not raise the error of a `final switch` that no case matches.
@pytest.mark.parametrize(
    "backend,flags,expected", cases(SWITCH_CASES, ctfe=False),
)
def test_check_switch(
    tmp_path: Path, backend: str, flags: list[str], expected: tuple[str, str],
) -> None:
    run_program(tmp_path, backend, flags, SWITCH_PROGRAM, expected)


# The bounds check that a flag set ends up with.
ON = "on"
OFF = "off"
SAFEONLY = "safeonly"

# dub turns `-boundscheck=off` into its `noBoundsCheck` option and puts the
# option after the other flags, so no row here has two `-boundscheck=` flags
# where the order of an `off` among them matters.
BOUNDS_FLAGS = [
    (["-check=bounds"], ON),
    (["-check=bounds=on"], ON),
    (["-check=bounds=off"], OFF),
    (["-boundscheck=on"], ON),
    (["-boundscheck=safeonly"], SAFEONLY),
    (["-boundscheck=off"], OFF),
    (["-noboundscheck"], OFF),
    (["-release"], SAFEONLY),
    (["-release", "-check=bounds=on"], ON),
    (["-release", "-check=bounds=off"], OFF),
    (["-release", "-boundscheck=on"], ON),
    (["-release", "-boundscheck=off"], OFF),
    (["-release", "-boundscheck=safeonly"], SAFEONLY),
    # `-check=bounds` is the specific flag: it wins over `-boundscheck=`
    # whichever comes first.
    (["-check=bounds=on", "-boundscheck=off"], ON),
    (["-boundscheck=off", "-check=bounds=on"], ON),
    (["-check=bounds=off", "-boundscheck=on"], OFF),
    (["-check=bounds=off", "-check=bounds=on"], ON),
    (["-check=bounds=on", "-check=bounds=off"], OFF),
    (["-check=off"], OFF),
    (["-check=on"], ON),
    (["-check=off", "-boundscheck=on"], OFF),
    (["-boundscheck=on", "-check=off"], OFF),
    (["-check=off", "-check=on"], ON),
    (["-check=off", "-release"], OFF),
    (["-boundscheck=safeonly", "-check=on"], ON),
]

ATTRIBUTES = ["@safe", "@trusted", "@system"]

BOUNDS_PROGRAMS = {
    "index": ("""
        int[4] storage = [1, 2, 3, 4];
        int[] slice = storage[0 .. 2];
        log("start\\n");
        auto value = slice[3];
        log("after\\n");
    """, "ArrayIndexError"),
    "slice": ("""
        int[4] storage = [1, 2, 3, 4];
        int[] slice = storage[0 .. 2];
        log("start\\n");
        auto value = slice[0 .. 3];
        log("after\\n");
    """, "ArraySliceError"),
    "slice copy": ("""
        int[4] target;
        int[4] source = [1, 2, 3, 4];
        int[] to = target[0 .. 3];
        int[] from = source[0 .. 2];
        log("start\\n");
        to[] = from[];
        log("after\\n");
    """, "RangeError"),
}


def bounds_expectation(
    effective: str, attribute: str, message: str,
) -> tuple[tuple[str, str], bool]:
    checked = effective == ON or (effective == SAFEONLY and attribute == "@safe")

    return (raises(message), False) if checked else (PASSES, True)


def bounds_cases(
    flag_table: list[tuple[list[str], str]],
    program_names: list[str],
) -> list:
    result = []
    for flags, effective in flag_table:
        for name in program_names:
            body, message = BOUNDS_PROGRAMS[name]
            for attribute in ATTRIBUTES:
                expected, unchecked = bounds_expectation(
                    effective, attribute, message,
                )
                for backend in backends_for(expected, unchecked):
                    result.append(pytest.param(
                        backend, flags, name, attribute, expected,
                        id=f"{backend}-{' '.join(flags)}-{name}-{attribute}",
                    ))
    return result


@pytest.mark.parametrize(
    "backend,flags,name,attribute,expected",
    bounds_cases(BOUNDS_FLAGS, ["index"]),
)
def test_check_bounds_index(
    tmp_path: Path, backend: str, flags: list[str], name: str,
    attribute: str, expected: tuple[str, str],
) -> None:
    body, _ = BOUNDS_PROGRAMS[name]
    run_program(
        tmp_path, backend, flags, f"{attribute} unittest {{ {body} }}", expected,
    )


# The slice and the slice copy are bounds checks that dmd's glue layer
# emits separately from the index.
@pytest.mark.parametrize(
    "backend,flags,name,attribute,expected",
    bounds_cases(
        [
            (["-check=bounds=on"], ON),
            (["-check=bounds=off"], OFF),
            (["-boundscheck=safeonly"], SAFEONLY),
            (["-release"], SAFEONLY),
        ],
        ["slice", "slice copy"],
    ),
)
def test_check_bounds_slice_and_copy(
    tmp_path: Path, backend: str, flags: list[str], name: str,
    attribute: str, expected: tuple[str, str],
) -> None:
    body, _ = BOUNDS_PROGRAMS[name]
    run_program(
        tmp_path, backend, flags, f"{attribute} unittest {{ {body} }}", expected,
    )


# A pointer has no length to check an upper bound against, and its slice
# is never `@safe`; the order of its bounds is checked as any bounds are.
POINTER_SLICE = """
    {attribute} unittest {{
        int[4] storage = [1, 2, 3, 4];
        int* pointer = storage.ptr;
        size_t lower = {lower};
        size_t upper = {upper};
        log("start\\n");
        auto value = pointer[lower .. upper];
        log("after\\n");
    }}
"""


@pytest.mark.parametrize("attribute", ["@trusted", "@system"])
@pytest.mark.parametrize("flags", [
    ["-check=bounds=on"], ["-check=bounds=off"], ["-release"],
])
@pytest.mark.parametrize("backend", BACKENDS)
def test_check_bounds_pointer_slice_has_no_upper_limit(
    tmp_path: Path, backend: str, flags: list[str], attribute: str,
) -> None:
    run_program(
        tmp_path, backend, flags,
        POINTER_SLICE.format(attribute=attribute, lower=1, upper=3), PASSES,
    )


@pytest.mark.parametrize("attribute", ["@trusted", "@system"])
@pytest.mark.parametrize("flags,effective", [
    (["-check=bounds=on"], ON),
    (["-check=bounds=off"], OFF),
    (["-boundscheck=safeonly"], SAFEONLY),
    (["-release"], SAFEONLY),
])
@pytest.mark.parametrize("backend", NO_CTFE_UNCHECKED)
def test_check_bounds_reversed_pointer_slice(
    tmp_path: Path, backend: str, flags: list[str], effective: str,
    attribute: str,
) -> None:
    expected = raises("ArraySliceError") if effective == ON else PASSES
    run_program(
        tmp_path, backend, flags,
        POINTER_SLICE.format(attribute=attribute, lower=2, upper=1), expected,
    )


# The two checks are independent: a bounds failure with the assert check
# off still fails, and a failed assert with the bounds check off too.
@pytest.mark.parametrize("backend", BACKENDS)
def test_check_assert_off_still_checks_bounds(
    tmp_path: Path, backend: str,
) -> None:
    body, message = BOUNDS_PROGRAMS["index"]
    run_program(
        tmp_path, backend, ["-check=assert=off"],
        f"@safe unittest {{ {body} }}", raises(message),
    )


@pytest.mark.parametrize("backend", NO_CTFE_HALT)
def test_check_bounds_on_halts_with_checkaction_halt(
    tmp_path: Path, backend: str,
) -> None:
    body, _ = BOUNDS_PROGRAMS["index"]
    run_program(
        tmp_path, backend, ["-check=bounds=on", "-checkaction=halt"],
        f"@system unittest {{ {body} }}", HALTS,
    )


@pytest.mark.parametrize("backend", NO_CTFE_UNCHECKED)
def test_check_bounds_off_does_not_halt_with_checkaction_halt(
    tmp_path: Path, backend: str,
) -> None:
    body, _ = BOUNDS_PROGRAMS["index"]
    run_program(
        tmp_path, backend, ["-check=bounds=off", "-checkaction=halt"],
        f"@system unittest {{ {body} }}", PASSES,
    )


@pytest.mark.parametrize("backend", NO_CTFE_ABORT)
def test_check_bounds_on_aborts_with_checkaction_c(
    tmp_path: Path, backend: str,
) -> None:
    body, _ = BOUNDS_PROGRAMS["index"]
    run_program(
        tmp_path, backend, ["-boundscheck=on", "-checkaction=C"],
        f"@system unittest {{ {body} }}", aborts("array index out of bounds"),
    )


# `dmd` refuses a value of `-check=` or `-boundscheck=` that it does not
# know, and so does every backend, before it runs anything.
@pytest.mark.parametrize("flag", [
    "-check=bogus",
    "-check=bounds=maybe",
    "-check=bounds=ON",
    "-check=assertx",
    "-check=",
    "-check",
    "-boundscheck=bogus",
    "-boundscheck",
])
@pytest.mark.parametrize("backend", BACKENDS)
def test_unknown_check_flag_value_is_an_error(
    tmp_path: Path, backend: str, flag: str,
) -> None:
    if backend == "native":
        result = subprocess.run(
            [native_compiler(), flag, "-o-", "-"],
            input="void main() {}",
            capture_output=True,
            check=False,
            text=True,
            timeout=TIMEOUT,
        )
    else:
        (tmp_path / "dub.sdl").write_text(
            f'name "app"\ntargetType "library"\ndflags "{flag}"\n',
            encoding="utf-8",
        )
        (tmp_path / "source").mkdir()
        (tmp_path / "source" / "app.d").write_text(
            "module app;\nunittest {}\n", encoding="utf-8",
        )
        result = subprocess.run(
            [sb_path(), f"--backend={backend}", "--no-optimise-image",
             str(tmp_path)],
            capture_output=True,
            check=False,
            text=True,
            timeout=TIMEOUT,
        )

    output = result.stdout + result.stderr
    assert result.returncode == 1, output
    assert flag in output


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
