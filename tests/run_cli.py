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
# Guest faults: code that compiled D kills with a signal. `bin/sb` ends
# with the message on stderr, `<file>(<line>): fatal: <message>`, and exit
# status 1. The cases of each kind of fault are in `bin/ut`, in-process;
# these need the real process.
FAULT_BACKENDS = ["interpreter", "bytecode"]


def run_program(
    tmp_path: Path, backend: str, code: str,
) -> subprocess.CompletedProcess[str]:
    write(tmp_path / "outside" / ".keep")
    write(tmp_path / "app" / "app.d", code)
    return run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path / "outside",
    )


@pytest.mark.parametrize("backend", FAULT_BACKENDS)
@pytest.mark.parametrize(
    "statement, message",
    [
        ("int* p; int x = *p;", "null pointer dereference"),
        ("int z = 0; int x = 5 / z;", "integer division by zero"),
    ],
)
def test_guest_fault_ends_the_process_with_a_message(
    tmp_path: Path, backend: str, statement: str, message: str,
) -> None:
    result = run_program(
        tmp_path, backend, "void main() {\n    " + statement + "\n}\n",
    )

    assert result.returncode == 1, output(result)
    assert f"app.d(2): fatal: {message}" in result.stderr.splitlines()


# The process dies as it does when compiled D gets the signal: no `finally`
# or `scope(exit)` runs, and no guest `catch` sees an exception.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_guest_fault_runs_no_guest_cleanup(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "import core.stdc.stdio: puts;\n"
        "int zero() { return 0; }\n"
        "void main() {\n"
        "    scope(exit) puts(\"scope exit ran\");\n"
        "    try {\n"
        "        try {\n"
        "            int x = 5 / zero();\n"
        "        } finally {\n"
        "            puts(\"finally ran\");\n"
        "        }\n"
        "    } catch (Throwable) {\n"
        "        puts(\"catch ran\");\n"
        "    }\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert "ran" not in output(result)


# Output that the guest wrote comes before the message, also a line with no
# newline: the host flushes what the guest left in its buffers.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_guest_fault_flushes_guest_output_first(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "import core.stdc.stdio: printf;\n"
        "void main() {\n"
        "    printf(\"before\\n\");\n"
        "    int* p;\n"
        "    *p = 1;\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert "before\n" in result.stdout


# The file in the message is the file of the faulting code.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_guest_fault_names_the_file_of_the_faulting_module(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "app" / "helper.d",
        "module helper;\n"
        "int target(int* p) {\n"
        "    return *p;\n"
        "}\n")
    result = run_program(
        tmp_path, backend,
        "import helper;\n"
        "void main() {\n"
        "    target(null);\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert "helper.d(3): fatal: null pointer dereference" in result.stderr


# The fault of a guest function that native code calls back is a fault of
# the guest too.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_guest_fault_in_a_native_callback_ends_the_process(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "import core.stdc.stdlib: qsort;\n"
        "extern(C) int compare(const(void)* a, const(void)* b) {\n"
        "    int* p;\n"
        "    return *p;\n"
        "}\n"
        "void main() {\n"
        "    int[2] values = [2, 1];\n"
        "    qsort(values.ptr, values.length, int.sizeof, &compare);\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(4): fatal: null pointer dereference"
        in result.stderr.splitlines()
    )


# An array operation divides element by element in native code of the
# dependency image: a zero element is the same hardware trap as a scalar
# division by zero, and it is reported at the statement.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
@pytest.mark.parametrize("statement", ["c[] = a[] / b[];", "a[] /= b[1];"])
def test_array_operation_division_by_zero_is_a_fault(
    tmp_path: Path, backend: str, statement: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        "    int[] a = [4, 6];\n"
        "    int[] b = [2, 0];\n"
        "    int[2] c;\n"
        f"    {statement}\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(5): fatal: integer division by zero"
        in result.stderr.splitlines()
    )


# The same trap for the other operators and element types: the elements are
# divided at the promoted type, as scalars are.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
@pytest.mark.parametrize(
    "type_, dividends, divisors, statement, message",
    [
        ("int", "[4, 6]", "[2, 0]", "c[] = a[] % b[];",
            "integer division by zero"),
        ("int", "[4, 6]", "[2, 0]", "a[] %= b[1];",
            "integer division by zero"),
        ("int", "[4, int.min]", "[2, -1]", "c[] = a[] / b[];",
            "integer overflow in division"),
        ("int", "[4, 6]", "[2, 0]", "c[] = 12 / b[];",
            "integer division by zero"),
        ("byte", "[4, 6]", "[2, 0]", "c[] = a[] / b[];",
            "integer division by zero"),
        ("ulong", "[4, 6]", "[2, 0]", "c[] = a[] / b[];",
            "integer division by zero"),
        ("long", "[4, long.min]", "[2, -1]", "c[] = a[] / b[];",
            "integer overflow in division"),
    ],
)
def test_array_operation_division_traps_as_the_scalar_division_does(
    tmp_path: Path, backend: str, type_: str, dividends: str, divisors: str,
    statement: str, message: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        f"    {type_}[] a = {dividends};\n"
        f"    {type_}[] b = {divisors};\n"
        f"    {type_}[2] c;\n"
        f"    {statement}\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert f"app.d(5): fatal: {message}" in result.stderr.splitlines()


# Elements whose division does not trap are no fault: the narrow types
# divide as `int`, and a floating point division never traps.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
@pytest.mark.parametrize(
    "type_, dividends, divisors",
    [
        ("short", "[short.min, 6]", "[-1, 1]"),
        ("ubyte", "[200, 6]", "[255, 1]"),
        ("uint", "[uint.max, 6]", "[uint.max, 1]"),
        ("double", "[4, 6]", "[2, 0]"),
    ],
)
def test_array_operation_division_that_does_not_trap_is_no_fault(
    tmp_path: Path, backend: str, type_: str, dividends: str, divisors: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        f"    {type_}[] a = {dividends};\n"
        f"    {type_}[] b = {divisors};\n"
        f"    {type_}[2] c;\n"
        "    c[] = a[] / b[];\n"
        "}\n",
    )

    assert result.returncode == 0, output(result)


# `synchronized (c)` locks the monitor of `c`, a field of the object.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_synchronized_on_a_null_class_reference_is_a_fault(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "class C { }\n"
        "void main() {\n"
        "    C c;\n"
        "    synchronized (c) {}\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(4): fatal: use of a null class reference"
        in result.stderr.splitlines()
    )


