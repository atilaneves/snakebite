#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1"]
# ///

# End-to-end tests of the `bin/sb` command line. They start the built
# binary as a child process, so they live here and not in `bin/ut`.

import os
import re
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


# Compiled D runs the module destructors after `main`, and the output they
# write is flushed before the process ends.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_runs_after_main(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static ~this() { writeln("dtor"); }
        void main() { writeln("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["main", "dtor"]


# Within a module the destructors run in reverse declaration order. The
# thread-local ones of the main thread run before the shared ones.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructors_run_in_reverse_order(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static ~this() { writeln("shared 1"); }
        static ~this() { writeln("thread 1"); }
        shared static ~this() { writeln("shared 2"); }
        static ~this() { writeln("thread 2"); }
        void main() { writeln("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "main", "thread 2", "thread 1", "shared 2", "shared 1",
    ]


# A module's destructors run after those of every module that imports it:
# the reverse of the order its constructors ran.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructors_run_in_reverse_import_order(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "a_library.d",
        """
        module a_library;
        import std.stdio: writeln;
        shared static this() { writeln("library constructor"); }
        shared static ~this() { writeln("library destructor"); }
        """,
    )
    write(
        tmp_path / "app" / "b_main.d",
        """
        module b_main;
        import a_library;
        import std.stdio: writeln;
        shared static this() { writeln("main constructor"); }
        shared static ~this() { writeln("main destructor"); }
        void main() { writeln("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "library constructor", "main constructor", "main",
        "main destructor", "library destructor",
    ]


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_runs_after_main_throws(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static ~this() { writeln("dtor"); }
        void main() { throw new Exception("main failed"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert "main failed" in result.stderr
    assert guest_lines(result) == ["dtor"]


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_that_throws_fails_the_program(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static ~this() { writeln("not reached"); }
        shared static ~this() { throw new Exception("dtor failed"); }
        void main() { writeln("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert "dtor failed" in result.stderr
    assert guest_lines(result) == ["main"]


# A thread-local destructor runs on every thread that ends, and a joined
# thread has run it by the time `join` returns.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_thread_destructor_runs_when_thread_ends(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.thread: Thread;
        import std.stdio: writeln;
        static ~this() { writeln("thread destructor"); }
        void main() {
            auto thread = new Thread({ writeln("worker"); });
            thread.start;
            thread.join;
            writeln("main");
        }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "worker", "thread destructor", "main", "thread destructor",
    ]


# `bin/sb` runs the unittests, then `main`, then the module destructors.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_runs_after_unittests_and_main(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static ~this() { writeln("dtor"); }
        unittest { writeln("unittest"); }
        void main() { writeln("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["unittest", "main", "dtor"]


# Compiled D with `-unittest` runs the destructors even when a unittest
# failed, and `main` does not run.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_runs_after_failed_unittest(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static ~this() { writeln("dtor"); }
        unittest { assert(false, "unittest failed"); }
        void main() { writeln("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert "dtor" in guest_lines(result)
    assert "main" not in guest_lines(result)


def run_app(
    tmp_path: Path, backend: str,
) -> subprocess.CompletedProcess[str]:
    return run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )


# What the guest wrote to stdout, without the timing report `bin/sb` ends
# its output with.
def guest_lines(result: subprocess.CompletedProcess[str]) -> list[str]:
    return [
        line for line in result.stdout.splitlines()
        if not re.fullmatch(r"[a-z ]+:\s+[\d.]+ ms", line)
    ]


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


C_ROOT_SOURCE = """
#include <string.h>
struct Point { int x; int y; };
struct Point origin = {1, 2};
int numbers[3] = {4, 5, 6};
int total(int x) {
    int pair[2] = {x, 3};
    return pair[0] + pair[1] + (int) strlen("ab");
}
"""


# A C file is a root module of a dub project (`sourceFiles`): the C
# preprocessor runs on it, and its initialisers reach the backend. The
# native row is the same files built by dmd, whose own unittest run is the
# expected result.
@pytest.mark.parametrize("backend", ["native", "interpreter", "bytecode"])
@pytest.mark.parametrize(
    "total, expected_status", [(9, 0), (8, 1)], ids=["agrees", "disagrees"],
)
def test_c_root_module(
    tmp_path: Path, backend: str, total: int, expected_status: int,
) -> None:
    write(
        tmp_path / "app" / "dub.sdl",
        dub_project_recipe("c-root") + 'sourceFiles "source/lib.c"\n',
    )
    write(tmp_path / "app" / "source" / "lib.c", C_ROOT_SOURCE)
    write(
        tmp_path / "app" / "source" / "main.d",
        f"""
        module main;
        import lib;
        unittest {{
            assert(total(4) == {total});
            assert(origin.y == 2);
            assert(numbers[2] == 6);
        }}
        int main() {{ return 0; }}
        """,
    )

    if backend == "native":
        result = run_native(tmp_path / "app")
    else:
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image",
            str(tmp_path / "app"), cwd=tmp_path,
        )

    assert (result.returncode != 0) == (expected_status != 0), output(result)


def run_native(
    directory: Path,
    flags: list[str] | None = None,
    sources: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    program = directory / "native-program"
    build = subprocess.run(
        ["dmd", "-unittest", f"-of={program}", *(flags or []),
         *(sources or ["source/main.d", "source/lib.c"])],
        capture_output=True, check=False, text=True, cwd=directory,
    )
    assert build.returncode == 0, output(build)
    return subprocess.run(
        [str(program)], capture_output=True, check=False, text=True,
        cwd=directory,
    )


def run_backend(
    backend: str, directory: Path, cwd: Path, env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return run_sb(
        f"--backend={backend}", "--no-optimise-image", str(directory),
        cwd=cwd, env=env,
    )


# `-P` flags in `dflags` go to the C preprocessor, as `dmd -P` sends them:
# a macro and an include directory are the usual configuration of a C
# project.
@pytest.mark.parametrize("backend", ["native", "interpreter", "bytecode"])
@pytest.mark.parametrize(
    "expected, expected_status", [(1242, 0), (1243, 1)],
    ids=["agrees", "disagrees"],
)
def test_c_preprocessor_flags_from_dflags(
    tmp_path: Path, backend: str, expected: int, expected_status: int,
) -> None:
    flags = ["-P-DVALUE=42", "-P-Iinc"]
    app = tmp_path / "app"
    write(
        app / "dub.sdl",
        dub_project_recipe("c-flags")
        + 'sourceFiles "source/lib.c"\n'
        + "".join(f'dflags "{flag}"\n' for flag in flags),
    )
    write(app / "source" / "local.h", "#define LOCAL 200\n")
    write(app / "inc" / "outer.h", "#define OUTER 1000\n")
    write(
        app / "source" / "lib.c",
        """
        #include "local.h"
        #include "outer.h"
        #ifndef VALUE
        #define VALUE 1
        #endif
        int value(void) { return VALUE + LOCAL + OUTER; }
        """,
    )
    write(
        app / "source" / "main.d",
        f"""
        module main;
        import lib;
        unittest {{ assert(value() == {expected}); }}
        int main() {{ return 0; }}
        """,
    )

    if backend == "native":
        result = run_native(app, flags)
    else:
        result = run_backend(backend, app, tmp_path)

    assert (result.returncode != 0) == (expected_status != 0), output(result)


def write_unlisted_c_project(app: Path) -> None:
    write(app / "dub.sdl", dub_project_recipe("c-unlisted"))
    write(app / "source" / "lib.c", "int add(int a, int b) { return a + b; }\n")
    write(
        app / "source" / "main.d",
        """
        module main;
        import lib;
        unittest { assert(add(40, 2) == 42); }
        int main() { return 0; }
        """,
    )


# A dub build compiles the sources the recipe lists, and a C module that a D
# module imports but the recipe does not list is not one of them: the link
# fails, and a run must fail the same way, not succeed.
@pytest.mark.parametrize("backend", ["native", "interpreter", "bytecode"])
def test_imported_c_file_not_in_recipe_does_not_link(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write_unlisted_c_project(app)

    if backend == "native":
        result = subprocess.run(
            ["dub", "test", "-q", "--compiler=dmd"],
            capture_output=True, check=False, text=True, cwd=app,
        )
        assert "undefined reference" in output(result)
    else:
        result = run_backend(backend, app, tmp_path)
        assert "cannot resolve the symbol `add`" in output(result)

    assert result.returncode != 0, output(result)


# Without a recipe the build is `dmd -i`, which compiles the imported C
# file with the program.
@pytest.mark.parametrize("backend", ["native", "interpreter", "bytecode"])
def test_imported_c_file_in_bare_directory_links(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write(app / "lib.c", "int add(int a, int b) { return a + b; }\n")
    write(
        app / "main.d",
        """
        module main;
        import lib;
        unittest { assert(add(40, 2) == 42); }
        int main() { return 0; }
        """,
    )

    if backend == "native":
        build = subprocess.run(
            ["dmd", "-i", "-unittest", "-ofnative-program", "main.d"],
            capture_output=True, check=False, text=True, cwd=app,
        )
        assert build.returncode == 0, output(build)
        result = subprocess.run(
            [str(app / "native-program")], capture_output=True, check=False,
            text=True, cwd=app,
        )
    else:
        result = run_backend(backend, app, tmp_path)

    assert result.returncode == 0, output(result)


# A `main` in a C module is the entry of the process: druntime does not
# start, so no unittest runs, and the status is the one `main` returns.
@pytest.mark.parametrize("backend", ["native", "interpreter", "bytecode"])
def test_c_main_is_the_program_entry(tmp_path: Path, backend: str) -> None:
    app = tmp_path / "app"
    write(app / "dub.sdl", dub_project_recipe("c-main") + 'sourceFiles "source/lib.c"\n')
    write(
        app / "source" / "lib.c",
        """
        #include <stdio.h>
        int main(int argc, char **argv) {
            printf("c main %d\\n", argc);
            return 3;
        }
        """,
    )
    write(
        app / "source" / "main.d",
        """
        module app;
        import core.stdc.stdio: puts;
        unittest { puts("unittest ran"); }
        """,
    )

    if backend == "native":
        result = run_native(app, sources=["source/main.d", "source/lib.c"])
    else:
        result = run_backend(backend, app, tmp_path)

    assert result.returncode == 3, output(result)
    assert "c main 1" in result.stdout
    assert "unittest ran" not in output(result)


# One message says why the C file did not compile, however many times the
# frontend reaches for it.
@pytest.mark.parametrize("backend", ["interpreter", "bytecode"])
def test_missing_c_preprocessor_is_reported_once(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write(app / "dub.sdl", dub_project_recipe("c-no-cpp") + 'sourceFiles "source/lib.c"\n')
    write(app / "source" / "lib.c", "int add(int a, int b) { return a + b; }\n")
    write(app / "source" / "main.d", "module main;\nimport lib;\nunittest { assert(add(1, 2) == 3); }\n")

    result = run_backend(backend, app, tmp_path, {"CPPCMD": "/nonexistent/cpp"})

    assert result.returncode != 0, output(result)
    assert output(result).count("cannot run the C preprocessor") == 1
    assert "No such file or directory" in output(result)


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


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
