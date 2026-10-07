#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1", "pytest-xdist==3.8.0"]
# ///

# End-to-end tests of the `bin/sb` command line. They start the built
# binary as a child process, so they live here and not in `bin/ut`.

import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import NamedTuple

import pytest
from dubname import delete_plain_dub_names, dub_name, forget_dub_names

pytest_plugins = ["pytester"]

BACKENDS = ["interpreter", "bytecode", "ctfe"]

# CTFE cannot interpret `open64` from `std.file.readText`, which the
# guest programs of the tests that use this list call.
FILE_BACKENDS = ["bytecode", "interpreter"]

# Whole-program tests also run `native`: the same files compiled by dmd, the
# reference compiler, and run as an executable. The expectations are what
# compiled D does, not what a backend happens to do.
PROGRAM_BACKENDS = ["native", *FILE_BACKENDS]


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


# A module destructor sees the directory that the constructors and `main`
# of the same program see.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_uses_project_directory(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "outside" / ".keep")
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("project-cwd"))
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        import std.file: write;
        shared static ~this() { "shared-destructor.txt".write("yes"); }
        static ~this() { "thread-destructor.txt".write("yes"); }
        int main() { return 0; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path / "outside",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "app" / "shared-destructor.txt").exists()
    assert (tmp_path / "app" / "thread-destructor.txt").exists()
    assert not (tmp_path / "outside" / "shared-destructor.txt").exists()
    assert not (tmp_path / "outside" / "thread-destructor.txt").exists()


# The report of the tool is about the run, so it comes after everything that
# the program prints, the module destructors included.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_timing_lines_follow_module_destructor_output(
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
    lines = result.stdout.splitlines()
    assert lines[:2] == ["main", "dtor"], output(result)
    assert all(is_timing_line(line) for line in lines[2:]), output(result)


# A program that has module constructors needs no compiler at run time: the
# registration of its modules is made from bytes that the build of the tool
# holds. The CTFE backend needs no image of the project's dependencies, so
# nothing else asks for a compiler.
def test_module_constructor_runs_without_a_compiler(tmp_path: Path) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        shared static this() { }
        shared static ~this() { }
        int main() { return 0; }
        """,
    )
    write(tmp_path / "no-compiler" / ".keep")

    result = run_sb(
        "--backend=ctfe", str(tmp_path / "app"),
        cwd=tmp_path, env={"PATH": str(tmp_path / "no-compiler")},
    )

    assert result.returncode == 0, output(result)


# The registration of the modules of a program needs no directory that the
# user can write to, or that can run programs.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_constructor_runs_with_a_read_only_temporary_directory(
    tmp_path: Path, backend: str,
) -> None:
    if os.geteuid() == 0:
        pytest.skip("root can write in a read-only directory")

    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static this() { writeln("constructor"); }
        void main() { writeln("main"); }
        """,
    )
    read_only = tmp_path / "read-only"
    read_only.mkdir()
    read_only.chmod(0o555)

    try:
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image",
            str(tmp_path / "app"),
            cwd=tmp_path, env={"TMPDIR": str(read_only)},
        )
    finally:
        read_only.chmod(0o755)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["constructor", "main"]


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_constructor_runs_with_a_no_exec_temporary_directory(
    tmp_path: Path, backend: str,
) -> None:
    unshare = shutil.which("unshare")
    if unshare is None:
        pytest.skip("unshare is not on PATH")

    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.stdio: writeln;
        shared static this() { writeln("constructor"); }
        void main() { writeln("main"); }
        """,
    )
    no_exec = tmp_path / "no-exec"
    no_exec.mkdir()
    script = (
        'mount -t tmpfs -o noexec tmpfs "$1" && TMPDIR="$1" exec "$2" '
        '--backend="$3" --no-optimise-image "$4"'
    )

    result = subprocess.run(
        [unshare, "--user", "--map-root-user", "--mount", "sh", "-c", script,
         "sh", str(no_exec), sb_path(), backend, str(tmp_path / "app")],
        capture_output=True, check=False, text=True, timeout=120,
        cwd=tmp_path,
    )

    if "unshare:" in result.stderr:
        pytest.skip("the system refuses a user and mount namespace")

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["constructor", "main"]


# A failure of snakebite itself in a module phase prints the message that the
# rest of the tool prints, not a stack trace of the host.
def test_host_failure_in_a_module_destructor_prints_a_message(
    tmp_path: Path,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        template T(int n) { shared static ~this() { } }
        alias A = T!1;
        int main() { return 0; }
        """,
    )

    result = run_app(tmp_path, "ctfe")

    assert result.returncode == 1, output(result)
    assert result.stderr.startswith("snakebite: "), output(result)
    assert "??:?" not in result.stderr, output(result)


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


