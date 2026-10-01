#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1"]
# ///

# End-to-end tests of the `bin/sb` command line. They start the built
# binary as a child process, so they live here and not in `bin/ut`.

import os
import stat
import subprocess
from pathlib import Path

import pytest

BACKENDS = ["interpreter", "bytecode", "ctfe"]

# CTFE cannot interpret `open64` from `std.file.readText`, which the
# guest programs of the tests that use this list call.
FILE_BACKENDS = ["bytecode", "interpreter"]


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_constructor_uses_project_directory(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "outside" / ".keep")
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("project-cwd"))
    write(tmp_path / "app" / "project-relative.txt", "ready\n")
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        import std.file: readText, write;
        private bool initialized;
        shared static this() {
            initialized = "project-relative.txt".readText == "ready\\n";
            "constructor-result.txt".write(initialized ? "yes" : "no");
        }
        unittest { "test-ran.txt".write("yes"); }
        int main() { return 0; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path / "outside",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "app" / "constructor-result.txt").read_text() == "yes"
    assert (tmp_path / "app" / "test-ran.txt").exists()


# `bin/sb` has no native instance of the druntime template that builds an
# associative array literal, unlike `bin/ut`, so a static initialiser's
# literal must run as guest code.
@pytest.mark.parametrize("backend", ["interpreter", "bytecode"])
def test_struct_field_assoc_array_initialiser(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("aa-field"))
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        struct S { int[string] m = ["a": 1]; }
        unittest { S s; assert(s.m["a"] == 1); }
        int main() { return 0; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )

    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("backend", ["interpreter", "bytecode"])
def test_immutable_assoc_array_literal(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("aa-immutable"))
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        immutable int[string] g = ["g": 7];
        unittest { assert(g["g"] == 7); }
        int main() { return 0; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )

    assert result.returncode == 0, result.stdout + result.stderr


# Guest code runs in the project directory, but snakebite's own state
# stays in the directory it was started from.
@pytest.mark.parametrize("backend", BACKENDS)
def test_state_directory_stays_in_caller_directory(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "outside" / ".keep")
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("state-cwd"))
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        int main() { return 0; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path / "outside",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "outside" / ".snakebite").exists()
    assert not (tmp_path / "app" / ".snakebite").exists()


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_dependency_constructor_uses_project_directory(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "outside" / ".keep")
    write(
        tmp_path / "app" / "dub.json",
        """
        {
            "name": "cwd-app",
            "targetType": "executable",
            "sourcePaths": ["source"],
            "importPaths": ["source"],
            "dependencies": {
                "cwd-dep": {"path": "../dependency"}
            },
            "configurations": [
                {"name": "unittest", "targetType": "executable"}
            ]
        }
        """,
    )
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        import dep;
        import std.file: readText;
        unittest {
            assert("dependency-constructor.txt".readText == "ran");
            assert(answer() == 42);
        }
        int main() { return 0; }
        """,
    )
    write(
        tmp_path / "dependency" / "dub.json",
        """
        {
            "name": "cwd-dep",
            "targetType": "library",
            "sourcePaths": ["source"],
            "importPaths": ["source"]
        }
        """,
    )
    write(
        tmp_path / "dependency" / "source" / "dep.d",
        """
        module dep;
        import std.file: write;
        shared static this() {
            write("dependency-constructor.txt", "ran");
        }
        int answer() { return 42; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path / "outside",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        tmp_path / "app" / "dependency-constructor.txt"
    ).read_text() == "ran"


