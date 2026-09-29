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


@pytest.mark.parametrize("backend", ["interpreter", "bytecode", "ctfe"])
def test_project_import_without_semicolon(tmp_path: Path, backend: str) -> None:
    (tmp_path / "dub.sdl").write_text(
        'name "repl-import-test"\n', encoding="utf-8",
    )
    source = tmp_path / "source"
    source.mkdir()
    (source / "repl_import_test.d").write_text(
        "module repl_import_test;\n"
        "T importedValue(T)(T value) { return value; }\n",
        encoding="utf-8",
    )

    child = pexpect.spawn(
        sb_path(),
        ["--project", str(tmp_path), "-b", backend],
        timeout=TIMEOUT,
        encoding="utf-8",
    )
    try:
        child.expect_exact("Snakebite REPL")
        child.expect_exact("[   0.0 ms] > ")

        child.sendline("import repl_import_test")
        child.expect(r"\[\s+\d+\.\d ms\] > ")
        assert "Error:" not in clean(child.before)

        child.sendline("importedValue(42)")
        child.expect(r"\[\s+\d+\.\d ms\] > ")
        assert "42\n" in clean(child.before)

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def write_versioned_project(directory: Path) -> None:
    (directory / "dub.sdl").write_text(
        'name "repl-lazy-project"\n'
        'versions "ReplProjectVersion"\n'
        'stringImportPaths "views"\n',
        encoding="utf-8",
    )
    views = directory / "views"
    views.mkdir()
    (views / "greeting.txt").write_text("hello", encoding="utf-8")
    source = directory / "source"
    source.mkdir()
    (source / "repl_used.d").write_text(
        "module repl_used;\n"
        "version (ReplProjectVersion) int answer() { return 42; }\n"
        'string greeting() { return import("greeting.txt"); }\n',
        encoding="utf-8",
    )
    (source / "repl_unused.d").write_text(
        "module repl_unused;\n"
        'pragma(msg, "repl_unused was analysed");\n',
        encoding="utf-8",
    )


# The frontend analyses what a cell reaches, not the whole project, once
# the project's dependency image is on disk. A module that no cell
# imports has no compile-time effect.
def test_project_module_is_not_analysed_until_imported(tmp_path: Path) -> None:
    write_versioned_project(tmp_path)
    warm = run_sb("--project", str(tmp_path), "-c", "1 + 1", cwd=tmp_path)
    assert warm.returncode == 0

    result = run_sb("--project", str(tmp_path), "-c", "1 + 1", cwd=tmp_path)

    assert result.returncode == 0
    assert result.stdout == "2\n"
    assert result.stderr == ""

    result = run_sb(
        "--project", str(tmp_path), "-c", "import repl_unused;", cwd=tmp_path,
    )

    assert result.returncode == 0
    assert result.stderr == "repl_unused was analysed\n"


# A bare directory whose modules call no dependency template needs no
# dependency image. That answer is remembered the same way an image is,
# so a warm start does not run the frontend over the project. The clock
# module fails semantic analysis at any `__TIME__` but midnight, and
# `SOURCE_DATE_EPOCH` sets `__TIME__` without changing any input the
# image cache records: the warm start fails if it analyses the project.
def test_warm_start_does_not_analyse_a_project_without_an_image(
    tmp_path: Path,
) -> None:
    write_project_without_image(tmp_path)
    (tmp_path / "clock.d").write_text(
        "module clock;\n"
        'static assert(__TIME__ == "00:00:00", "clock was analysed");\n',
        encoding="utf-8",
    )

    cold = run_sb(
        "--project", str(tmp_path), input="import used;\nanswer()\n",
        cwd=tmp_path, timeout_seconds=120, env={"SOURCE_DATE_EPOCH": "0"},
    )
    warm = run_sb(
        "--project", str(tmp_path), input="import used;\nanswer()\n",
        cwd=tmp_path, timeout_seconds=120, env={"SOURCE_DATE_EPOCH": "3600"},
    )

    assert cold.returncode == 0
    assert cold.stdout == "42\n"
    assert warm.returncode == 0
    assert warm.stdout == "42\n"
    assert "clock was analysed" not in warm.stdout + warm.stderr


