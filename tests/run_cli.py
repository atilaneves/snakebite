#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1"]
# ///

# End-to-end tests of the `bin/sb` command line. They start the built
# binary as a child process, so they live here and not in `bin/ut`.

import os
import re
import shutil
import stat
import subprocess
from pathlib import Path
from typing import NamedTuple

import pytest

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
        """
        name "app"
        targetType "library"
        dependency "dep" path="../dep"
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
        """
        name "dep"
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