@pytest.mark.parametrize("backend", BACKENDS)
def test_import_paths_stay_relative_to_caller(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "outside" / "imports" / "helper.d",
        "module helper;\nenum answer = 42;\n",
    )
    write(tmp_path / "outside" / "strings" / "payload.txt", "payload\n")
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import helper: answer;
        static assert(import("payload.txt") == "payload\\n");
        static assert(answer == 42);
        int main() { return 0; }
        """,
    )

    result = run_sb(
        f"--backend={backend}",
        "--import-path=imports",
        "--string-import-path=strings",
        str(tmp_path / "app"),
        cwd=tmp_path / "outside",
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_fetch_keeps_package_name(tmp_path: Path) -> None:
    fake_dub(
        tmp_path,
        'echo "fake dub received: $*"\n'
        "exit 1\n",
    )

    for backend in BACKENDS:
        result = run_with_fake_dub(
            tmp_path, f"--backend={backend}", "unit-threaded",
        )

        assert result.returncode == 1
        assert "fake dub received: fetch unit-threaded" in output(result)


# A package already in the local dub cache must resolve without
# `dub fetch`: without a version, fetch always asks the registry over the
# network.
def test_package_on_disk_does_not_fetch(tmp_path: Path) -> None:
    log = tmp_path / "dub.log"
    fake_dub(
        tmp_path,
        f'echo "$*" >> "{log}"\n'
        '[ "$1" = describe ] || exit 1\n'
        f'echo "{tmp_path / "packages" / "cached"}"\n',
    )

    run_with_fake_dub(tmp_path, "cached")

    assert log.read_text().splitlines() == [
        "describe cached --data=working-directory --data-list",
    ]


# A package missing from the local dub cache is fetched once, then
# described.
def test_package_missing_fetches_then_describes(tmp_path: Path) -> None:
    log = tmp_path / "dub.log"
    fetched = tmp_path / "fetched"
    fake_dub(
        tmp_path,
        f'echo "$*" >> "{log}"\n'
        f'if [ "$1" = fetch ]; then touch "{fetched}"; exit 0; fi\n'
        f'[ -e "{fetched}" ] || '
        '{ echo "Failed to find package locally."; exit 2; }\n'
        f'echo "{tmp_path / "packages" / "missing"}"\n',
    )

    run_with_fake_dub(tmp_path, "missing")

    assert log.read_text().splitlines() == [
        "describe missing --data=working-directory --data-list",
        "fetch missing",
        "describe missing --data=working-directory --data-list",
    ]


# A package that cannot be fetched reports what dub said about it.
def test_fetch_failure_reports_dub_output(tmp_path: Path) -> None:
    fake_dub(
        tmp_path,
        'echo "fake dub said: $1"\n'
        "exit 2\n",
    )

    result = run_with_fake_dub(tmp_path, "absent")

    assert result.returncode == 1
    assert (
        "snakebite: dub fetch failed for `absent`:\n"
        "fake dub said: fetch\n"
        "after dub describe failed:\n"
        "fake dub said: describe\n"
    ) in output(result)


# A dub recipe whose unittest configuration is an executable: dub's own
# synthetic unittest configuration would put a generated stub with its
# own `main` first, and a program takes the first root `main` it finds.
def dub_project_recipe(name: str) -> str:
    return (
        f'name "{name}"\ntargetType "library"\n'
        'configuration "unittest" {\n    targetType "executable"\n}\n'
    )


def write(path: Path, text: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def fake_dub(directory: Path, script_body: str) -> None:
    dub = directory / "bin" / "dub"
    write(dub, "#!/bin/sh\n" + script_body)
    dub.chmod(dub.stat().st_mode | stat.S_IXUSR)


# The fake dub goes on the child's PATH only, so no other process sees it.
def run_with_fake_dub(
    directory: Path, *args: str,
) -> subprocess.CompletedProcess[str]:
    outside = directory / "outside"
    outside.mkdir(exist_ok=True)
    path = f"{directory / 'bin'}:{os.environ.get('PATH', '')}"
    return run_sb(*args, cwd=outside, env={"PATH": path})


def output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def run_sb(
    *args: str,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout_seconds: int = 120,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sb_path(), *args],
        capture_output=True,
        check=False,
        text=True,
        timeout=timeout_seconds,
        cwd=cwd,
        env=None if env is None else {**os.environ, **env},
    )


def sb_path() -> str:
    sb = os.path.join(os.getcwd(), "bin", "sb")
    if not os.path.exists(sb):
        pytest.fail("bin/sb does not exist; run `ninja bin/sb` first")

    return sb


# A C `main` gets what the C runtime gives it, not the `string[]` of a D
# `main`: the argument count, the argument vector, and for the three-argument
# form the environment. A bare directory runs its own `main`.
C_MAINS = [
    ("no_parameters", "extern(C) int main() { return 0; }", ""),
    (
        "count_and_vector",
        """
        extern(C) int main(int argc, char** argv) {
            printf("argc %d\\n", argc);
            return argc == 1 && argv[0] !is null && argv[1] is null ? 0 : 3;
        }
        """,
        "argc 1",
    ),
    (
        "environment",
        """
        extern(C) int main(int argc, char** argv, char** envp) {
            printf("env %d\\n", envp !is null && envp[0] !is null);
            return argc == 1 && envp !is null ? 0 : 3;
        }
        """,
        "env 1",
    ),
]


@pytest.mark.parametrize("backend", ["bytecode", "interpreter"])
@pytest.mark.parametrize(
    "source,expected",
    [row[1:] for row in C_MAINS],
    ids=[row[0] for row in C_MAINS],
)
def test_bare_directory_c_main_gets_what_the_c_runtime_gives(
    tmp_path: Path, backend: str, source: str, expected: str,
) -> None:
    write(
        tmp_path / "app" / "app.d",
        "import core.stdc.stdio: printf;\n" + source,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )

    assert result.returncode == 0, output(result)
    assert expected in output(result)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