# A remembered "no image" answer holds only while the project's inputs
# are unchanged: a new module is analysed on the next start.
def test_project_without_an_image_notices_a_new_module(tmp_path: Path) -> None:
    write_project_without_image(tmp_path)
    warm = run_sb(
        "--project", str(tmp_path), input="import used;\nanswer()\n",
        cwd=tmp_path, timeout_seconds=120,
    )
    assert warm.returncode == 0
    (tmp_path / "broken.d").write_text(
        "module broken;\n"
        'static assert(false, "broken was analysed");\n',
        encoding="utf-8",
    )

    result = run_sb(
        "--project", str(tmp_path), input="import used;\nanswer()\n",
        cwd=tmp_path, timeout_seconds=120,
    )

    assert result.returncode != 0
    assert "broken was analysed" in result.stdout


def write_project_without_image(directory: Path) -> None:
    (directory / "used.d").write_text(
        "module used;\nint answer() { return 42; }\n", encoding="utf-8",
    )


# The project's versions and string imports apply to the project modules
# a cell imports, whether or not the dependency image was already built.
def test_project_import_sees_project_versions(tmp_path: Path) -> None:
    write_versioned_project(tmp_path)

    for _ in range(2):
        result = run_sb(
            "--project", str(tmp_path),
            input="import repl_used;\nanswer()\ngreeting()\n",
            cwd=tmp_path,
        )

        assert result.returncode == 0
        assert result.stdout == "42\nhello\n"


def write_versioned_package(directory: Path) -> None:
    (directory / "dub.sdl").write_text(
        'name "repl-versioned-package"\nversions "ProjV"\n',
        encoding="utf-8",
    )
    package = directory / "source" / "pkg"
    package.mkdir(parents=True)
    (package / "package.d").write_text(
        "module pkg;\npublic import pkg.foo;\n", encoding="utf-8",
    )
    (package / "foo.d").write_text(
        "module pkg.foo;\n"
        "version (ProjV) int top() { return 42; }\n"
        "int answer() { version (ProjV) return 42; else return 0; }\n",
        encoding="utf-8",
    )


# `dub build` compiles every module of the project with the project's
# versions, however a module is reached: here through a package's
# `package.d` and its `public import`.
@pytest.mark.parametrize("backend", ["interpreter", "bytecode", "ctfe"])
def test_package_module_sees_project_versions(
    tmp_path: Path, backend: str,
) -> None:
    write_versioned_package(tmp_path)

    for _ in range(2):
        result = run_sb(
            "--project", str(tmp_path), "-b", backend,
            input="import pkg;\ntop()\nanswer()\n",
            cwd=tmp_path,
            timeout_seconds=60,
        )

        assert result.returncode == 0
        assert result.stdout == "42\n42\n"


def write_nested_import_project(directory: Path) -> None:
    (directory / "dub.sdl").write_text(
        'name "repl-nested-import"\nversions "ProjV"\n', encoding="utf-8",
    )
    source = directory / "source"
    source.mkdir()
    (source / "outer.d").write_text(
        "module outer;\n"
        "version (ProjV) import conditional;\n"
        "int local() { import inner; return innerAnswer(); }\n"
        "int viaVersion() { return conditionalAnswer(); }\n",
        encoding="utf-8",
    )
    (source / "inner.d").write_text(
        "module inner;\n"
        "int innerAnswer() { version (ProjV) return 42; else return 0; }\n",
        encoding="utf-8",
    )
    (source / "conditional.d").write_text(
        "module conditional;\n"
        "int conditionalAnswer() {\n"
        "    version (ProjV) return 43; else return 0;\n"
        "}\n",
        encoding="utf-8",
    )


# A project module imported inside a function body or a `version` block
# is compiled with the project's versions too, as `dub build` does.
@pytest.mark.parametrize("backend", ["interpreter", "bytecode", "ctfe"])
def test_nested_import_sees_project_versions(
    tmp_path: Path, backend: str,
) -> None:
    write_nested_import_project(tmp_path)

    for _ in range(2):
        result = run_sb(
            "--project", str(tmp_path), "-b", backend,
            input="import outer;\nlocal()\nviaVersion()\n",
            cwd=tmp_path,
            timeout_seconds=60,
        )

        assert result.returncode == 0
        assert result.stdout == "42\n43\n"


