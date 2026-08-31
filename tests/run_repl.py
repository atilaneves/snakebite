#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pexpect==4.9.0", "pytest==8.4.1"]
# ///

import os
import re
import subprocess
from pathlib import Path

import pexpect
import pytest

_ANSI_ESCAPE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

TIMEOUT = 10
UP_ARROW = "\x1b[A"


def test_repl() -> None:
    repl = sb_path()
    child = pexpect.spawn(repl, timeout=TIMEOUT, encoding="utf-8")
    try:
        child.expect_exact("Snakebite REPL")
        child.expect_exact("[   0.0 ms] > ")

        child.sendline("1 + 2")
        child.expect(r"\[\s+\d+\.\d ms\] > ")
        output = clean(child.before)
        assert "3\n" in output

        child.sendline(UP_ARROW)
        child.expect(r"\[\s+\d+\.\d ms\] > ")
        output = clean(child.before)
        assert "3\n" in output

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def test_piped_blank_line_is_silent_noop() -> None:
    result = run_sb(input="\n")

    assert result.returncode == 0
    assert result.stdout == ""


def test_piped_whitespace_line_is_silent_noop() -> None:
    result = run_sb(input="   \n")

    assert result.returncode == 0
    assert result.stdout == ""


def test_interactive_error_label_is_red() -> None:
    child = pexpect.spawn(sb_path(), timeout=TIMEOUT, encoding="utf-8")
    try:
        child.expect_exact("Snakebite REPL")
        child.expect_exact("[   0.0 ms] > ")

        child.sendline("unittest { assert(1 == 2); }")
        child.expect(r"\[\s+\d+\.\d ms\] > ")

        child.sendline(":t")
        child.expect_exact(
            "\x1b[31mError:\x1b[0m unittest at <repl cell 1>(1) failed: 1 != 2",
        )
        child.expect(r"\[\s+\d+\.\d ms\] > ")

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def test_piped_error_label_is_not_coloured() -> None:
    result = run_sb(input="1 / 0\n")

    assert result.returncode == 0
    assert result.stdout.startswith("Error: ")
    assert "\x1b[" not in result.stdout


def test_piped_mode_continues_after_error() -> None:
    result = run_sb(input="1 + 1\n2 + 2\nbad_var\n4 + 4\n5 + 5\n")

    assert result.returncode == 0
    assert result.stdout == (
        "2\n"
        "4\n"
        "Error: undefined identifier `bad_var`\n"
        "8\n"
        "10\n"
    )


def test_piped_pragma_msg_writes_once_to_stderr() -> None:
    result = run_sb(input='pragma(msg, "hello");\n42\n')

    assert result.returncode == 0
    assert result.stdout == "42\n"
    assert result.stderr == "hello\n"


def test_piped_failed_import_writes_only_error_to_stdout() -> None:
    result = run_sb(input="import mymodule;\n")

    assert result.returncode == 0
    assert result.stdout == "Error: unable to read module `mymodule`\n"
    assert result.stderr == ""


def test_piped_quit_command_does_not_abandon_pending_input() -> None:
    result = run_sb(
        input="int answer() {\n:q\nreturn 42;\n}\nanswer()\n:q\n",
    )

    assert result.returncode == 0
    assert result.stdout == (
        "Error: cannot run REPL command `:q` while input is pending\n"
        "42\n"
    )


def test_command_prints_expression_result() -> None:
    result = run_sb("-c", "1 + 2")

    assert result.returncode == 0
    assert result.stdout == "3\n"


def test_command_can_use_several_file_arguments(tmp_path: Path) -> None:
    first = tmp_path / "first.d"
    second = tmp_path / "second.d"
    first.write_text(
        "int firstValue() { return 19; }\n",
        encoding="utf-8",
    )
    second.write_text(
        "int secondValue() { return firstValue() + 23; }\n",
        encoding="utf-8",
    )

    result = run_sb(str(first), str(second), "-c", "secondValue()")

    assert result.returncode == 0
    assert result.stdout == "42\n"
    assert result.stderr == ""


def test_file_argument_can_import_module_from_import_path(tmp_path: Path) -> None:
    imports = tmp_path / "imports"
    imports.mkdir()
    (imports / "quickbite_repl_imported.d").write_text(
        "module quickbite_repl_imported;\n"
        "int importedValue() { return 41; }\n",
        encoding="utf-8",
    )
    file = tmp_path / "loaded.d"
    file.write_text(
        "import quickbite_repl_imported;\n"
        "int loadedValue() { return importedValue() + 1; }\n",
        encoding="utf-8",
    )

    result = run_sb("-I", str(imports), str(file), "-c", "loadedValue()")

    assert result.returncode == 0
    assert result.stdout == "42\n"
    assert result.stderr == ""


def test_file_argument_loads_example_fixture() -> None:
    result = run_sb("tests/examples/ct.d")

    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""


def test_file_argument_exits_without_interactive_prompt() -> None:
    child = pexpect.spawn(
        sb_path(),
        ["tests/examples/ct.d"],
        timeout=TIMEOUT,
        encoding="utf-8",
    )
    try:
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0
    assert "Snakebite REPL" not in child.before
    assert "> " not in child.before


def test_live_flag_keeps_repl_open_after_file_arguments(tmp_path: Path) -> None:
    module = tmp_path / "loaded.d"
    module.write_text(
        "int loadedValue() { return 42; }\n",
        encoding="utf-8",
    )

    child = pexpect.spawn(
        sb_path(),
        ["-l", str(module)],
        timeout=TIMEOUT,
        encoding="utf-8",
    )
    try:
        child.expect_exact("Snakebite REPL")
        child.expect_exact("[   0.0 ms] > ")

        child.sendline("loadedValue()")
        child.expect(r"\[\s+\d+\.\d ms\] > ")
        output = clean(child.before)
        assert "42\n" in output

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def run_sb(*args: str, input: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sb_path(), *args],
        input=input,
        capture_output=True,
        check=False,
        text=True,
        timeout=TIMEOUT,
    )


def sb_path() -> str:
    repl = os.path.join(os.getcwd(), "bin", "sb")
    if not os.path.exists(repl):
        pytest.skip("bin/sb does not exist; run `dub build -c sb` first")

    return repl


def clean(text: str) -> str:
    return _ANSI_ESCAPE.sub("", text).replace("\r", "")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