# A fault in a unittest run names the unittest that was running: the guest
# call stack follows the message.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_fault_in_unittest_names_the_unittest(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "app" / "helper.d",
        "module helper;\n"
        "int target(int* p) { return *p; }\n")
    result = run_program(
        tmp_path, backend,
        "module app;\n"
        "import helper;\n"
        "unittest {\n"
        "    target(null);\n"
        "}\n"
        "int main() { return 0; }\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "helper.d(2): fatal: null pointer dereference"
        in result.stderr.splitlines()
    )
    assert "in helper.target (helper.d(2))" in result.stderr
    assert "__unittest_L3_C1 (app.d(3))" in result.stderr


# A destructor that the collector runs is guest code too: its fault is
# reported as any other, with the message of the fault.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_guest_fault_in_a_finalizer_ends_the_process_with_a_message(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "import core.memory: GC;\n"
        "class C {\n"
        "    int* p;\n"
        "    ~this() { *p = 1; }\n"
        "}\n"
        "void make() { foreach (i; 0 .. 100) new C; }\n"
        "void main() {\n"
        "    int x;\n"
        "    int* q = &x;\n"
        "    *q = 1;\n"
        "    make();\n"
        "    GC.collect();\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(4): fatal: null pointer dereference"
        in result.stderr.splitlines()
    )


# The unittest is named also when native code is between it and the fault.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_fault_in_a_native_callback_names_the_unittest(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "import core.stdc.stdlib: qsort;\n"
        "extern(C) int compare(const(void)* a, const(void)* b) {\n"
        "    int* p;\n"
        "    return *p;\n"
        "}\n"
        "unittest {\n"
        "    int[2] values = [2, 1];\n"
        "    qsort(values.ptr, values.length, int.sizeof, &compare);\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert "in app.compare (app.d(2))" in result.stderr
    assert "__unittest_L6_C1 (app.d(6))" in result.stderr


# `p.length = n` writes the array that `p` points to.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_length_assignment_through_a_null_pointer_is_a_fault(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        "    int[]* p;\n"
        "    p.length = 3;\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(3): fatal: null pointer dereference"
        in result.stderr.splitlines()
    )


# `*p ~= c` appends to the array that `p` points to.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_append_through_a_null_pointer_is_a_fault(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        "    string* p;\n"
        "    *p ~= 'c';\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(3): fatal: null pointer dereference"
        in result.stderr.splitlines()
    )


# An operand of an array operation division can be the result of another
# operation of the same statement: its elements are divided in the same
# native loop, and the hardware trap is the same.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
@pytest.mark.parametrize(
    "statement, message",
    [
        ("c[] = a[] / (b[] - 1);", "integer division by zero"),
        ("c[] = a[] % (b[] - 1);", "integer division by zero"),
        ("c[] = (a[] - 4) / (b[] - 3);", "integer overflow in division"),
    ],
)
def test_array_operation_division_of_an_intermediate_result_is_a_fault(
    tmp_path: Path, backend: str, statement: str, message: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        "    int[] a = [int.min + 4, 6];\n"
        "    int[] b = [2, 1];\n"
        "    int[2] c;\n"
        f"    {statement}\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert f"app.d(5): fatal: {message}" in result.stderr.splitlines()


# An operand that is shorter than the result is the error of the array
# operation itself: no element after its end is divided.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
def test_array_operation_with_a_short_operand_is_not_a_division_fault(
    tmp_path: Path, backend: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        "void main() {\n"
        "    int[] a = [8, 6, 4, 2];\n"
        "    int[] wide = [2, 1, 0, 0, 5];\n"
        "    int[] b = wide[0 .. 2];\n"
        "    int[4] c;\n"
        "    c[] = a[] / b[];\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert "Mismatched array lengths for vector operation" in result.stderr
    assert "fatal:" not in result.stderr


# `0 ^^ -1` is `1 / 0` for integers: compiled D dies of SIGFPE.
@pytest.mark.parametrize("backend", FAULT_BACKENDS)
@pytest.mark.parametrize("type_", ["int", "long"])
def test_zero_to_a_negative_power_is_a_fault(
    tmp_path: Path, backend: str, type_: str,
) -> None:
    result = run_program(
        tmp_path, backend,
        f"{type_} zero() {{ return 0; }}\n"
        "void main() {\n"
        "    auto x = zero() ^^ (zero() - 1);\n"
        "}\n",
    )

    assert result.returncode == 1, output(result)
    assert (
        "app.d(3): fatal: integer division by zero"
        in result.stderr.splitlines()
    )


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