# A session runs the same whether or not the project's dependency image is
# already built, from any working directory. It works in the project
# directory, as `dub build` does, so a project module's `__FILE__` is the
# path dub hands the compiler: relative to the project directory.
@pytest.mark.parametrize("working_directory", ["project", "elsewhere"])
def test_project_session_is_the_same_on_a_cold_and_a_warm_image_cache(
    tmp_path: Path, working_directory: str,
) -> None:
    project = tmp_path / "project"
    source = project / "source"
    source.mkdir(parents=True)
    (tmp_path / "elsewhere").mkdir()
    (project / "dub.sdl").write_text('name "good"\n', encoding="utf-8")
    (source / "good.d").write_text(
        "module good;\n"
        "string file() { return __FILE__; }\n"
        "string fullPath() { return __FILE_FULL_PATH__; }\n"
        "int answer() { return 42; }\n",
        encoding="utf-8",
    )
    (source / "unused.d").write_text(
        "module unused;\n"
        'pragma(msg, "unused was analysed");\n',
        encoding="utf-8",
    )
    full_path = os.path.realpath(source / "good.d")

    for _ in range(2):
        result = run_sb(
            "--project", str(project),
            input="import good;\nfile()\nfullPath()\nanswer()\nimport unused;\n",
            cwd=tmp_path / working_directory,
            timeout_seconds=60,
        )

        assert result.returncode == 0
        assert result.stdout == f"source/good.d\n{full_path}\n42\n"
        assert result.stderr == "unused was analysed\n"


# Paths on the command line are relative to where the session starts,
# even though a project session works in the project directory.
def test_project_session_resolves_arguments_from_its_start_directory(
    tmp_path: Path,
) -> None:
    source = tmp_path / "project" / "source"
    source.mkdir(parents=True)
    (tmp_path / "project" / "dub.sdl").write_text(
        'name "arguments"\n', encoding="utf-8",
    )
    (source / "arguments.d").write_text(
        "module arguments;\nint fromProject() { return 1; }\n",
        encoding="utf-8",
    )
    imports = tmp_path / "imports"
    imports.mkdir()
    (imports / "extra.d").write_text(
        "module extra;\nint fromImportPath() { return 2; }\n",
        encoding="utf-8",
    )
    (tmp_path / "loaded.d").write_text(
        "import arguments;\nimport extra;\n"
        "int loadedValue() { return fromProject() + fromImportPath(); }\n",
        encoding="utf-8",
    )

    result = run_sb(
        "--project", "project", "-I", "imports", "loaded.d",
        "-c", "loadedValue()",
        cwd=tmp_path,
        timeout_seconds=60,
    )

    assert result.returncode == 0
    assert result.stdout == "3\n"
    assert result.stderr == ""


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


@pytest.mark.parametrize("backend", ["interpreter", "bytecode"])
def test_command_uses_requested_backend(backend: str) -> None:
    result = run_sb("-b", backend, "-c", "1 + 2")

    assert result.returncode == 0
    assert result.stdout == "3\n"
    assert result.stderr == ""


# A REPL session holds the whole frontend heap. A garbage collection at
# exit only finds garbage that the OS reclaims anyway, and over that heap
# it costs more than the rest of a `-c` run's shutdown. The GC profile
# printed at exit counts every collection, so a count equal to the one the
# command saw means that no collection ran after it.
def test_exit_does_not_collect_garbage() -> None:
    result = run_sb(
        "--DRT-gcopt=profile:1",
        "-c",
        'imported!"core.memory".GC.profileStats.numCollections',
    )

    assert result.returncode == 0
    seen, summary = result.stdout.split("\n", 1)
    at_exit = re.search(r"Number of collections:\s+(\d+)", summary)
    assert at_exit is not None
    assert int(at_exit.group(1)) == int(seen)


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


def test_dub_option_loads_module_from_fetched_project(tmp_path: Path) -> None:
    file = tmp_path / "loaded.d"
    file.write_text(
        "import automem.vector;\n"
        "int loadedValue() { return 42; }\n",
        encoding="utf-8",
    )

    result = run_sb(
        "--dub",
        "automem@0.6.11",
        str(file),
        "-c",
        "loadedValue()",
        timeout_seconds=30,
    )

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


def run_sb(
    *args: str,
    input: str = "",
    timeout_seconds: int = TIMEOUT,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sb_path(), *args],
        input=input,
        capture_output=True,
        check=False,
        text=True,
        timeout=timeout_seconds,
        cwd=cwd,
        env=None if env is None else {**os.environ, **env},
    )


def sb_path() -> str:
    repl = os.path.join(os.getcwd(), "bin", "sb-repl")
    if not os.path.exists(repl):
        pytest.skip("bin/sb-repl does not exist; run `dub build -c sb-repl` first")

    return repl


def clean(text: str) -> str:
    return _ANSI_ESCAPE.sub("", text).replace("\r", "")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
