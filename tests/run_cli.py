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
    assert guest_lines(result) == [
        "crt constructor", "main", "shared destructor", "crt destructor",
    ]


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