# The `dub describe` record of a project that nothing changed since the
# first start holds on the second start. The state directory lies in the
# project directory here, which the record watches: creating it must not
# change what the record saw.
@pytest.mark.parametrize("backend", BACKENDS)
def test_second_start_does_not_describe_again(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write(app / "dub.sdl", dub_project_recipe("describe-once"))
    write(
        app / "source" / "main.d",
        """
        module main;
        int main() { return 0; }
        """,
    )
    real_dub = shutil.which("dub")
    assert real_dub is not None
    log = tmp_path / "dub.log"
    fake_dub(tmp_path, f'echo "$*" >> "{log}"\nexec "{real_dub}" "$@"\n')

    for _ in range(2):
        result = run_with_fake_dub_in(
            tmp_path, app, f"--backend={backend}", "--no-optimise-image", ".",
        )
        assert result.returncode == 0, output(result)

    describes = [
        line for line in log.read_text().splitlines()
        if line.split()[0] == "describe"
    ]
    assert len(describes) == 1, describes


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_dependency_constructor_uses_project_directory(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "outside" / ".keep")
    write(
        tmp_path / "app" / "dub.json",
        f"""
        {{
            "name": "{dub_name("cwd-app")}",
            "targetType": "executable",
            "sourcePaths": ["source"],
            "importPaths": ["source"],
            "dependencies": {{
                "{dub_name("cwd-dep")}": {{"path": "../dependency"}}
            }},
            "configurations": [
                {{"name": "unittest", "targetType": "executable"}}
            ]
        }}
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
        f"""
        {{
            "name": "{dub_name("cwd-dep")}",
            "targetType": "library",
            "sourcePaths": ["source"],
            "importPaths": ["source"]
        }}
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
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
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
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
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
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
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


@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
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


@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
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
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
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


# Compiled D with `-unittest` runs the unittests, not `main`, and then the
# module destructors.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_module_destructor_runs_after_unittests(
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
    assert guest_lines(result) == ["unittest", "dtor"]


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


# Compiled D orders the modules by import: all shared constructors, imported
# module first, then all thread-local constructors. The destructors run in
# the reverse order. The file names sort the importing module first, so
# source order is not import order.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_module_constructors_and_destructors_follow_import_order(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "a_main.d",
        """
        module a_main;
        import z_library;
        import std.stdio: writeln;
        shared static this() { writeln("main shared constructor"); }
        static this() { writeln("main thread constructor"); }
        shared static ~this() { writeln("main shared destructor"); }
        static ~this() { writeln("main thread destructor"); }
        void main() { writeln("main"); }
        """,
    )
    write(
        tmp_path / "app" / "z_library.d",
        """
        module z_library;
        import std.stdio: writeln;
        shared static this() { writeln("library shared constructor"); }
        static this() { writeln("library thread constructor"); }
        shared static ~this() { writeln("library shared destructor"); }
        static ~this() { writeln("library thread destructor"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "library shared constructor", "main shared constructor",
        "library thread constructor", "main thread constructor",
        "main",
        "main thread destructor", "library thread destructor",
        "main shared destructor", "library shared destructor",
    ]


# druntime refuses to start a program whose modules with constructors import
# each other: it cannot order them.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_cyclic_module_constructors_fail_the_program(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "first.d",
        """
        module first;
        import second;
        import std.stdio: writeln;
        shared static this() { writeln("first constructor"); }
        void main() { writeln("main"); }
        """,
    )
    write(
        tmp_path / "app" / "second.d",
        """
        module second;
        import first;
        import std.stdio: writeln;
        shared static this() { writeln("second constructor"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert (
        "Cyclic dependency between module constructors/destructors"
        in result.stderr
    )
    assert guest_lines(result) == []


# druntime waits for the threads that are not daemons after the main
# thread's thread-local destructors and before the shared destructors.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_shared_destructors_wait_for_other_threads(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.thread: Thread;
        import core.time: msecs;
        import std.stdio: writeln;
        shared static ~this() { writeln("shared destructor"); }
        static ~this() { writeln("thread destructor"); }
        void main() {
            new Thread({
                Thread.sleep(300.msecs);
                writeln("worker");
            }).start;
            writeln("main");
        }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "main", "thread destructor", "worker", "thread destructor",
        "shared destructor",
    ]


# A spawned thread learns that its owner ended from the main thread's
# thread-local destructor of `std.concurrency`. druntime runs that
# destructor before it waits for the thread, so the program ends.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_spawned_thread_ends_before_shared_destructors(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.concurrency: OwnerTerminated, receive, spawn;
        import std.stdio: writeln;
        shared static ~this() { writeln("shared destructor"); }
        void worker() {
            try
                receive((int value) {});
            catch (OwnerTerminated)
                writeln("owner terminated");
        }
        void main() {
            spawn(&worker);
            writeln("main");
        }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "main", "owner terminated", "shared destructor",
    ]


# Every thread that druntime starts runs the thread-local constructors and
# destructors, also a thread that calls no function of the program.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_thread_without_program_code_runs_thread_constructors(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import std.parallelism: TaskPool;
        import std.stdio: writeln;
        static this() { writeln("thread constructor"); }
        static ~this() { writeln("thread destructor"); }
        void main() {
            auto pool = new TaskPool(1);
            pool.finish(true);
            writeln("main");
        }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "thread constructor", "thread constructor", "thread destructor",
        "main", "thread destructor",
    ]


# druntime prints a throwable that leaves a destructor as it prints one that
# leaves `main`: the class name, the file and the line, then the message.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_module_destructor_exception_has_the_druntime_format(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        shared static ~this() { throw new Exception("dtor failed"); }
        void main() {}
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert re.match(
        r"object\.Exception@.*main\.d\(\d+\): dtor failed\n", result.stderr,
    ), result.stderr


# `Thread.join` gives the caller the exception that left a thread-local
# destructor of the thread it joined. `join(false)` returns it, where `join`
# throws it again.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_join_returns_thread_destructor_exception(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.thread: Thread;
        import std.stdio: writeln;
        bool isWorker;
        static ~this() { if (isWorker) throw new Exception("dtor failed"); }
        void main() {
            auto thread = new Thread({ isWorker = true; });
            thread.start;
            writeln("joined: ", thread.join(false).msg);
            writeln("main");
        }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["joined: dtor failed", "main"]
    assert result.stderr == ""


# The C `exit` ends a compiled D program through druntime's image
# finalizer: the thread-local destructors of the calling thread run, then
# the shared ones, and the status is the argument of `exit`.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_exit_runs_module_destructors(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdlib: exit;
        import std.stdio: stdout, writeln;
        shared static ~this() { writeln("shared destructor"); stdout.flush; }
        static ~this() { writeln("thread destructor"); stdout.flush; }
        void main() {
            writeln("main");
            stdout.flush;
            exit(5);
        }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 5, output(result)
    assert guest_lines(result) == [
        "main", "thread destructor", "shared destructor",
    ]


# A module's thread-local destructor runs before that of a module it
# imports, also when the imported module is in a compiled dependency and
# the thread is not the main thread.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_thread_destructor_runs_before_that_of_a_dependency(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "dub.sdl",
        f"""
        name "{dub_name("app")}"
        targetType "library"
        dependency "{dub_name("dep")}" path="../dep"
        """,
    )
    write(
        tmp_path / "app" / "source" / "logic.d",
        """
        module logic;
        import dep;
        import core.thread: Thread;
        import std.stdio: writeln;
        static ~this() { writeln("program destructor"); }
        unittest {
            use;
            auto thread = new Thread({ use; writeln("worker"); });
            thread.start;
            thread.join;
            writeln("joined");
        }
        """,
    )
    write(
        tmp_path / "dep" / "dub.sdl",
        f"""
        name "{dub_name("dep")}"
        targetType "library"
        """,
    )
    write(
        tmp_path / "dep" / "source" / "dep.d",
        """
        module dep;
        import std.stdio: writeln;
        static ~this() { writeln("dependency destructor"); }
        void use() {}
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert [
        line for line in guest_lines(result) if "modules passed" not in line
    ] == [
        "worker", "program destructor", "dependency destructor", "joined",
        "program destructor", "dependency destructor",
    ]


def run_app(
    tmp_path: Path, backend: str,
) -> subprocess.CompletedProcess[str]:
    if backend == "native":
        return run_native_app(tmp_path)

    return run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )


# The program in `app`, built and run as compiled D builds and runs it.
def run_native_app(tmp_path: Path) -> subprocess.CompletedProcess[str]:
    dmd = shutil.which("dmd")
    if dmd is None:
        pytest.skip("dmd, the reference compiler, is not on PATH")

    if (tmp_path / "app" / "dub.sdl").exists():
        return subprocess.run(
            ["dub", "test", "--compiler=dmd", "-q"],
            capture_output=True,
            check=False,
            text=True,
            timeout=120,
            cwd=tmp_path / "app",
        )

    executable = tmp_path / "native"
    sources = sorted(str(path) for path in (tmp_path / "app").glob("*.d"))
    compiled = subprocess.run(
        [dmd, "-unittest", f"-of={executable}", f"-od={tmp_path}", *sources],
        capture_output=True,
        check=False,
        text=True,
        timeout=120,
    )
    assert compiled.returncode == 0, output(compiled)

    return subprocess.run(
        [str(executable)],
        capture_output=True,
        check=False,
        text=True,
        timeout=120,
        cwd=tmp_path,
    )


# What the guest wrote to stdout, without the timing report `bin/sb` ends
# its output with.
def is_timing_line(line: str) -> bool:
    return re.fullmatch(r"[a-z ]+:\s+[\d.]+ ms", line) is not None


def guest_lines(result: subprocess.CompletedProcess[str]) -> list[str]:
    return [
        line for line in result.stdout.splitlines()
        if not is_timing_line(line)
    ]


# A `pragma(crt_constructor)` function runs before every module constructor,
# and a `pragma(crt_destructor)` function runs after every module destructor.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_functions_surround_the_module_phases(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        static ~this() { puts("thread destructor"); }
        shared static this() { puts("shared constructor"); }
        static this() { puts("thread constructor"); }
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "crt constructor", "shared constructor", "thread constructor",
        "main",
        "thread destructor", "shared destructor", "crt destructor",
    ]


# In a module the `crt_constructor` functions run in declaration order and
# the `crt_destructor` functions in the reverse order.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_functions_of_a_module_run_in_declaration_order(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void first() { puts("first"); }
        pragma(crt_destructor) void third() { puts("third"); }
        pragma(crt_constructor) void second() { puts("second"); }
        pragma(crt_destructor) void fourth() { puts("fourth"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "first", "second", "main", "fourth", "third",
    ]


# The `crt_constructor` functions of several modules run in the order of the
# modules on the command line, not in import order. The `crt_destructor`
# functions run in the reverse order.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_functions_of_modules_follow_module_order(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "a_main.d",
        """
        module a_main;
        import z_library;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void crtConstructor() { puts("main crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("main crt destructor"); }
        shared static this() { puts("main shared constructor"); }
        void main() { puts("main"); }
        """,
    )
    write(
        tmp_path / "app" / "z_library.d",
        """
        module z_library;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void crtConstructor() { puts("library crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("library crt destructor"); }
        shared static this() { puts("library shared constructor"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "main crt constructor", "library crt constructor",
        "library shared constructor", "main shared constructor",
        "main",
        "library crt destructor", "main crt destructor",
    ]


@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_functions_surround_the_unittests(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        unittest { puts("unittest"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert [
        line for line in guest_lines(result) if line != "main"
    ] == [
        "crt constructor", "unittest", "shared destructor", "crt destructor",
    ]


@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_exit_runs_crt_destructors(tmp_path: Path, backend: str) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        import core.stdc.stdlib: exit;
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        void main() { puts("main"); exit(5); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 5, output(result)
    lines = guest_lines(result)
    assert lines[:2] == ["crt constructor", "main"]
    assert sorted(lines[2:]) == ["crt destructor", "shared destructor"]


@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_destructor_runs_after_main_throws(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        void main() { puts("main"); throw new Exception("main failed"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert "main failed" in result.stderr
    assert guest_lines(result) == [
        "main", "shared destructor", "crt destructor",
    ]


# A failed module constructor skips the module destructors, but the
# `crt_destructor` functions still run: they do not belong to druntime.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_destructor_runs_after_a_failed_module_constructor(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        shared static this() { throw new Exception("constructor failed"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert "constructor failed" in result.stderr
    assert guest_lines(result) == ["crt constructor", "crt destructor"]


# A cycle between module constructors stops druntime before it runs a module
# constructor. The crt functions are not druntime's, so they still run.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_functions_run_when_module_constructors_have_a_cycle(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import other;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static this() { puts("main shared constructor"); }
        void main() { puts("main"); }
        """,
    )
    write(
        tmp_path / "app" / "other.d",
        """
        module other;
        import main;
        shared static this() {}
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert guest_lines(result) == ["crt constructor", "crt destructor"]


# `exit` in a `crt_constructor` function ends the program before druntime
# runs a module constructor, so no module destructor runs.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_exit_in_a_crt_constructor_runs_no_module_destructor(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        import core.stdc.stdlib: exit;
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); exit(3); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        static ~this() { puts("thread destructor"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 3, output(result)
    assert guest_lines(result) == ["crt constructor", "crt destructor"]


# Compiled D has no stable result here: the throw comes before druntime
# starts, so there is no GC for the exception. Only the backends have a row.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_crt_destructors_run_when_a_later_crt_constructor_throws(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_constructor) void first() { puts("first crt constructor"); }
        pragma(crt_constructor) void second() { throw new Exception("second failed"); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 1, output(result)
    assert "second failed" in result.stderr
    assert guest_lines(result) == ["first crt constructor", "crt destructor"]


# The functions of a template instance and of a mixin are crt functions of
# the module that instantiates them. The instance comes after the functions
# declared in the module.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_functions_of_a_template_instance_and_a_mixin_run(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        template Hook(string text) {
            pragma(crt_constructor) void hook() { puts(text.ptr); }
        }
        alias instance = Hook!"instance";
        mixin template Hooks() {
            pragma(crt_constructor) void mixed() { puts("mixin"); }
            pragma(crt_destructor) void mixedDestructor() { puts("mixin destructor"); }
        }
        mixin Hooks;
        pragma(crt_constructor) void declared() { puts("declared"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == [
        "mixin", "declared", "instance", "main", "mixin destructor",
    ]


@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_function_with_a_mangle_pragma_runs(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_constructor)
        pragma(mangle, "renamed_crt_constructor")
        extern(C) void crtConstructor() { puts("crt constructor"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["crt constructor", "main"]


# A thread-local variable that a `crt_constructor` function sets keeps its
# value on the main thread.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_constructor_sets_a_thread_local_variable(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: printf;
        int value = 5;
        pragma(crt_constructor) void crtConstructor() { value = 7; }
        static this() { printf("thread constructor %d\\n", value); }
        void main() { printf("main %d\\n", value); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 0, output(result)
    assert guest_lines(result) == ["thread constructor 7", "main 7"]


# A string import is not a lexer literal, so dmd gives it no zero code unit
# after the file's text unless the backend adds one. `native` is the compiled
# D that the two backends must agree with.
@pytest.mark.parametrize("backend", ["native", *FILE_BACKENDS])
def test_string_import_is_followed_by_zero(
    tmp_path: Path, backend: str,
) -> None:
    write(tmp_path / "strings" / "payload.txt", "payload")
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        unittest {
            immutable text = import("payload.txt");
            assert(text.length == 7);
            assert(text.ptr[text.length] == 0);
        }
        """,
    )

    if backend == "native":
        command = [
            "dmd", "-unittest", "-main", f"-J{tmp_path / 'strings'}", "-run",
            str(tmp_path / "app" / "main.d"),
        ]
        result = subprocess.run(
            command, capture_output=True, check=False, text=True,
            cwd=tmp_path, timeout=120,
        )
    else:
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image",
            "--string-import-path=strings", str(tmp_path / "app"),
            cwd=tmp_path,
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


# A fault of the guest ends the process with the signal that compiled D dies
# of, after one line on standard error. The faulting statement is not on the
# first line of its function: the line names the statement.
FAULTS = [
    ("null pointer read",
     "module main;\n"
     "int load(int* pointer) {\n"
     "    int unused = 1;\n"
     "    return *pointer;\n"
     "}\n"
     "int main() { int* pointer; return load(pointer); }\n",
     -signal.SIGSEGV, "fatal: null pointer dereference", "main.load"),
    ("integer division by zero",
     "module main;\n"
     "int divide(int dividend, int divisor) {\n"
     "    int unused = 1;\n"
     "    return dividend / divisor;\n"
     "}\n"
     "int main() { int zero; return divide(1, zero); }\n",
     -signal.SIGFPE, "fatal: integer division by zero or overflow",
     "main.divide"),
    ("call through a null function pointer",
     "module main;\n"
     "int call(int function() callee) {\n"
     "    int unused = 1;\n"
     "    return callee();\n"
     "}\n"
     "int main() { int function() callee; return call(callee); }\n",
     -signal.SIGSEGV, "fatal: null pointer dereference", "main.call"),
    ("call through a null delegate",
     "module main;\n"
     "int call(int delegate() callee) {\n"
     "    int unused = 1;\n"
     "    return callee();\n"
     "}\n"
     "int main() { int delegate() callee; return call(callee); }\n",
     -signal.SIGSEGV, "fatal: null pointer dereference", "main.call"),
    ("throw of a null reference",
     "module main;\n"
     "void raise(Throwable thrown) {\n"
     "    int unused = 1;\n"
     "    throw thrown;\n"
     "}\n"
     "int main() { Throwable thrown; raise(thrown); return 0; }\n",
     -signal.SIGSEGV, "fatal: null pointer dereference", "main.raise"),
]


@pytest.mark.parametrize("backend", FILE_BACKENDS)
@pytest.mark.parametrize(
    "source,status,message,function", [fault[1:] for fault in FAULTS],
    ids=[fault[0] for fault in FAULTS],
)
def test_guest_fault_ends_the_process_with_the_signal(
    tmp_path: Path, backend: str, source: str, status: int, message: str,
    function: str,
) -> None:
    write(tmp_path / "app" / "main.d", source)

    result = run_sb(f"--backend={backend}", str(tmp_path / "app"), cwd=tmp_path)

    assert result.returncode == status, output(result)
    position = f"main.d(4): {message}, in {function}"
    assert result.stderr == (
        position if backend == "interpreter" else message
    ) + "\n", output(result)


@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_virtual_call_on_null_receiver_evaluates_arguments_first(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        "module main;\n"
        "import core.stdc.stdio;\n"
        "class C { int value(int a) { return a; } }\n"
        "int side() { fprintf(stderr, \"side\\n\"); return 1; }\n"
        "int main() { C receiver; return receiver.value(side()); }\n",
    )

    result = run_sb(f"--backend={backend}", str(tmp_path / "app"), cwd=tmp_path)

    assert result.returncode == -signal.SIGSEGV, output(result)
    assert result.stderr.startswith("side\n"), output(result)


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


# The GC forbids an allocation while it runs a finalizer, so a guest
# destructor that allocates fails the way compiled D does. Each case runs in
# a process of its own: the error leaves the process that collected unsafe
# for the next test. CTFE cannot run `GC.collect`.
FINALIZER_BACKENDS = ["native", "interpreter", "bytecode"]


@pytest.mark.parametrize("backend", FINALIZER_BACKENDS)
@pytest.mark.parametrize(
    "destructor",
    [
        "auto p = new int; *p = 1;",
        "int[] a; a ~= 1; total += a.length;",
        "int x = dead; total += call(() => x);",
        'throw new Exception("boom");',
    ],
    ids=["new", "append", "closure", "throw-new"],
)
def test_destructor_that_allocates_fails_in_finalizer(
    tmp_path: Path, backend: str, destructor: str,
) -> None:
    source = f"""
        module main;
        __gshared int dead;
        __gshared long total;
        int call(int delegate() d) {{ return d(); }}
        class B {{ ~this() {{ {destructor} ++dead; }} }}
        pragma(inline, false) void make() {{
            foreach (n; 0 .. 2000)
                new B;
        }}
        unittest {{
            import core.memory: GC;
            make;
            GC.collect;
            GC.collect;
        }}
        int main() {{ return 0; }}
    """
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("finalizer"))
    write(tmp_path / "app" / "source" / "main.d", source)

    if backend == "native":
        result = subprocess.run(
            ["dmd", "-unittest", "-of=native", "source/main.d"],
            capture_output=True, check=False, text=True,
            cwd=tmp_path / "app",
        )
        assert result.returncode == 0, output(result)
        result = subprocess.run(
            [str(tmp_path / "app" / "native")],
            capture_output=True, check=False, text=True,
            cwd=tmp_path / "app",
        )
    else:
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image",
            str(tmp_path / "app"), cwd=tmp_path,
        )

    assert result.returncode != 0, output(result)
    assert "InvalidMemoryOperationError" in output(result)


# A destructor that throws an exception which exists already allocates
# nothing, and druntime reports the exception as a `FinalizeError`.
@pytest.mark.parametrize("backend", FINALIZER_BACKENDS)
def test_destructor_that_throws_existing_exception_gives_finalize_error(
    tmp_path: Path, backend: str,
) -> None:
    source = """
        module main;
        __gshared Exception existing;
        class B { ~this() { throw existing; } }
        pragma(inline, false) void make() {
            foreach (n; 0 .. 2000)
                new B;
        }
        unittest {
            import core.memory: GC;
            existing = new Exception("existing");
            make;
            GC.collect;
            GC.collect;
        }
        int main() { return 0; }
    """
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("finalizer"))
    write(tmp_path / "app" / "source" / "main.d", source)

    if backend == "native":
        result = subprocess.run(
            ["dmd", "-unittest", "-of=native", "source/main.d"],
            capture_output=True, check=False, text=True,
            cwd=tmp_path / "app",
        )
        assert result.returncode == 0, output(result)
        result = subprocess.run(
            [str(tmp_path / "app" / "native")],
            capture_output=True, check=False, text=True,
            cwd=tmp_path / "app",
        )
    else:
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image",
            str(tmp_path / "app"), cwd=tmp_path,
        )

    assert result.returncode != 0, output(result)
    assert "FinalizeError" in output(result)


# An opaque class has no size. Taking its type information must not crash.
# A native build does not link this program.
@pytest.mark.parametrize("backend", ["interpreter", "bytecode"])
def test_type_information_of_opaque_class(
    tmp_path: Path, backend: str,
) -> None:
    source = """
        module main;
        import core.stdc.stdio: printf;
        import core.stdc.stdlib: qsort;
        __gshared int never;
        extern(C++) class Opaque;
        __gshared Opaque opaque;
        int work(int x) {
            if (x == never + 12345) {
                Opaque[] all;
                all ~= opaque;
                x += cast(int) all.length;
            }
            return x + 1;
        }
        class C { int f(int x) { return work(x); } }
        extern(C) int cmp(const void* a, const void* b) {
            return work(*cast(int*) a) - work(*cast(int*) b);
        }
        unittest {
            auto c = new C;
            int[4] v = [4, 2, 3, 1];
            qsort(v.ptr, 4, 4, &cmp);
            printf("ok %d %d%d%d%d\\n", c.f(1), v[0], v[1], v[2], v[3]);
        }
        int main() { return 0; }
    """
    write(tmp_path / "app" / "dub.sdl", dub_project_recipe("opaque-class"))
    write(tmp_path / "app" / "source" / "main.d", source)

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image",
        str(tmp_path / "app"), cwd=tmp_path,
    )

    assert result.returncode == 0, output(result)
    assert "ok 2 1234" in output(result)


# What the GC finalizer needs from a destructor that compiled D allows: no
# allocation and no lock. Each shape is one construct in the destructor of a
# class. All the shapes of one backend run in one small process, where a
# collection is cheap, and the process of a defect that hangs ends at the
# timeout of `run_sb`. A shape is `(declarations, destructor body, statement
# that makes garbage, statement that collects)`; the last two have a default,
# and a body of `None` means that the declarations define the class `B`.
# 2000 dead objects are the deterministic form that a conservative GC allows:
# a stale stack word keeps at most a few alive.
class FinalizerShape(NamedTuple):
    declarations: str
    body: str | None = ""
    make: str = "new B;"
    collect: str = "GC.collect; GC.collect;"


FINALIZER_SHAPES: dict[str, tuple[str | None, ...]] = {
    "aaindex": (
        "__gshared int[int] aa; shared static this() { aa = [1: 1, 2: "
        "2]; }",
        "total += aa[2];",
    ),
    "aalookup": (
        '__gshared int[string] aa; shared static this() { aa = ["one": '
        '1, "two": 2]; }',
        'if (auto p = "two" in aa) total += *p; total += aa.length;',
    ),
    "aliasthis": (
        "struct W { int v; alias v this; }",
        "W w = W(3); int i = w; total += i;",
    ),
    "alloca_": (
        "import core.stdc.stdlib: alloca;",
        "auto p = cast(int*) alloca(16); *p = 3; total += *p;",
    ),
    "arrayops": (
        "",
        "int[4] a = [1,2,3,4]; int[4] b = [4,3,2,1]; int[4] c; c[] = "
        "a[] + b[]; total += c[0];",
    ),
    "arreq": (
        "__gshared int[] a1 = [1,2,3]; __gshared int[] a2 = [1,2,3];",
        "if (a1 == a2) total += 1; if (a1 < [9]) total += 0;",
    ),
    "arreq2": (
        "__gshared int[] a1 = [1,2,3]; __gshared int[] a2 = [1,2,3];",
        "if (a1 == a2) total += 1;",
    ),
    "asg_dbl": (
        "",
        "double d; d = 2.5; total += cast(long) d;",
    ),
    "asg_field": (
        "",
        "id = dead; total += 1;",
    ),
    "asg_gshared": (
        "__gshared int g;",
        "g = dead; total += 1;",
    ),
    "asg_index": (
        "__gshared int[4] g;",
        "g[1] = 2; total += g[1];",
    ),
    "asg_local": (
        "",
        "int a; a = dead; total += a + 1;",
    ),
    "asg_ptr": (
        "__gshared int g;",
        "int* p = &g; *p = 3; total += 1;",
    ),
    "asg_ref": (
        "",
        "Object o; o = this; total += o !is null;",
    ),
    "asg_str": (
        '__gshared string gs = "ab";',
        "string s; s = gs; total += s.length;",
    ),
    "asg_struct": (
        "struct P { int x, y; }",
        "P a = P(1, 2); P b; b = a; total += b.y;",
    ),
    "assertok": (
        "",
        'assert(dead >= 0, "neg"); total += 1;',
    ),
    "atomic": (
        "import core.atomic; shared int ctr;",
        'atomicOp!"+="(ctr, 1); total += atomicLoad(ctr);',
    ),
    "bitfield_class": (
        "class H { uint a : 3; uint b : 5; } __gshared H h; "
        "shared static this() { h = new H; }",
        "h.b = 9; total += h.b;",
    ),
    "bitfield_struct": (
        "struct F { uint a : 3; uint b : 5; } __gshared F gf;",
        "F f; f.a = 3; f.b = 9; total += f.a + f.b; gf.a = 1; ++gf.b;",
    ),
    "boundsok": (
        "__gshared int[] data = [1,2,3];",
        "total += data[dead % 3];",
    ),
    "breakfinally": (
        "",
        "foreach (i; 0 .. 3) { scope(exit) total += 1; if (i == 1) "
        "break; }",
    ),
    "callchain_loop": (
        "int inner(int n) { return n + 1; }\nint outer(int n) { return "
        "inner(n) + inner(n + 1); }",
        "int sum; foreach (i; 0 .. 10) sum += outer(i); total += sum;",
    ),
    "classinfo": (
        "",
        "total += this.classinfo.name.length;",
    ),
    "compare_strings": (
        '__gshared string name = "abc";',
        'if (name == "abc") ++total;',
    ),
    "contract": (
        "int f(int x) in (x >= 0) out (r; r > 0) { return x + 1; }",
        "total += f(dead);",
    ),
    "compound_fields": (
        "struct Owner { byte pad = 9; double d = 1.5; long l = 20; "
        "double run() { d += 0.5; l <<= 1; return d + l; } }",
        "Owner owner; auto result = owner.run; assert(result == 42.0); "
        "total += cast(long) result;",
    ),
    "inherited_class_contracts": (
        "class Base { int limit = 7; int f(int x) "
        "in { ++total; assert(x < limit); } "
        "out (r) { ++total; assert(r == x * limit); } "
        "do { return x * limit; } } "
        "class Derived: Base { override int f(int x) in (x > 0) "
        "do { return x * limit; } } __gshared Base target; "
        "shared static this() { target = new Derived; }",
        "auto before = total; auto result = target.f(3); "
        "assert(result == 21); assert(total == before + 2); "
        "total += result;",
    ),
    "inherited_interface_contracts": (
        "interface First { int a(); } interface Second { int f(int x) "
        "in { record(); assert(x == g()); } "
        "out (r) { record(); assert(r == g() * 2); } "
        "int g(); void record(); } class Impl: First, Second { "
        "int value = 7; int a() { return 1; } "
        "int g() { return value; } void record() { ++total; } "
        "int f(int x) in (x > 0) do { return x * 2; } } "
        "__gshared Second target; "
        "shared static this() { target = new Impl; }",
        "auto before = total; auto result = target.f(7); "
        "assert(result == 14); assert(total == before + 2); "
        "total += result;",
    ),
    "copyctor": (
        "struct P { int x; this(int v) { x = v; } this(ref return "
        "scope P o) { x = o.x + 1; } }",
        "P a = P(1); P b = a; total += b.x;",
    ),
    "cstring": (
        "import core.stdc.string: strlen, memcmp;",
        'total += strlen("hello") + (memcmp("ab".ptr, "ab".ptr, 2) == '
        "0);",
    ),
    "ctfeguard": (
        "int f(int x) { if (__ctfe) return x; return x + 1; }",
        "total += f(1);",
    ),
    "cvar": (
        "import core.stdc.stdarg; int sumv(int n, ...) { va_list ap; "
        "va_start(ap, n); int s; foreach (i; 0 .. n) s += "
        "va_arg!int(ap); va_end(ap); return s; }",
        "total += sumv(3, 1, 2, 3);",
    ),
    "delegfield": (
        "struct Cb { int delegate(int) d; } __gshared Cb cb; class Tgt "
        "{ int k = 2; int m(int x) { return x * k; } } shared static "
        "this() { cb.d = &(new Tgt).m; }",
        "total += cb.d(3);",
    ),
    "dgcall": (
        "class T { int m(int x) { return x + 1; } } __gshared int "
        "delegate(int) dg; shared static this() { dg = &(new T).m; }",
        "total += dg(1);",
    ),
    "dowhile": (
        "",
        "int i; do { ++i; } while (i < 4); while (i > 0) { --i; total "
        "+= 1; }",
    ),
    "dstring": (
        "",
        'wstring w = "ab"w; dstring d = "abc"d; total += w.length + '
        'd.length; foreach (dchar c; "hé") total += 1;',
    ),
    "dyncast": (
        "class X {} class Y : X { int v = 4; } __gshared X gx; shared "
        "static this() { gx = new Y; }",
        "if (auto y = cast(Y) gx) total += y.v;",
    ),
    "enumval": (
        "enum Color : ubyte { r = 1, g, b } enum table = [1, 2, 3];",
        "Color c = Color.g; total += c;",
    ),
    "finalswitch": (
        "enum E { a, b, c } int pick(E e) { final switch (e) with (E) "
        "{ case a: return 1; case b: return 2; case c: return 3; } }",
        "total += pick(cast(E)(dead % 3));",
    ),
    "floatm": (
        "import core.stdc.math: sqrt;",
        "double d = sqrt(16.0) * 1.5; total += cast(long) d;",
    ),
    "fnptr2": (
        "int f1(int x) { return x + 1; } __gshared int function(int) "
        "fp = &f1;",
        "total += fp(1); auto q = &f1; total += q(2);",
    ),
    "fnptrcall": (
        "int f1(int x) { return x + 1; } __gshared int function(int) "
        "fp; shared static this() { fp = &f1; }",
        "total += fp(1);",
    ),
    "forloop": (
        "",
        "for (int i = 0; i < 3; i++) total += i + 1;",
    ),
    "gcquery": (
        "import core.memory: GC;",
        "total += 1; auto p = cast(void*) this; total += (p !is null);",
    ),
    "gotocase": (
        "",
        "switch (dead & 1) { case 0: total += 1; goto case 1; case 1: "
        "total += 1; break; default: }",
    ),
    "gotofinally": (
        "",
        "foreach (i; 0 .. 2) { try { if (i == 1) goto done; } finally "
        "{ total += 1; } } done:",
    ),
    "gotolbl": (
        "",
        "int i; again: ++i; if (i < 3) goto again; outer: foreach (a; "
        "0 .. 3) foreach (b; 0 .. 3) { if (b == 1) continue outer; if "
        "(a == 2) break outer; total += 1; } total += i;",
    ),
    "guest_callback_to_native": (
        "import core.stdc.stdlib: qsort;\nextern(C) int compare(const "
        "void* a, const void* b) { return *cast(int*) a - *cast(int*) "
        "b; }",
        "int[3] values = [3, 1, 2]; qsort(values.ptr, 3, int.sizeof, "
        "&compare); total += values[0];",
    ),
    "idcompare": (
        "",
        "Object o = this; if (o is this) total += 1; if (o !is null) "
        "total += 1;",
    ),
    "iface": (
        "interface I { int f(); } final class K : I { int f() { return "
        "3; } } __gshared I gi; shared static this() { gi = new K; }",
        "total += gi.f;",
    ),
    "immtable": (
        "static immutable int[5] table = [10, 20, 30, 40, 50]; static "
        'immutable string[3] names = ["a", "bb", "ccc"];',
        "total += table[dead % 5] + names[dead % 3].length;",
    ),
    "incfield": (
        "",
        "++id; id += 2; total += id;",
    ),
    "init_only": (
        "",
        "int a = dead; Object o = this; total += a + 1;",
    ),
    "interface_call": (
        "interface I { int value(); }\nclass Impl : I { int value() { "
        "return 2; } }\n__gshared Impl impl;\nshared static this() { "
        "impl = new Impl; }",
        "I i = impl; total += i.value;",
    ),
    "invariant_": (
        "class Inv { int v = 1; invariant { assert(v == 1); } int "
        "get() { return v; } } __gshared Inv gi; shared static this() "
        "{ gi = new Inv; }",
        "total += gi.get;",
    ),
    "lazyp": (
        "int pick(bool b, lazy int v) { return b ? v : 0; }",
        "total += pick(true, dead + 1);",
    ),
    "memberdtor": (
        "struct M { int v = 3; ~this() { total += v; } } class H { M "
        "m; ~this() { total += 1; } } __gshared int made; void mk() { "
        "foreach (i; 0 .. 10) new H; }",
        "total += 1;",
    ),
    "memfnptr": (
        "struct S { int v; int get() { return v; } }",
        "S s = S(7); auto d = &s.get; total += d();",
    ),
    "memset_": (
        "import core.stdc.string: memset;",
        "ubyte[16] b = void; memset(b.ptr, 1, 16); total += b[3];",
    ),
    "nested_function": (
        "",
        "int n = 2; int inner() { return n + 1; } total += inner();",
    ),
    "nestedclass": (
        "class Outer { int v = 2; class Inner { int get() { return v; "
        "} } Inner mk() { return new Inner; } } __gshared Outer.Inner "
        "gin; shared static this() { gin = (new Outer).mk; }",
        "total += gin.get;",
    ),
    "nesteddg": (
        "int apply(scope int delegate(int) d) { return d(2); }",
        "int base = 5; int add(int x) { return x + base; } total += "
        "apply(&add);",
    ),
    "neststruct": (
        "struct In { int v; ~this() { total += v; } } struct Out { In "
        "a; In b; ~this() { total += 1; } }",
        "{ auto o = Out(In(1), In(2)); }",
    ),
    "opapply": (
        "struct C { int opApply(scope int delegate(int) d) { foreach "
        "(i; 0 .. 3) if (auto r = d(i + 1)) return r; return 0; } }",
        "C c; foreach (x; c) total += x;",
    ),
    "opassign": (
        "struct P { int x; void opAssign(P o) { x = o.x + 1; } }",
        "P a = P(1); P b; b = a; total += b.x;",
    ),
    "placement": (
        "struct P { int x; this(int v) { x = v; } }",
        "P s = void; new (s) P(3); total += s.x;",
    ),
    "postblit": (
        "struct P { int x; this(this) { total += 1; } ~this() { total "
        "+= 1; } } P same(P p) { return p; }",
        "P a = P(1); P b = a; P c = same(b); total += c.x;",
    ),
    "ptrarith": (
        "__gshared int[4] g = [1,2,3,4];",
        "auto p = g.ptr; p += 2; total += *p + p[-1];",
    ),
    "ptrfield": (
        "struct N { int v; } __gshared N gn;",
        "auto p = &gn; p.v = 4; total += p.v;",
    ),
    "ptrmember": (
        "struct N { int v; N* next; } __gshared N* head; shared static "
        "this() { head = new N(1, new N(2, null)); }",
        "for (auto n = head; n; n = n.next) total += n.v;",
    ),
    "rangefe": (
        "struct R { int i, n; bool empty() const { return i >= n; } "
        "int front() const { return i; } void popFront() { ++i; } }",
        "foreach (x; R(1, 5)) total += x;",
    ),
    "refout": (
        "ref int pick(return ref int a) { return a; } void setit(out "
        "int o) { o = 4; }",
        "int a = 1; pick(a) += 2; int o; setit(o); total += a + o;",
    ),
    "retfinally": (
        "int g(int i) { try { if (i) return 1; } finally { total += 1; "
        "} return 0; }",
        "total += g(1);",
    ),
    "retstruct": (
        "struct P { int x, y; } P mk(int a) { P p; p.x = a; p.y = a; "
        "return p; }",
        "total += mk(2).y;",
    ),
    "sarr": (
        "",
        "int[8] a = [1,2,3,4,5,6,7,8]; int[8] b = a; b[] += 2; foreach "
        "(x; b) total += x;",
    ),
    "scopeclass": (
        "class Q { int v = 2; ~this() { total += 1; } }",
        "scope q = new Q; total += q.v;",
    ),
    "scopeguards": (
        "",
        "scope(exit) total += 1; scope(success) total += 1; { "
        "scope(failure) total += 100; total += 1; }",
    ),
    "slices": (
        "__gshared int[] data = [1,2,3,4,5,6];",
        "auto s = data[1 .. 4]; foreach (x; s) total += x; total += "
        "s.length;",
    ),
    "snprintf": (
        "import core.stdc.stdio: snprintf;",
        'char[32] buf; total += snprintf(buf.ptr, buf.length, "%d-%s", '
        'dead, "x".ptr);',
    ),
    "staticctor": (
        "__gshared int gs; int tl; static this() { tl = 5; }",
        "total += 1;",
    ),
    "staticlocal": (
        "int next() { static int n; return ++n; } int nextg() { "
        "__gshared int n; return ++n; }",
        "total += next + nextg;",
    ),
    "stdalgo": (
        "import std.algorithm.comparison: max, min;",
        "total += max(1, min(5, dead + 2));",
    ),
    "strswitch": (
        '__gshared string key = "beta"; int sw(string s) { switch (s) '
        '{ case "alpha": return 1; case "beta": return 2; default: '
        "return 0; } }",
        "total += sw(key);",
    ),
    "base_class": (
        "class Base { ~this() { ++total; } } "
        "class B : Base { ~this() { ++dead; } }",
        None,
    ),
    "collecting_thread": (
        "",
        "++total;",
        "new B;",
        "import core.thread: Thread; auto collector = new Thread({ "
        "GC.collect; GC.collect; }); collector.start; collector.join;",
    ),
    "heap_struct": (
        "struct S { int value; ~this() { ++total; ++dead; } }",
        None,
        "auto s = new S(1); assert(s.value == 1);",
    ),
    "struct_field": (
        "struct Part { ~this() { ++total; } } "
        "class B { Part part; ~this() { ++dead; } }",
        None,
    ),
    "thread_local_first_touch": (
        "int threadLocalDead;",
        "++threadLocalDead; ++total;",
    ),
    "struct_array": (
        "struct S { int value; ~this() { ++total; ++dead; } }",
        None,
        "auto array = new S[4]; assert(array.length == 4);",
    ),
    "struct_locals_with_destructors": (
        "struct S { int value; ~this() { ++total; } }",
        "S[3] locals; total += locals[0].value;",
    ),
    "structeq": (
        "struct P { int x; string s; }",
        'auto a = P(1, "q"); auto b = P(1, "q"); if (a == b) total += '
        "1;",
    ),
    "structmethodtmpl": (
        'struct V { int x; V opBinary(string op : "+")(V o) { return '
        "V(x + o.x); } int opIndex(size_t i) { return x + cast(int) i; "
        "} int opCall(int k) { return x * k; } }",
        "auto v = V(1) + V(2); total += v[1] + v(2);",
    ),
    "superdtor": (
        "class Base { ~this() { total += 1; } } class D2 : Base { "
        "~this() { total += 2; } } void more() { foreach (i; 0 .. 4) "
        "new D2; } shared static this() { more; }",
        "total += 1;",
    ),
    "ternary": (
        "",
        "total += dead > 5 ? 1 : 2;",
    ),
    "ternstr": (
        '__gshared string s1 = "a", s2 = "bc";',
        "auto s = dead % 2 ? s1 : s2; total += s.length; if (s is s1) "
        'total += 1; if (s == "bc") total += 1;',
    ),
    "tlsstruct": (
        "struct T { int a; long b; } T tl;",
        "++tl.a; total += tl.a;",
    ),
    "tlsvar": (
        "int tl; static this() { tl = 0; }",
        "++tl; total += tl;",
    ),
    "tmplfirst": (
        "T twice(T)(T x) { return x + x; } T pick(T)(T a, T b) { "
        "return a > b ? a : b; }",
        "total += twice(3L) + pick!short(1, 2);",
    ),
    "tohash": (
        "",
        "total += (hashOf(dead) & 1) + 1;",
    ),
    "trycatch_scopeexit": (
        "",
        "scope(exit) ++total; try { if (total < 0) throw new "
        'Exception("never"); } catch (Exception) { }',
    ),
    "typeidname": (
        "",
        "total += typeid(this).name.length;",
    ),
    "typesafevar": (
        "int sum(int[] xs...) { int s; foreach (x; xs) s += x; return "
        "s; }",
        "total += sum(1, 2, 3);",
    ),
    "union_": (
        "union U { int i; float f; ubyte[4] b; }",
        "U u; u.f = 1.0f; total += u.b[3];",
    ),
    "whileasg": (
        "",
        "int i = 3; while (i) { i = i - 1; total += 1; }",
    ),
    "withstmt": (
        "struct P { int x, y; }",
        "P p = P(1, 2); with (p) total += x + y;",
    ),
    "write_gshared": (
        "",
        "total += 1;",
    ),
}


def finalizer_shape_source(name: str, value: tuple[str | None, ...]) -> str:
    shape = FinalizerShape(*value)
    destructor = "" if shape.body is None else f"""
        class B {{
            int id;
            ~this() {{ {shape.body} ++dead; }}
        }}"""
    return f"""
        module shape_{name};
        __gshared int dead;
        __gshared long total;
        {shape.declarations}{destructor}
        pragma(inline, false) void make() {{
            foreach (n; 0 .. 2000) {{
                {shape.make}
            }}
        }}
        public bool finalizes() {{
            import core.memory: GC;
            make;
            {shape.collect}
            return dead > 1000 && total > 0;
        }}
    """


# Runs the named shapes in one process. A hang gives the output that the
# process had written so far, marked as a timeout.
def run_finalizer_shapes(
    backend: str, names: list[str], app: Path,
) -> tuple[str, bool]:
    write(app / "dub.sdl", dub_project_recipe("finalizer"))
    for name in names:
        write(
            app / "source" / f"shape_{name}.d",
            finalizer_shape_source(name, FINALIZER_SHAPES[name]),
        )
    imports = "".join(f"import shape_{name};\n" for name in names)
    reports = "".join(
        f'fprintf(stderr, "{name} %s\\n", shape_{name}.finalizes '
        '? "ok".ptr : "failed".ptr);\n'
        for name in names
    )
    write(
        app / "source" / "main.d",
        "module main;\nimport core.stdc.stdio: fprintf, stderr;\n"
        + imports + "unittest {\n" + reports + "}\nint main() { return 0; }\n",
    )

    try:
        if backend == "native":
            result = subprocess.run(
                ["dmd", "-unittest", "-of=native", *sorted(
                    str(path.relative_to(app))
                    for path in (app / "source").glob("*.d")
                )],
                capture_output=True, check=False, text=True, cwd=app,
            )
            assert result.returncode == 0, output(result)
            result = subprocess.run(
                [str(app / "native")], capture_output=True, check=False,
                text=True, cwd=app, timeout=FINALIZER_TIMEOUT_SECONDS,
            )
        else:
            result = run_sb(
                f"--backend={backend}", "--no-optimise-image", str(app),
                cwd=app.parent, timeout_seconds=FINALIZER_TIMEOUT_SECONDS,
            )
    except subprocess.TimeoutExpired as timeout:
        def decoded(data: str | bytes | None) -> str:
            if data is None:
                return ""
            return data if isinstance(data, str) else data.decode(
                errors="replace")

        return (
            decoded(timeout.stdout) + decoded(timeout.stderr)
            + f"\ntimed out after {FINALIZER_TIMEOUT_SECONDS} s\n"
        ), False
    return output(result), True


FINALIZER_TIMEOUT_SECONDS = 300


class FinalizerShapes:
    def __init__(self, backend: str, root: Path) -> None:
        self.backend = backend
        self._root = root
        self._alone: dict[str, str] = {}
        self.text, self.completed = run_finalizer_shapes(
            backend, list(FINALIZER_SHAPES), root / "all" / "app",
        )

    # The combined run is the fast path. When it did not finish, a shape
    # without a report runs alone, so that one defect makes one test red.
    def verdict(self, shape: str) -> str:
        lines = self.text.splitlines()
        if f"{shape} ok" in lines or f"{shape} failed" in lines:
            return self.text
        if self.completed:
            return self.text
        if shape not in self._alone:
            self._alone[shape], _ = run_finalizer_shapes(
                self.backend, [shape], self._root / shape / "app",
            )
        return self._alone[shape]


@pytest.fixture(scope="module", params=FINALIZER_BACKENDS)
def finalizer_shapes(
    request: pytest.FixtureRequest, tmp_path_factory: pytest.TempPathFactory,
) -> FinalizerShapes:
    return FinalizerShapes(
        request.param,
        tmp_path_factory.mktemp(f"finalizer-{request.param}"),
    )


@pytest.mark.xdist_group("finalizer-shapes")
@pytest.mark.parametrize("shape", sorted(FINALIZER_SHAPES))
def test_destructor_shape_runs_in_finalizer(
    finalizer_shapes: FinalizerShapes, shape: str,
) -> None:
    text = finalizer_shapes.verdict(shape)

    assert f"{shape} ok" in text.splitlines(), (
        f"{finalizer_shapes.backend}:\n{text[-3000:]}"
    )


# A dub recipe whose unittest configuration is an executable: dub's own
# synthetic unittest configuration would put a generated stub with its
# own `main` first, and a program takes the first root `main` it finds.
def dub_project_recipe(name: str) -> str:
    return (
        f'name "{dub_name(name)}"\ntargetType "library"\n'
        'configuration "unittest" {\n    targetType "executable"\n}\n'
    )


# A throw from a `crt_destructor` function makes the program fail. Compiled D
# aborts there, so only the backends have a row.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_throw_from_a_crt_destructor_fails_the_program(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        pragma(crt_destructor) void crtDestructor() { throw new Exception("destructor failed"); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert "destructor failed" in result.stderr
    assert result.returncode == 1, output(result)


def write_cpp_exception_project(tmp_path: Path) -> None:
    write(
        tmp_path / "app" / "dub.sdl",
        dub_project_recipe("cpp-exception")
        + f'dependency "{dub_name("cpp-exception-dep")}"'
        + ' path="../dependency"\n',
    )
    write(
        tmp_path / "app" / "source" / "main.d",
        """
        module main;
        import core.stdc.stdio: fflush, printf, stdout;
        import dep: throwsFromCpp;
        int main() {
            printf("about to throw\\n");
            fflush(stdout);
            try {
                throwsFromCpp;
            } catch (Throwable) {
                printf("caught\\n");
                return 3;
            }
            return 0;
        }
        """,
    )
    write(
        tmp_path / "dependency" / "dub.sdl",
        f'name "{dub_name("cpp-exception-dep")}"\n'
        'targetType "staticLibrary"\n'
        'preBuildCommands "c++ -c -fPIC $PACKAGE_DIR/throws.cpp'
        ' -o $PACKAGE_DIR/throws.o"\n'
        'sourceFiles "throws.o"\nlibs "stdc++"\n',
    )
    write(
        tmp_path / "dependency" / "throws.cpp",
        """
        #include <stdexcept>
        void throwsFromCpp() { throw std::runtime_error("boom"); }
        """,
    )
    write(
        tmp_path / "dependency" / "source" / "dep.d",
        "module dep;\nextern(C++) void throwsFromCpp();\n",
    )


# A C++ exception that unwinds past every frame of the program ends the
# process as it ends compiled D: nothing catches or translates it, and a D
# `catch (Throwable)` never matches a foreign exception. Compiled D dies of
# `SIGABRT` here, and only a process shows that. The dependency compiles its
# own C++ source into an object file that the image links.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_cpp_exception_terminates_the_process_uncaught(
    tmp_path: Path, backend: str,
) -> None:
    if shutil.which("c++") is None:
        pytest.skip("no C++ compiler is on PATH")

    write_cpp_exception_project(tmp_path)

    result = run_app(tmp_path, backend)

    assert "about to throw" in result.stdout, output(result)
    assert "caught" not in result.stdout, output(result)
    assert "std::runtime_error" in result.stderr, output(result)
    assert result.returncode == -signal.SIGABRT, output(result)


# A library that a dependency names must follow the objects that need it on
# the link line: a linker that resolves in order, such as GNU ld with
# `--as-needed`, drops it otherwise. `CC` forces that linker here, whatever
# the machine's default is.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_dependency_library_is_linked_after_the_objects_that_need_it(
    tmp_path: Path, backend: str,
) -> None:
    if shutil.which("c++") is None:
        pytest.skip("no C++ compiler is on PATH")
    if shutil.which("ld.bfd") is None:
        pytest.skip("no GNU ld on PATH")

    write_cpp_exception_project(tmp_path)
    cc = tmp_path / "order-sensitive-cc"
    write(
        cc,
        "#!/bin/sh\n"
        'exec cc -fuse-ld=bfd -Wl,--as-needed "$@"\n',
    )
    cc.chmod(0o755)

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path, env={"CC": str(cc)},
    )

    assert "about to throw" in result.stdout, output(result)
    assert "linking failed" not in result.stderr, output(result)


# `exit` in a module destructor ends druntime's destructor phase. The
# `crt_destructor` functions are not druntime's, so they still run.
@pytest.mark.parametrize("backend", PROGRAM_BACKENDS)
def test_crt_destructor_runs_after_exit_in_a_module_destructor(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "main.d",
        """
        module main;
        import core.stdc.stdio: puts;
        import core.stdc.stdlib: exit;
        pragma(crt_constructor) void crtConstructor() { puts("crt constructor"); }
        pragma(crt_destructor) void crtDestructor() { puts("crt destructor"); }
        shared static ~this() { puts("shared destructor"); exit(5); }
        void main() { puts("main"); }
        """,
    )

    result = run_app(tmp_path, backend)

    assert result.returncode == 5, output(result)
    assert guest_lines(result) == [
        "crt constructor", "main", "shared destructor", "crt destructor",
    ]


# A guest program that calls a native dependency: the dependency's template
# instances and functions are built into an image the backends call, and
# each shape states what the program's `main` returns. A shape without
# `imports` is a dub project in `app`; with `imports` it is a bare `app`
# directory that imports from `deps`. `optimised` leaves the image
# optimisation on, which is the default of `bin/sb`.
class ImageShape(NamedTuple):
    files: dict[str, str | Callable[[], str]]
    backends: tuple[str, ...] = tuple(BACKENDS)
    imports: bool = False
    optimised: bool = False
    status: int = 0
    arguments: tuple[str, ...] = ()


def dub_app_recipe(name: str, settings: str = "") -> str:
    return (
        f'name "{dub_name(name)}"\ntargetType "library"\n{settings}'
        'configuration "unittest" {\n    targetType "executable"\n}\n'
    )


def dub_library(name: str) -> Callable[[], str]:
    return lambda: f'name "{dub_name(name)}"\ntargetType "library"\n'


def dub_dependency(name: str) -> str:
    return f'dependency "{dub_name(name)}" path="../dependency"\n'


def snippet_shape(code: str, result: int, backends: tuple[str, ...]) -> ImageShape:
    return ImageShape(
        {
            "app/root.d": (
                "module root;\n" + code
                + f"\nint main() {{ return answer == {result} ? 0 : 1; }}\n"
            ),
        },
        backends=backends,
    )


# CTFE cannot call native code, so the shapes and C projects that need a
# dependency image run on the other backends only.
NATIVE_AND_BACKENDS = ("native", *BACKENDS)
NATIVE_AND_FILE_BACKENDS = ("native", *FILE_BACKENDS)

IMAGE_SHAPES: dict[str, ImageShape] = {
    # Two overloads of one template share the name `answer!int`.
    "overloaded_template": ImageShape(
        {
            "deps/overloads.d": """
                module overloads;
                template answer(T) {
                    T answer() { return 17; }
                    T answer(T value) { return value + 1; }
                }
                int invoke(string moduleName)() {
                    mixin("import " ~ moduleName ~ ";");
                    return mixin(moduleName ~ ".rootAnswer()");
                }
                """,
            "app/root.d": """
                module root;
                import overloads;
                int rootAnswer() { return 31; }
                int main() {
                    assert(answer!int() == 17);
                    assert(answer!int(23) == 24);
                    assert(invoke!(__MODULE__)() == 31);
                    return 0;
                }
                """,
        },
        imports=True,
    ),
    # Only the guest's own call instantiates `doubled!int`.
    "template_instantiated_only_by_guest": ImageShape(
        {
            "deps/only_guest.d": """
                module only_guest;
                auto doubled(T)(T x) { return cast(T) (x + x); }
                """,
            "app/root.d": """
                module root;
                import only_guest;
                int main() { return doubled(21) == 42 ? 0 : 1; }
                """,
        },
        imports=True,
    ),
    # `&pick!(string)` binds to the more specialised array overload; the
    # call `pick("hello")` must still reach the scalar overload.
    "overload_partial_ordering": ImageShape(
        {
            "deps/ordering.d": """
                module ordering;
                size_t pick(S)(S value) { return 1; }
                size_t pick(S : C[], C)(S[] values) { return 2; }
                """,
            "app/root.d": """
                module root;
                import ordering;
                int main() { assert(pick("hello") == 1); return 0; }
                """,
        },
        imports=True,
        optimised=True,
    ),
    # A nested function that captures a local escapes through the returned
    # `Wrapped!f`, so `only!false` has a heap closure frame.
    "closure_across_the_barrier": ImageShape(
        {
            "deps/closure_dep.d": """
                module closure_dep;
                struct Wrapped(alias pred) {
                    int value;
                    int get() { return pred(value); }
                }
                auto only(bool exact)(int base) {
                    int captured = base;
                    int f(int x) {
                        static if (exact)
                            return x * captured;
                        else
                            return x + captured;
                    }
                    return Wrapped!f(5);
                }
                """,
            "app/root.d": """
                module root;
                import closure_dep;
                int main() { assert(only!false(10).get() == 15); return 0; }
                """,
        },
        backends=tuple(FILE_BACKENDS),
        imports=True,
        optimised=True,
    ),
    "narrow_template_arguments": ImageShape(
        {
            "deps/narrow.d": """
                module narrow;
                struct Selection(ushort value) { int member = value; }
                int read(T)(T value) { return value.member; }
                int number(short value)() { return value; }
                int literal(string value)() { return value == "!cast(ushort)1u"; }
                """,
            "app/root.d": """
                module root;
                import narrow;
                int main() {
                    assert(read(Selection!1()) == 1);
                    assert(number!(-2)() == -2);
                    assert(literal!"!cast(ushort)1u"() == 1);
                    return 0;
                }
                """,
        },
        imports=True,
    ),
    "atomic_fetch_add_in_a_project": ImageShape(
        {
            "app/root.d": """
                module root;
                import core.atomic: atomicFetchAdd;
                int main() {
                    shared int value = 17;
                    assert(atomicFetchAdd(value, 4) == 17);
                    assert(value == 21);
                    return 0;
                }
                """,
        },
        backends=NATIVE_AND_FILE_BACKENDS,
    ),
    # A dependency's `__gshared` variable lives in the native image: native
    # and interpreted code share one storage.
    "dependency_global": ImageShape(
        {
            "app/dub.sdl": lambda: f"""
                name "{dub_name("global-app")}"
                targetType "library"
                targetName "global-app"
                {dub_dependency("global-dependency")}
                configuration "unittest" {{
                    targetType "executable"
                }}
                """,
            "dependency/dub.sdl": lambda: f"""
                name "{dub_name("global-dependency")}"
                targetType "staticLibrary"
                """,
            "dependency/source/global_dependency.d": """
                module global_dependency;
                __gshared int counter = 0;
                void bump() { ++counter; }
                struct Settings {
                    static string path = "default";
                    static void setPath(string value) { path = value; }
                }
                """,
            "app/source/global_app.d": """
                module global_app;
                import global_dependency;
                int main() {
                    if (counter != 0) return 1;
                    bump();
                    if (counter != 1) return 2;
                    if (Settings.path != "default") return 3;
                    Settings.setPath("changed");
                    if (Settings.path != "changed") return 4;
                    return 0;
                }
                """,
        },
        backends=tuple(FILE_BACKENDS),
    ),
    # The interpreted reader on a new thread sees that thread's own copy of
    # the dependency's thread-local variable.
    "dependency_thread_local_per_thread": ImageShape(
        {
            "app/dub.sdl": lambda: f"""
                name "{dub_name("global-app")}"
                targetType "library"
                targetName "global-app"
                {dub_dependency("global-dependency")}
                configuration "unittest" {{
                    targetType "executable"
                }}
                """,
            "dependency/dub.sdl": lambda: f"""
                name "{dub_name("global-dependency")}"
                targetType "staticLibrary"
                """,
            "dependency/source/global_dependency.d": """
                module global_dependency;
                import core.thread: Thread;
                struct Settings {
                    static string path = "default";
                    static void setPath(string value) { path = value; }
                }
                string readOnNewThread(string delegate() read) {
                    string seen;
                    auto thread = new Thread({ seen = read(); });
                    thread.start;
                    thread.join;
                    return seen;
                }
                """,
            "app/source/global_app.d": """
                module global_app;
                import global_dependency;
                int main() {
                    Settings.setPath("changed");
                    if (Settings.path != "changed") return 1;
                    if (readOnNewThread(() => Settings.path) != "default")
                        return 2;
                    if (Settings.path != "changed") return 3;
                    return 0;
                }
                """,
        },
        backends=tuple(FILE_BACKENDS),
    ),
    # The native base declares a second virtual method whose return type
    # dmd must infer and that the guest never calls.
    "subclass_of_native_class_with_inferred_virtual_method": ImageShape(
        {
            "dependency/dub.sdl": dub_library("vtable-dep"),
            "dependency/source/vtable_dep.d": """
                module vtable_dep;
                import std.algorithm.iteration: filter;

                class Base {
                    private int _value;
                    this(int value) { _value = value; }
                    int value() { return _value; }
                    auto positives(int[] xs) {
                        return xs.filter!(x => x > 0);
                    }
                }
                """,
            "app/dub.sdl": lambda: dub_app_recipe(
                "vtable-app", dub_dependency("vtable-dep"),
            ),
            "app/source/vtable_app.d": """
                module vtable_app;
                import vtable_dep;

                class Derived : Base {
                    this(int value) { super(value); }
                    override int value() { return super.value() + 1; }
                }

                int main() {
                    auto derived = new Derived(41);
                    return derived.value() == 42 ? 0 : 1;
                }
                """,
        },
    ),
    "address_of_native_inferred_free_function": ImageShape(
        {
            "dependency/dub.sdl": dub_library("fnptr-dep"),
            "dependency/source/fnptr_dep.d": """
                module fnptr_dep;
                auto increment(int x) { return x + 1; }
                """,
            "app/dub.sdl": lambda: dub_app_recipe(
                "fnptr-app", dub_dependency("fnptr-dep"),
            ),
            "app/source/fnptr_app.d": """
                module fnptr_app;
                import fnptr_dep;
                int main() {
                    auto fp = &increment;
                    return fp(41) == 42 ? 0 : 1;
                }
                """,
        },
    ),
    # The call passes the `TypeInfo` tuple before the declared parameters
    # and the extra arguments after them, as compiled D does.
    "new_native_class_with_variadic_constructor": ImageShape(
        {
            "dependency/dub.sdl":
                dub_library("variadic-ctor-dep"),
            "dependency/source/variadic_ctor_dep.d": """
                module variadic_ctor_dep;
                import core.vararg;

                class Summer {
                    int total;
                    this(int first, ...) {
                        total = first;
                        foreach (type; _arguments) {
                            assert(type == typeid(int));
                            total += va_arg!int(_argptr);
                        }
                    }
                }
                """,
            "app/dub.sdl": lambda: dub_app_recipe(
                "variadic-ctor-app",
                dub_dependency("variadic-ctor-dep"),
            ),
            "app/source/variadic_ctor_app.d": """
                module variadic_ctor_app;
                import variadic_ctor_dep;

                int main() {
                    auto summer = new Summer(1, 2, 3);
                    return summer.total == 6 ? 0 : 1;
                }
                """,
        },
        backends=tuple(FILE_BACKENDS),
    ),
    "new_native_struct_with_variadic_constructor": ImageShape(
        {
            "dependency/dub.sdl":
                dub_library("variadic-struct-ctor-dep"),
            "dependency/source/variadic_struct_ctor_dep.d": """
                module variadic_struct_ctor_dep;
                import core.vararg;

                struct Summer {
                    int total;
                    this(int first, ...) {
                        total = first;
                        foreach (type; _arguments) {
                            assert(type == typeid(int));
                            total += va_arg!int(_argptr);
                        }
                    }
                }
                """,
            "app/dub.sdl": lambda: dub_app_recipe(
                "variadic-struct-ctor-app",
                dub_dependency("variadic-struct-ctor-dep"),
            ),
            "app/source/variadic_struct_ctor_app.d": """
                module variadic_struct_ctor_app;
                import variadic_struct_ctor_dep;

                int main() {
                    auto summer = new Summer(1, 2, 3);
                    return summer.total == 6 ? 0 : 1;
                }
                """,
        },
        backends=tuple(FILE_BACKENDS),
    ),
    # A native class's `auto` method, reached through a delegate that the
    # guest takes.
    "native_inferred_method_through_delegate": ImageShape(
        {
            "dependency/dub.sdl":
                dub_library("delegate-dep"),
            "dependency/source/delegate_dep.d": """
                module delegate_dep;

                class Greeter {
                    private int _base;
                    this(int base) { _base = base; }
                    auto answer(int x) { return _base + x; }
                }
                """,
            "app/dub.sdl": lambda: dub_app_recipe(
                "delegate-app",
                dub_dependency("delegate-dep"),
            ),
            "app/source/delegate_app.d": """
                module delegate_app;
                import delegate_dep;

                int main() {
                    auto instance = new Greeter(40);
                    auto dg = &instance.answer;
                    return dg(2) == 42 ? 0 : 1;
                }
                """,
        },
    ),
    # dub compiles a package from its own directory with paths relative to
    # it, so a root module's `__FILE__` is that relative path.
    "root_module_file_is_relative_to_the_project": ImageShape(
        {
            "app/dub.sdl": lambda: dub_app_recipe(
                "filename", 'sourcePaths "sub"\nimportPaths "imports"\n',
            ),
            "app/imports/.keep": "",
            "app/sub/file_name.d": """
                module file_name;
                int main() { return __FILE__ == "sub/file_name.d" ? 0 : 1; }
                """,
        },
    ),
    # An empty source file is a valid module.
    "empty_root_source": ImageShape(
        {
            "app/dub.sdl": lambda: dub_app_recipe("emptyroot"),
            "app/source/main_empty_root.d": """
                module main_empty_root;
                int main() { return 0; }
                """,
            "app/source/empty_root.d": "",
        },
    ),
    # dub's debug and unittest build types pass `-debug`.
    "dub_debug_mode_compiles_debug_blocks": ImageShape(
        {
            "app/dub.sdl": lambda: dub_app_recipe("debugmode"),
            "app/source/debug_mode.d": """
                module debug_mode;
                int main() { debug { return 0; } return 1; }
                """,
        },
    ),
    # The `-version` flag of the command line reaches the image build.
    "image_build_receives_version_flag": ImageShape(
        {
            "deps/versioned.d": """
                module versioned;
                int answer(T)() {
                    version (ImageSetting) return 42; else return 1;
                }
                """,
            "app/root.d": """
                module root;
                import versioned;
                int main() { return answer!int == 42 ? 0 : 1; }
                """,
        },
        imports=True,
        arguments=("--version=ImageSetting",),
    ),
    # A root-owned type nested two levels deep in the arguments of a
    # dependency template instance: the instance is not in the image, and
    # one with only built-in and dependency types is.
    "nested_template_argument_with_a_root_type": ImageShape(
        {
            "deps/nested_root.d": """
                module nested_root;
                struct Bucket(K, V) { K key; V value; }
                void store(T)(T value) {}
                """,
            "app/root.d": """
                module root;
                import nested_root;
                class Thing {}
                int main() {
                    Bucket!(string, void delegate(Thing)) bucket;
                    store(bucket);
                    Bucket!(string, void delegate(int)) other;
                    store(other);
                    return 0;
                }
                """,
        },
        imports=True,
    ),
    "thread_object_from_a_druntime_template": snippet_shape("""
        import core.thread: Thread;
        int answer() {
            auto thread = new Thread({});
            thread.start;
            thread.join;
            return 0;
        }
        """, 0, NATIVE_AND_FILE_BACKENDS),
    # A Phobos template instance that the program instantiates.
    "phobos_rebindable_alias_overloads": snippet_shape("""
        import std.typecons: rebindable;
        int answer() {
            int[] values = [17];
            return rebindable(values)[0];
        }
        """, 17, NATIVE_AND_BACKENDS),
    "phobos_among_with_a_lambda": snippet_shape("""
        import std.algorithm.comparison: among;
        int answer() {
            return among!((a, b) => a == b)("a", "x", "a");
        }
        """, 2, NATIVE_AND_BACKENDS),
    "recursive_constructor": snippet_shape("""
        struct Recursive {
            this(int depth) {
                if (depth > 0) {
                    auto child = Recursive(depth - 1);
                }
            }
        }
        int answer() {
            auto value = Recursive(0);
            return 0;
        }
        """, 0, NATIVE_AND_BACKENDS),
    "recursive_function_literal": snippet_shape("""
        int answer() {
            int delegate(int) recursive = (int depth) {
                if (depth > 0) return __traits(parent, depth)(depth - 1);
                return 7;
            };
            return recursive(3);
        }
        """, 7, NATIVE_AND_BACKENDS),
    "phobos_bigint": snippet_shape("""
        import std.bigint: BigInt;
        int answer() { return BigInt("123").toInt; }
        """, 123, NATIVE_AND_BACKENDS),
    "to_delegate_of_an_extern_c_function": snippet_shape("""
        import std.functional: toDelegate;
        extern(C) int increment(int value) { return value + 1; }
        int answer() { return toDelegate(&increment)(16); }
        """, 17, NATIVE_AND_FILE_BACKENDS),
    "atomic_fetch_add_with_phobos_min_max": snippet_shape("""
        import core.atomic: atomicFetchAdd;
        import std.algorithm.comparison: min, max;
        int answer() {
            shared int value = 17;
            ulong amount = 4;
            const previous = atomicFetchAdd(value, min(amount, max(amount, 2UL)));
            assert(value == 21);
            return previous;
        }
        """, 17, NATIVE_AND_FILE_BACKENDS),
    "atomic_load_through_a_pointer": snippet_shape("""
        import core.internal.atomic: atomicLoad;
        int answer() {
            shared int value = 42;
            auto pointer = &value;
            return atomicLoad(cast(int*) pointer);
        }
        """, 42, NATIVE_AND_FILE_BACKENDS),
}


def write_files(
    root: Path, files: dict[str, str | Callable[[], str]],
) -> None:
    for relative, text in files.items():
        write(root / relative, text() if callable(text) else text)


def run_image_shape(
    tmp_path: Path, backend: str, shape: ImageShape,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    if backend == "native":
        sources = sorted(
            str(path) for folder in ("app", "deps")
            for path in (tmp_path / folder).glob("*.d")
        )
        dmd = shutil.which("dmd")
        if dmd is None:
            pytest.skip("dmd, the reference compiler, is not on PATH")
        executable = tmp_path / "native"
        compiled = subprocess.run(
            [dmd, "-unittest", f"-of={executable}", f"-od={tmp_path}",
             *sources],
            capture_output=True, check=False, text=True, timeout=120,
        )
        assert compiled.returncode == 0, output(compiled)
        return subprocess.run(
            [str(executable)], capture_output=True, check=False, text=True,
            timeout=120, cwd=tmp_path,
        )

    arguments = [f"--backend={backend}", *shape.arguments]
    if not shape.optimised:
        arguments.append("--no-optimise-image")
    if shape.imports:
        arguments += ["-I", str(tmp_path / "deps")]
    return run_sb(*arguments, str(tmp_path / "app"), cwd=tmp_path, env=env)


def image_shape_cases() -> list[tuple[str, str]]:
    return [
        (name, backend)
        for name, shape in IMAGE_SHAPES.items()
        for backend in shape.backends
    ]


@pytest.mark.parametrize(
    "name, backend", image_shape_cases(),
    ids=[f"{name}-{backend}" for name, backend in image_shape_cases()],
)
def test_guest_runs_against_a_native_dependency(
    tmp_path: Path, name: str, backend: str,
) -> None:
    shape = IMAGE_SHAPES[name]
    write_files(tmp_path, shape.files)

    result = run_image_shape(tmp_path, backend, shape)

    assert result.returncode == shape.status, output(result)


# `bin/sb` is built with LDC, so the image compiler it looks for on PATH is
# `ldc2`. A stub of that name on the child's PATH records each start and
# then runs the real compiler, or fails as a test of the error message says.
IMAGE_COMPILER = "ldc2"


def stub_compiler(directory: Path, script_body: str) -> Path:
    real = shutil.which(IMAGE_COMPILER)
    assert real is not None, f"{IMAGE_COMPILER} is not on PATH"
    stub = directory / "stubs" / IMAGE_COMPILER
    write(stub, "#!/bin/sh\n" + script_body.replace("@REAL@", real))
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    return stub


def recording_compiler(directory: Path) -> Path:
    log = directory / "compiler.log"
    stub_compiler(directory, f'echo "$*" >> "{log}"\nexec "@REAL@" "$@"\n')
    return log


def image_builds(log: Path) -> int:
    if not log.exists():
        return 0
    return sum(" -shared " in f" {line} " for line in log.read_text().splitlines())


def compiler_starts(log: Path) -> int:
    return len(log.read_text().splitlines()) if log.exists() else 0


def image_directory_entries(project_root: Path) -> list[Path]:
    return sorted(project_root.glob(".snakebite/*/images/*"))


def run_with_stubs(
    tmp_path: Path, backend: str, *arguments: str,
) -> subprocess.CompletedProcess[str]:
    path = f"{tmp_path / 'stubs'}:{os.environ.get('PATH', '')}"
    return run_sb(
        f"--backend={backend}", *arguments, "-I", str(tmp_path / "deps"),
        str(tmp_path / "app"), cwd=tmp_path, env={"PATH": path},
    )


def write_answer_project(directory: Path, value: int = 7) -> None:
    write(
        directory / "deps" / "answers.d",
        f"""
        module answers;
        int answer(T)() {{ return {value}; }}
        """,
    )
    write(
        directory / "app" / "root.d",
        """
        module root;
        import answers;
        int main() { return answer!int(); }
        """,
    )


# Nothing about an unchanged project asks for another image: the second
# start, and a start after an edit that leaves the image source as it was,
# start no compiler at all. The two settings of the image optimisation each
# have an image of their own, and each is built once.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_unchanged_project_builds_its_image_once(
    tmp_path: Path, backend: str,
) -> None:
    write_answer_project(tmp_path)
    log = recording_compiler(tmp_path)

    first = run_with_stubs(tmp_path, backend)
    assert first.returncode == 7, output(first)
    assert image_builds(log) == 1

    starts = compiler_starts(log)
    again = run_with_stubs(tmp_path, backend)
    assert again.returncode == 7, output(again)
    assert compiler_starts(log) == starts

    write(
        tmp_path / "app" / "root.d",
        """
        module root;
        import answers;
        // An edit that calls the same template.
        int main() { return answer!int(); }
        """,
    )
    edited = run_with_stubs(tmp_path, backend)
    assert edited.returncode == 7, output(edited)
    assert compiler_starts(log) == starts

    unoptimised = run_with_stubs(tmp_path, backend, "--no-optimise-image")
    assert unoptimised.returncode == 7, output(unoptimised)
    assert image_builds(log) == 2

    for arguments in ([], ["--no-optimise-image"]):
        repeated = run_with_stubs(tmp_path, backend, *arguments)
        assert repeated.returncode == 7, output(repeated)
    assert image_builds(log) == 2


# An edit to a dependency is in the next start's result, and builds the
# image that has the edit.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_dependency_edit_is_in_the_next_start(
    tmp_path: Path, backend: str,
) -> None:
    write_answer_project(tmp_path, 7)
    log = recording_compiler(tmp_path)

    before = run_with_stubs(tmp_path, backend, "--no-optimise-image")
    assert before.returncode == 7, output(before)
    assert image_builds(log) == 1

    write_answer_project(tmp_path, 9)
    after = run_with_stubs(tmp_path, backend, "--no-optimise-image")
    assert after.returncode == 9, output(after)
    assert image_builds(log) == 2


@pytest.mark.parametrize("backend", FILE_BACKENDS)
@pytest.mark.parametrize(
    "phase, failing_arguments, message",
    [
        ("compilation", "-c", "Dependency image compilation failed"),
        ("linking", "-shared", "Dependency image linking failed"),
    ],
    ids=["compile", "link"],
)
def test_failing_image_build_reports_the_compiler_output(
    tmp_path: Path, backend: str, phase: str, failing_arguments: str,
    message: str,
) -> None:
    write_answer_project(tmp_path)
    stub_compiler(
        tmp_path,
        'case " $* " in\n'
        f'    *" {failing_arguments} "*) echo "image build diagnostic"; '
        "exit 1;;\n"
        'esac\nexec "@REAL@" "$@"\n',
    )

    failed = run_with_stubs(tmp_path, backend)

    assert failed.returncode != 0, output(failed)
    assert message in output(failed)
    assert "Command: " in output(failed)
    assert "image build diagnostic" in output(failed)

    assert image_directory_entries(tmp_path) == []

    # The failed build leaves nothing that a start with a working compiler
    # would take for an image.
    (tmp_path / "stubs" / IMAGE_COMPILER).unlink()
    recovered = run_with_stubs(tmp_path, backend)
    assert recovered.returncode == 7, output(recovered)


# A link failure of the real linker, with no stub: the dependency calls a
# symbol that nothing defines. The image link fails at build time, not when
# the guest runs, the user sees the symbol, and the failed build leaves
# nothing in the image directory. A later start without the call builds
# the image.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_unresolved_dependency_symbol_fails_the_image_link(
    tmp_path: Path, backend: str,
) -> None:
    write_files(tmp_path, {
        "deps/missing.d": """
            module missing;
            extern(C) int image_missing_dependency();
            int answer(T)() { return image_missing_dependency(); }
            """,
        "app/root.d": """
            module root;
            import missing;
            int main() { return answer!int(); }
            """,
    })
    log = recording_compiler(tmp_path)

    failed = run_with_stubs(tmp_path, backend, "--no-optimise-image")

    assert failed.returncode == 1, output(failed)
    assert "Dependency image linking failed" in output(failed)
    assert "image_missing_dependency" in output(failed)
    assert image_directory_entries(tmp_path) == []

    write(
        tmp_path / "deps" / "missing.d",
        """
        module missing;
        int answer(T)() { return 5; }
        """,
    )
    builds = image_builds(log)
    recovered = run_with_stubs(tmp_path, backend, "--no-optimise-image")

    assert recovered.returncode == 5, output(recovered)
    assert image_builds(log) == builds + 1
    entries = [path.name for path in image_directory_entries(tmp_path)]
    assert any(name.endswith(".so") for name in entries), entries
    assert not any(name.startswith("build-") for name in entries), entries


# A runner hook that a dependency installs replaces the default unit test
# runner: the app's failing unittest never runs. CTFE cannot call native code.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_dependency_runner_replaces_the_default_test_runner(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "dub.sdl",
        f'name "{dub_name("repeat-runner-app")}"\ntargetType "library"\n'
        f'dependency "{dub_name("repeat-runner")}" path="../runner"\n',
    )
    write(
        tmp_path / "app" / "source" / "app.d",
        """
        module repeat_runner_app;
        import repeat_runner;
        unittest { assert(false, "custom runner must replace default tests"); }
        """,
    )
    write(
        tmp_path / "runner" / "dub.sdl",
        f'name "{dub_name("repeat-runner")}"\ntargetType "staticLibrary"\n',
    )
    write(
        tmp_path / "runner" / "source" / "repeat_runner.d",
        """
        module repeat_runner;
        import core.runtime: Runtime, UnitTestResult;
        import core.stdc.stdio: puts;
        shared static this() {
            Runtime.extendedModuleUnitTester = () {
                puts("custom runner ran");
                return UnitTestResult(1, 1, false, false);
            };
        }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )

    assert result.returncode == 0, output(result)
    assert guest_lines(result).count("custom runner ran") == 1, output(result)


# A throwable that escapes the runner hook of a dependency ends the program
# with status 1, not with a crash at exit, and the runtime ends as it does
# in compiled D: a thread that the program started is joined and the module
# destructors run. The thread waits for a signal that the runner hook gives
# after the thread has started, just before the throwable escapes, so no time
# decides the result.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_throwable_escaping_a_unittest_runner_ends_the_program_cleanly(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "dub.sdl",
        f'name "{dub_name("escaping-throwable-app")}"\ntargetType "library"\n',
    )
    write(
        tmp_path / "app" / "source" / "escaping_throwable_app.d",
        """
        module escaping_throwable_app;
        import core.runtime: Runtime, UnitTestResult;
        import core.stdc.stdio: puts;
        import core.sync.semaphore: Semaphore;
        import core.thread: Thread;
        shared static this() {
            Runtime.extendedModuleUnitTester = {
                auto started = new Semaphore;
                auto release = new Semaphore;
                new Thread({
                    started.notify;
                    release.wait;
                    puts("guest thread ended");
                }).start;
                started.wait;
                release.notify;
                foreach (module_; ModuleInfo)
                    if (module_ && module_.unitTest
                            && module_.name == "escaping_throwable_app")
                        module_.unitTest()();
                return UnitTestResult(1, 1, false, false);
            };
        }
        shared static ~this() { puts("module destructor ran"); }
        unittest { throw new Exception("escapes the runner"); }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path,
    )

    assert result.returncode == 1, output(result)
    assert "escapes the runner" in output(result)
    assert "guest thread ended" in guest_lines(result), output(result)
    assert "module destructor ran" in guest_lines(result), output(result)


def app_using_unused_member(backend: str, expected: int) -> str:
    # CTFE cannot call native code.
    check = "" if backend == "ctfe" else (
        f"if (image_unused_answer() != {expected}) return 1;"
    )
    return f"""
        module image_app;
        import image_middle;
        extern(C) int image_unused_answer();
        int main() {{
            assert(answer() == 42);
            {check}
            return 0;
        }}
        """


# The dependencies of a dependency are built once and reach the image as
# archives: a member that nothing refers to still answers a symbol lookup,
# an edit of the app does not build the dependencies again, an edit of a
# transitive dependency does, and the image does not use the copy of the
# archive that dub leaves in the package directory.
@pytest.mark.parametrize("backend", BACKENDS)
def test_transitive_dub_dependencies_reach_the_image(
    tmp_path: Path, backend: str,
) -> None:
    write(
        tmp_path / "app" / "dub.sdl",
        """
        name "image-app"
        targetType "library"
        targetName "image-app"
        preBuildCommands "test ! -e reject-build"
        dependency "image-middle" path="../middle"
        configuration "unittest" {
            targetType "executable"
        }
        """,
    )
    app_source = tmp_path / "app" / "source" / "app.d"
    write(app_source, app_using_unused_member(backend, 73))
    write(
        tmp_path / "middle" / "dub.sdl",
        """
        name "image-middle"
        targetType "staticLibrary"
        dependency "image-leaf" path="../leaf archives"
        """,
    )
    write(
        tmp_path / "middle" / "source" / "image_middle.d",
        """
        module image_middle;
        import image_leaf;
        int answer() { return leaf() + 1; }
        """,
    )
    leaf = tmp_path / "leaf archives"
    write(leaf / "dub.sdl", 'name "image-leaf"\ntargetType "staticLibrary"\n')
    write(
        leaf / "source" / "image_leaf.d",
        "module image_leaf;\nint leaf() { return 41; }\n",
    )
    unused = leaf / "source" / "image_unused.d"
    write(
        unused,
        """
        module image_unused;
        extern(C) int image_unused_answer() { return 73; }
        """,
    )
    # dub keeps the build artifacts of a dependency under DPATH.
    dpath = tmp_path / "dpath"
    start = lambda: run_sb(  # noqa: E731
        f"--backend={backend}", "--no-optimise-image", str(tmp_path / "app"),
        cwd=tmp_path, env={"DPATH": str(dpath)},
    )

    first = start()
    assert first.returncode == 0, output(first)

    # With the build command of the app rejecting a build, an edit of the
    # app still starts: neither the app nor the archives are built again.
    write(tmp_path / "app" / "reject-build")
    write(app_source, app_using_unused_member(backend, 73) + "\n")
    edited_app = start()
    assert edited_app.returncode == 0, output(edited_app)
    (tmp_path / "app" / "reject-build").unlink()

    write(
        unused,
        """
        module image_unused;
        extern(C) int image_unused_answer() { return 179; }
        """,
    )
    write(app_source, app_using_unused_member(backend, 179))
    edited_leaf = start()
    assert edited_leaf.returncode == 0, output(edited_leaf)

    # Another compiler's build replaces the copy in the package directory.
    write(leaf / "libimage-leaf.a", "not an archive")
    foreign = start()
    assert foreign.returncode == 0, output(foreign)

    # A missing build artifact is built again. CTFE cannot call native code,
    # so it builds none.
    if backend == "ctfe":
        return
    artifacts = list(dpath.rglob("libimage-leaf.a"))
    assert len(artifacts) == 1, artifacts
    artifacts[0].unlink()
    rebuilt = start()
    assert rebuilt.returncode == 0, output(rebuilt)
    assert artifacts[0].exists()


# The `preGenerateCommands` of a recipe run at each start: a cached
# description of the project does not skip them.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_generation_hook_runs_at_every_start(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write(
        app / "dub.sdl",
        f'name "{dub_name("hook-app")}"\ntargetType "library"\n'
        'preGenerateCommands "echo hook >> hooks.log"\n',
    )
    write(app / "source" / "app.d", "module app;\n")

    for starts in (1, 2, 3):
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image", str(app),
            cwd=tmp_path,
        )
        assert result.returncode == 0, output(result)
        assert (app / "hooks.log").read_text().splitlines() == (
            ["hook"] * starts
        )


# The test runner that dub generates for a library names the modules of
# the package: a module renamed between two starts is run under its new name.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_generated_test_runner_follows_a_module_rename(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write(
        app / "dub.sdl",
        f'name "{dub_name("renamed-app")}"\ntargetType "library"\n',
    )

    def start(module_name: str) -> subprocess.CompletedProcess[str]:
        write(
            app / "source" / "app.d",
            f"""
            module {module_name};
            unittest {{
                import core.stdc.stdio: puts;
                puts("{module_name} unittest ran");
            }}
            """,
        )
        return run_sb(
            f"--backend={backend}", "--no-optimise-image", str(app),
            cwd=tmp_path,
        )

    for module_name in ("original_name", "original_name", "changed_name"):
        result = start(module_name)
        assert result.returncode == 0, output(result)
        assert f"{module_name} unittest ran" in guest_lines(result)
        other = {"original_name", "changed_name"} - {module_name}
        assert not any(name in output(result) for name in other)


# A C file is a root module of a project (`sourceFiles` of a dub recipe, or
# any `.c` file of a bare directory), and D code imports it as it imports a
# D module (ImportC). Each case states the status that the D `main` returns,
# which a compiled program gives as well. `CMOD` in the D source names the C
# module.
class CProject(NamedTuple):
    c_source: str
    d_source: str
    status: int
    dub: bool = False
    extra_c: str | None = None
    extra_d: str | None = None
    backends: tuple[str, ...] = tuple(BACKENDS)


C_PROJECTS: dict[str, CProject] = {
    "functionCalledFromD": CProject(
        r"""
        int add(int a, int b) { return a + b; }
        """,
        r"""
        import CMOD;
        int main() { return add(40, 2); }
        """,
        42,
        dub=True,
    ),
    "vaCopy": CProject(
        r"""
        #include <stdarg.h>
        int twice(int count, ...) {
            va_list first, second;
            va_start(first, count);
            va_copy(second, first);
            int total = 0;
            for (int i = 0; i < count; i++) total += va_arg(first, int);
            for (int i = 0; i < count; i++) total += va_arg(second, int);
            va_end(first);
            va_end(second);
            return total;
        }
        """,
        r"""
        import CMOD;
        int main() { return twice(3, 3, 7, 11); }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "compilerBuiltins": CProject(
        r"""
        int swapped(int x) { return __builtin_bswap32(x); }
        int leading(unsigned x) { return __builtin_clz(x); }
        int expected(int x) { return __builtin_expect(x, 1); }
        """,
        r"""
        import CMOD;
        int main() {
            return swapped(1) == 0x01000000 && leading(1) == 31
                && expected(42) == 42 ? 42 : 1;
        }
        """,
        42,
    ),
    "addressAsIntegerInitialiser": CProject(
        r"""
        int target = 42;
        unsigned long address = (unsigned long) &target;
        unsigned long viaChar = (unsigned long) (char *) &target;
        """,
        r"""
        import CMOD;
        int main() {
            return address == cast(size_t) &target
                && viaChar == address ? *cast(int*) address : 1;
        }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "scalarAndArrayInitialisers": CProject(
        r"""
        int scalar = 5;
        double ratio = 0.5;
        int numbers[4] = {1, 2, 3};
        int inferred[] = {10, 20};
        int local(int x) {
            int a[2] = {x, 3};
            return a[0] + a[1];
        }
        """,
        r"""
        import CMOD;
        int main() {
            const ok = scalar == 5 && ratio == 0.5
                && numbers[0] == 1 && numbers[2] == 3 && numbers[3] == 0
                && inferred.length == 2 && inferred[1] == 20
                && local(4) == 7;
            return ok ? 42 : 1;
        }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "structInitialisers": CProject(
        r"""
        struct Point { int x; int y; };
        struct Line { struct Point from; struct Point to; };
        struct Point origin = {1, 2};
        struct Line line = {{1, 2}, {3, 4}};
        struct Line designated = {.to = {.y = 9}, .from = {.x = 7}};
        int sparse[5] = {[3] = 4, [1] = 2};
        """,
        r"""
        import CMOD;
        int main() {
            const ok = origin.x == 1 && origin.y == 2
                && line.to.x == 3 && line.to.y == 4
                && designated.from.x == 7 && designated.from.y == 0
                && designated.to.x == 0 && designated.to.y == 9
                && sparse[1] == 2 && sparse[3] == 4 && sparse[4] == 0;
            return ok ? 42 : 1;
        }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "stringAndPointerInitialisers": CProject(
        r"""
        const char *greeting = "hello";
        char buffer[8] = "abc";
        int target = 41;
        int *pointer = &target;
        int **pointerToPointer = &pointer;
        int *offset = &target;
        """,
        r"""
        import CMOD;
        int main() {
            *pointer += 1;
            const ok = greeting[0] == 'h' && greeting[4] == 'o'
                && greeting[5] == 0
                && buffer[2] == 'c' && buffer[3] == 0
                && **pointerToPointer == 42 && target == 42
                && offset is pointer;
            return ok ? target : 1;
        }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "staticFunctionAndVariable": CProject(
        r"""
        static int counter = 40;
        static int bump(void) { return ++counter; }
        int twice(void) { bump(); return bump(); }
        """,
        r"""
        import CMOD;
        int main() { return twice(); }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "structByValueAndPointer": CProject(
        r"""
        struct IntAndLong { int a; long b; };
        struct IntAndLong make(int a, long b) {
            struct IntAndLong p = {a, b};
            return p;
        }
        long sum(struct IntAndLong p) { return p.a + p.b; }
        void scale(struct IntAndLong *p, int factor) {
            p->a *= factor;
            p->b *= factor;
        }
        """,
        r"""
        import CMOD;
        int main() {
            auto p = make(3, 4);
            scale(&p, 2);
            return cast(int) (sum(p) + sum(make(10, 18)));
        }
        """,
        42,
    ),
    "enumAndTypedef": CProject(
        r"""
        enum Colour { Red, Green = 10, Blue };
        typedef unsigned char byte_t;
        typedef struct { byte_t lo; byte_t hi; } BytePair;
        enum Colour pick(int i) { return i ? Blue : Green; }
        BytePair pack(byte_t lo, byte_t hi) {
            BytePair p = {lo, hi};
            return p;
        }
        """,
        r"""
        import CMOD;
        int main() {
            const p = pack(20, 11);
            return pick(1) == Blue && pick(0) == Green && Red == 0
                ? p.lo + p.hi + Blue : 1;
        }
        """,
        42,
    ),
    "controlFlow": CProject(
        r"""
        int fall(int x) {
            int r = 0;
            switch (x) {
            case 1: r += 1;
            case 2: r += 2; break;
            case 3: r += 4;
            default: r += 8;
            }
            return r;
        }
        int jump(int n) {
            int i = 0;
            loop:
            if (i >= n) goto done;
            i += 2;
            goto loop;
            done:
            return i;
        }
        int commas(void) {
            int a, b;
            a = (b = 3, b + 4);
            return a;
        }
        int total(void) {
            int values[5] = {1, 2, 3, 4, 5};
            int *p = values;
            int sum = 0;
            for (int i = 0; i < 5; i++) sum += *(p + i);
            for (p = values + 4; p != values; p--) sum += *(p - 1);
            return sum;
        }
        """,
        r"""
        import CMOD;
        int main() {
            const ok = fall(1) == 3 && fall(2) == 2 && fall(3) == 12
                && fall(9) == 8 && jump(5) == 6 && commas() == 7
                && total() == 25;
            return ok ? 42 : 1;
        }
        """,
        42,
    ),
    "compoundLiteral": CProject(
        r"""
        struct Point { int x; int y; };
        int norm1(struct Point p) { return p.x + p.y; }
        int viaLiteral(int a) {
            return norm1((struct Point){a, 2}) + (int[]){1, 2, 3}[2];
        }
        struct Point *global = &(struct Point){40, 2};
        int *array = (int[]){5, 6, 7};
        int viaAddress(void) {
            struct Point *p = &(struct Point){1, 41};
            p->x += 1;
            return p->x + p->y;
        }
        """,
        r"""
        import CMOD;
        int main() {
            return viaLiteral(37) == 42 && global.x + global.y == 42
                && array[2] == 7 && viaAddress() == 43
                ? 42 : 1;
        }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "genericSelection": CProject(
        r"""
        #define KIND(x) _Generic((x), int: 1, double: 2, default: 3)
        int kinds(void) { return KIND(1) * 100 + KIND(1.0) * 10 + KIND('a'); }
        """,
        r"""
        import CMOD;
        int main() { return kinds() == 121 ? 42 : 1; }
        """,
        42,
    ),
    "bitFields": CProject(
        r"""
        struct Flags {
            unsigned a : 3;
            unsigned b : 5;
            int c : 4;
        };
        struct Flags make(void) {
            struct Flags f = {5, 17, -2};
            f.a += 1;
            return f;
        }
        int sizeOfFlags(void) { return sizeof(struct Flags); }
        """,
        r"""
        import CMOD;
        int main() {
            const f = make();
            return f.a == 6 && f.b == 17 && f.c == -2
                && sizeOfFlags() == Flags.sizeof ? 42 : 1;
        }
        """,
        42,
    ),
    "variadicDefinedInC": CProject(
        r"""
        #include <stdarg.h>
        int sum(int count, ...) {
            va_list args;
            va_start(args, count);
            int total = 0;
            for (int i = 0; i < count; i++) total += va_arg(args, int);
            va_end(args);
            return total;
        }
        """,
        r"""
        import CMOD;
        int main() { return sum(3, 10, 12, 20); }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "cCallsPrintf": CProject(
        r"""
        #include <stdio.h>
        int report(int value) { return printf("total %d\n", value); }
        """,
        r"""
        import CMOD;
        int main() { return report(42); }
        """,
        9,
        backends=tuple(FILE_BACKENDS),
    ),
    "systemHeader": CProject(
        r"""
        #include <string.h>
        int length(const char *text) { return (int) strlen(text); }
        """,
        r"""
        import CMOD;
        int main() { return length("abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"); }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "addressOfCFunction": CProject(
        r"""
        int triple(int x) { return 3 * x; }
        """,
        r"""
        import CMOD;
        int main() {
            extern(C) int function(int) pointer = &triple;
            return pointer(14);
        }
        """,
        42,
    ),
    "cCallsBackD": CProject(
        r"""
        extern int fromD(int);
        int viaC(int x) { return fromD(x) + 1; }
        """,
        r"""
        import CMOD;
        extern(C) int fromD(int x) { return x * 2; }
        int main() { return viaC(20); }
        """,
        41,
        backends=tuple(FILE_BACKENDS),
    ),
    "bareDirectoryImportsCModule": CProject(
        r"""
        int add(int a, int b) { return a + b; }
        """,
        r"""
        import CMOD;
        int main() { return add(40, 2); }
        """,
        42,
    ),
    "cFunctionDeclaredInD": CProject(
        r"""
        int add(int a, int b) { return a + b; }
        """,
        r"""
        extern(C) int add(int, int);
        int main() { return add(40, 2); }
        """,
        42,
        dub=True,
        backends=tuple(FILE_BACKENDS),
    ),
    "comparisonsGiveInt": CProject(
        r"""
        int dirty(void) {
            int a[16] = {-1, -1, -1, -1, -1, -1, -1, -1,
                -1, -1, -1, -1, -1, -1, -1, -1};
            return a[0] + a[15];
        }
        int less(int x) { return x < 3; }
        int equal(int x) { return x == 3; }
        int not(int x) { return !x; }
        int both(int x, int y) { return x && y; }
        int either(int x, int y) { return x || y; }
        int pointer(int *p) { return p && *p > 3; }
        """,
        r"""
        import CMOD;
        int main() {
            int three = 3;
            int ok = 1;
            dirty;
            ok &= less(4) == 0;
            dirty;
            ok &= equal(4) == 0;
            dirty;
            ok &= not(5) == 0;
            dirty;
            ok &= both(1, 0) == 0;
            dirty;
            ok &= either(0, 0) == 0;
            dirty;
            ok &= pointer(&three) == 0;
            return ok ? 42 : 1;
        }
        """,
        42,
    ),
    "staticFunctionIsNotALinkedDefinition": CProject(
        r"""
        static int linkedHelper(void) { return 1; }
        int fromStatic(void) { return linkedHelper(); }
        """,
        r"""
        extern(C) int linkedHelper();
        extern(C) int fromStatic();
        int main() { return linkedHelper() * 10 + fromStatic(); }
        """,
        21,
        dub=True,
        extra_c=r"""
        int linkedHelper(void) { return 2; }
        """,
        backends=tuple(FILE_BACKENDS),
    ),
    "declarationWithPragmaMangle": CProject(
        r"""
        int mangledAdd(int a, int b) { return a + b; }
        """,
        r"""
        pragma(mangle, "mangledAdd") extern(C) int sum(int, int);
        int main() { return sum(40, 2); }
        """,
        42,
        dub=True,
        backends=tuple(FILE_BACKENDS),
    ),
    "declarationInCppNamespace": CProject(
        r"""
        int unusedInNamespaceTest(void) { return 0; }
        """,
        r"""
        extern(C++, importcns) int inNamespace(int);
        int main() { return inNamespace(41); }
        """,
        42,
        dub=True,
        extra_d=r"""
        extern(C++, importcns) int inNamespace(int x) { return x + 1; }
        """,
        backends=tuple(FILE_BACKENDS),
    ),
    "declarationInNonRootModule": CProject(
        r"""
        int unusedInNonRootTest(void) { return 0; }
        """,
        r"""
        import core.stdc.stdlib: libcAbs = abs;
        int main() { return libcAbs(-3) - 35; }
        """,
        42,
        dub=True,
        extra_d=r"""
        extern(C) int abs(int x) { return 77; }
        """,
        backends=tuple(FILE_BACKENDS),
    ),
    "externVariableIsTheDefinition": CProject(
        r"""
        int linkedCounter = 3;
        int readCounter(void) { return linkedCounter; }
        """,
        r"""
        extern(C) extern __gshared int linkedCounter;
        extern(C) int readCounter();
        extern(C) int bumpCounter();
        int main() {
            linkedCounter += 9;
            bumpCounter();
            return readCounter();
        }
        """,
        42,
        dub=True,
        extra_c=r"""
        extern int linkedCounter;
        int bumpCounter(void) { linkedCounter += 30; return linkedCounter; }
        """,
        backends=tuple(FILE_BACKENDS),
    ),
    "flexibleArrayMember": CProject(
        r"""
        struct Flexible { int count; int data[]; };
        struct OneElement { int count; int data[1]; };
        int flexible(void) {
            int storage[8] = {0};
            struct Flexible *f = (struct Flexible *) storage;
            struct OneElement *o = (struct OneElement *) storage;
            f->data[3] = 40;
            o->data[4] = 2;
            return f->data[3] + o->data[4];
        }
        """,
        r"""
        import CMOD;
        int main() { return flexible(); }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
    "compoundLiteralWithCharArray": CProject(
        r"""
        struct Named { int x; char name[8]; };
        struct Named *named = &(struct Named){41, "a"};
        """,
        r"""
        import CMOD;
        int main() { return named.x + (named.name[0] == 'a'); }
        """,
        42,
        backends=tuple(FILE_BACKENDS),
    ),
}


@pytest.mark.parametrize(
    "name, backend",
    [(name, backend) for name, case in C_PROJECTS.items()
     for backend in case.backends],
)
def test_c_module_is_imported_by_d(
    tmp_path: Path, name: str, backend: str,
) -> None:
    case = C_PROJECTS[name]
    module = f"importc_{name.lower()}"
    app = tmp_path / "app"
    source = app / "source" if case.dub else app
    if case.dub:
        write(
            app / "dub.sdl",
            f'''
            name "{dub_name("importc_project")}"
            targetType "library"
            mainSourceFile "source/{module}_app.d"
            sourceFiles "source/{module}.c"
            {f'sourceFiles "source/{module}_extra.c"' if case.extra_c else ""}
            configuration "unittest" {{
                targetType "executable"
            }}
            ''',
        )
    write(source / f"{module}.c", case.c_source)
    if case.extra_c is not None:
        write(source / f"{module}_extra.c", case.extra_c)
    if case.extra_d is not None:
        write(
            source / f"{module}_defs.d",
            f"module {module}_defs;\n{case.extra_d}",
        )
    write(
        source / f"{module}_app.d",
        f"module {module}_app;\n" + case.d_source.replace("CMOD", module),
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(app), cwd=tmp_path,
    )

    assert result.returncode == case.status, output(result)


DUB_DESCRIBE_FIXTURES = Path(__file__).parent / "fixtures" / "dub-describe"


# `bin/ut` runs the dub description cache on these recordings instead of
# starting dub. The recording has to be what dub gives for the project that
# sits next to it.
@pytest.mark.parametrize(
    "fixture",
    sorted(path.name for path in DUB_DESCRIBE_FIXTURES.iterdir() if path.is_dir()),
)
def test_recorded_dub_describe_is_what_dub_gives(
    tmp_path: Path, fixture: str,
) -> None:
    root = tmp_path / fixture
    shutil.copytree(DUB_DESCRIBE_FIXTURES / fixture, root)
    project, *arguments = (root / "describe.cmd").read_text().split()

    described = subprocess.run(
        ["dub", "describe", *arguments], capture_output=True, check=False,
        text=True, timeout=120, cwd=root / project,
    )

    assert described.returncode == 0, output(described)
    recorded = (DUB_DESCRIBE_FIXTURES / fixture / "describe.json").read_text()
    real = json.loads(described.stdout)
    for target in real["targets"]:
        target["cacheArtifactPath"] = "<machine specific>"
    assert real == json.loads(
        recorded.replace("@ROOT@", str(root))
    ), "stale recording: run tests/fixtures/dub-describe/record.sh"


# A new source file, a deleted one and a changed recipe are in the next
# start of a project: what dub finds in the project is not taken from an
# earlier start.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_project_changes_are_in_the_next_start(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    recipe = dub_project_recipe("changing")
    write(app / "dub.sdl", recipe)
    write(
        app / "source" / "main.d",
        """
        module main;
        int main() {
            int status = 0;
            static if (__traits(compiles, { import extra; })) status += 1;
            static if (__traits(compiles, { import nested.extra; })) status += 2;
            version (Changed) status += 4;
            return status;
        }
        """,
    )

    def start() -> int:
        result = run_sb(
            f"--backend={backend}", "--no-optimise-image", str(app),
            cwd=tmp_path,
        )
        return result.returncode

    assert start() == 0
    assert start() == 0
    write(app / "source" / "extra.d", "module extra;\n")
    assert start() == 1
    (app / "source" / "extra.d").unlink()
    assert start() == 0
    write(app / "source" / "nested" / "extra.d", "module nested.extra;\n")
    assert start() == 2
    write(app / "dub.sdl", recipe + 'versions "Changed"\n')
    assert start() == 6


# A unittest configuration of a project can name its own main source file,
# source and import directories.
@pytest.mark.parametrize("backend", FILE_BACKENDS)
def test_unittest_configuration_settings_are_loaded(
    tmp_path: Path, backend: str,
) -> None:
    app = tmp_path / "app"
    write(
        app / "dub.sdl",
        f'name "{dub_name("dub-package-settings")}"\n'
        """
        targetType "library"

        configuration "library" {
        }

        configuration "unittest" {
            targetType "executable"
            targetName "ut"
            mainSourceFile "tests/main.d"
            sourcePaths "tests"
            importPaths "tests"
        }
        """,
    )
    write(app / "source" / "package.d", "module dub_package_settings;\n")
    write(
        app / "tests" / "main.d",
        """
        module tests.main;
        int main() { return 3; }
        """,
    )

    result = run_sb(
        f"--backend={backend}", "--no-optimise-image", str(app), cwd=tmp_path,
    )

    assert result.returncode == 3, output(result)


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


def run_with_fake_dub_in(
    directory: Path, cwd: Path, *args: str,
) -> subprocess.CompletedProcess[str]:
    path = f"{directory / 'bin'}:{os.environ.get('PATH', '')}"
    return run_sb(*args, cwd=cwd, env={"PATH": path})


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


def write_plain_recipe(root: Path, name: str) -> None:
    (root / name).mkdir()
    (root / name / "dub.sdl").write_text(f'name "{name}"\n')


# A plain package name with a cache record fails its test and the record goes,
# a name from `dub_name` is not a failure, and a record that was there before
# the test began stays.
def test_plain_dub_name_with_a_cache_record_is_reported(
    tmp_path: Path,
) -> None:
    plain = f"plain-name-check-{secrets.token_hex(6)}"
    kept = f"kept-name-check-{secrets.token_hex(6)}"
    safe = dub_name("safe-name-check")
    cache = Path.home() / ".dub" / "cache"
    for name in (plain, kept, safe):
        write_plain_recipe(tmp_path, name)
        (cache / name / "~master").mkdir(parents=True)
    try:
        messages = delete_plain_dub_names(tmp_path, before={kept})
        assert len(messages) == 2
        assert {n for n in (plain, kept, safe)
                if any(n in m for m in messages)} == {plain, kept}
        assert not (cache / plain).exists()
        assert (cache / kept).is_dir()
        forget_dub_names()
        assert not (cache / safe).exists()
    finally:
        for name in (plain, kept):
            shutil.rmtree(cache / name, ignore_errors=True)


# A recipe that is JSON but not an object has no package name.
def test_recipe_that_is_not_a_json_object_has_no_package_name(
    tmp_path: Path,
) -> None:
    (tmp_path / "package.json").write_text("[]")

    assert delete_plain_dub_names(tmp_path, before=set()) == []


# The autouse fixture of conftest.py makes the check fail the test.
def test_fixture_fails_a_test_with_a_plain_dub_name(
    pytester: pytest.Pytester,
) -> None:
    plain = f"plain-fixture-check-{secrets.token_hex(6)}"
    cache = Path.home() / ".dub" / "cache"
    pytester.makeconftest((Path(__file__).parent / "conftest.py").read_text())
    pytester.makepyfile(
        f"""
        from pathlib import Path

        def test_plain_name(tmp_path):
            (tmp_path / "dub.sdl").write_text('name "{plain}"\\n')
            (Path.home() / ".dub" / "cache" / "{plain}" / "~master").mkdir(
                parents=True)
        """
    )
    try:
        result = pytester.runpytest_inprocess("-p", "no:xdist")
        result.assert_outcomes(passed=1, errors=1)
        assert plain in result.stdout.str()
        assert not (cache / plain).exists()
    finally:
        shutil.rmtree(cache / plain, ignore_errors=True)


# The tests can run in parallel (see build/pytest-workers.sh) because the
# state that they share, the `.snakebite` directory and the dub package store,
# is keyed by project path and published with an atomic rename.
if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
