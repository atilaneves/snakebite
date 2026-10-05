#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pytest==8.4.1", "pytest-xdist==3.8.0"]
# ///

# What a flag selects is tested in `bin/ut` (tests/ut/backends/flags.d and
# tests/ut/frontend/checks.d): there a program runs in the test process, with
# no compiler, linker or dub. A test is here only when its assertion needs a
# process: the signal that ends the process, the exit status of `bin/sb`, or
# dub, the dependency image, the build hooks and the root compiler wrapper
# that `bin/sb` starts to get the flags into the program.

import json
import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
from dubname import dub_name

TIMEOUT = 120

BACKENDS = ["bytecode", "interpreter", "ctfe"]

# CTFE has no process of its own to end: it reports a failed check as a
# compile-time error. The abort and its message come from the C runtime,
# which CTFE cannot call.
ENDS_PROCESS = ["bytecode", "interpreter"]

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
    recipe = f'name "{dub_name("app")}"\ntargetType "library"\n'
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


def outcome_of(result: subprocess.CompletedProcess[str]) -> Outcome:
    return Outcome(result.returncode, result.stdout + result.stderr)


def sb_path() -> str:
    sb = os.path.join(os.getcwd(), "bin", "sb")
    if not os.path.exists(sb):
        pytest.skip("bin/sb does not exist; run `ninja bin/sb` first")

    return sb


def assert_aborts_after_start(outcome: Outcome, message: str) -> None:
    assert outcome.status == -SIGABRT, outcome.output
    assert message in outcome.output, outcome.output
    assert "start" in outcome.output, outcome.output
    assert "after" not in outcome.output, outcome.output


# A halt kills the process with SIGILL (`ud2`), so the log ends where the
# halt happened.
@pytest.mark.parametrize("backend", ENDS_PROCESS)
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
    assert outcome.status == -SIGILL, outcome.output
    assert "start" in outcome.output
    assert "after" not in outcome.output


# The C runtime aborts the process and prints the failed condition.
@pytest.mark.parametrize("backend", ENDS_PROCESS)
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
    assert_aborts_after_start(outcome, "Assertion `x == 2' failed")


# The C runtime gets the message of `assert(e, message)` instead of the
# text of `e`.
@pytest.mark.parametrize("backend", ENDS_PROCESS)
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


# Under `-checkaction=C` the default of a `final switch` is an `assert(0)`
# that dmd does not analyse, so the expression has no type.
@pytest.mark.parametrize("backend", ENDS_PROCESS)
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
    assert_aborts_after_start(outcome, "Assertion `0' failed")


# The message of a failed bounds check is not the one of a failed assert.
@pytest.mark.parametrize("backend", ENDS_PROCESS)
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
    assert_aborts_after_start(
        outcome, "Assertion `array index out of bounds' failed",
    )


# `dmd` refuses a `-checkaction=` value that it does not know, and so does
# every backend, before it runs anything. The exit status is the process's.
@pytest.mark.parametrize("backend", BACKENDS)
def test_unknown_check_flag_value_is_an_error(
    tmp_path: Path, backend: str,
) -> None:
    flag = "-checkaction=bogus"
    (tmp_path / "dub.sdl").write_text(
        f'name "{dub_name("app")}"\ntargetType "library"\ndflags "{flag}"\n',
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
    assert f"switch `{flag}` is invalid" in output


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


# A template of a dub dependency that the project instantiates has the
# checks of the project's flags, as it has in a native build.
@pytest.mark.parametrize("backend", BACKENDS)
@pytest.mark.parametrize("extra_flags", [[], ["-c", "-g"]])
def test_check_flag_applies_to_a_dependency_template(
    tmp_path: Path, backend: str, extra_flags: list[str],
) -> None:
    app = tmp_path / "app"
    dependency = tmp_path / "dependency"
    (app / "source").mkdir(parents=True)
    (dependency / "source").mkdir(parents=True)
    (app / "dub.sdl").write_text(
        f'name "{dub_name("app")}"\ntargetType "library"\n'
        'dflags "-check=in=off"\n'
        + "".join(f'dflags "{flag}"\n' for flag in extra_flags)
        + f'dependency "{dub_name("dep")}" path="../dependency"\n',
        encoding="utf-8",
    )
    (app / "source" / "app.d").write_text(
        "module app;\nimport dep;\nunittest { positive(-1); }\n",
        encoding="utf-8",
    )
    (dependency / "dub.sdl").write_text(
        f'name "{dub_name("dep")}"\ntargetType "library"\n', encoding="utf-8",
    )
    (dependency / "source" / "dep.d").write_text(
        "module dep;\n"
        "T positive(T)(T value) in (value > 0) { return value; }\n",
        encoding="utf-8",
    )
    command = [
        sb_path(), f"--backend={backend}", "--no-optimise-image", str(app),
    ]

    result = subprocess.run(
        command, cwd=app, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )

    assert result.returncode == 0, result.stdout + result.stderr


# `bin/sb` asks dub to describe the project for ldc2, so the flags of
# `dflags-ldc` apply to the guest and the ones of `dflags-dmd` do not.
@pytest.mark.parametrize("backend", ["bytecode"])
def test_compiler_specific_flags_apply_to_guest_tests(
    tmp_path: Path, backend: str,
) -> None:
    app_source = PRELUDE + """\
int positive(int value)
in { assert(value > 0, "precondition checked"); }
body { return value; }
"""
    test_source = """\
module app_test;
import app: log, positive;

unittest {
    log("start\\n");
    assert(positive(-1) == -1);
    log("after\\n");
    version (D_NoBoundsChecks) {} else assert(0, "bounds are checked");
}
"""
    outcome = run_compiler_specific_project(
        tmp_path, backend, ["-check=in=on", "-check=bounds=on"],
        ["--disable-contracts", "--boundscheck=off"], app_source,
        test_source,
    )

    assert_passes_after_start(backend, outcome)


def run_compiler_specific_project(
    tmp_path: Path, backend: str, dmd_flags: list[str], ldc_flags: list[str],
    app_source: str, test_source: str,
) -> Outcome:
    project = tmp_path / "project"
    (project / "source").mkdir(parents=True)
    (project / "dub.json").write_text(
        json.dumps({
            "name": dub_name("app"), "targetType": "library",
            "dflags-dmd": dmd_flags, "dflags-ldc": ldc_flags,
        }),
        encoding="utf-8",
    )
    (project / "source" / "app.d").write_text(app_source, encoding="utf-8")
    (project / "source" / "app_test.d").write_text(
        test_source, encoding="utf-8",
    )

    return outcome_of(subprocess.run(
        [sb_path(), f"--backend={backend}", "--no-optimise-image",
         str(project)],
        capture_output=True,
        check=False,
        text=True,
        timeout=TIMEOUT,
    ))


# A dependency that does not build is a failure with the compiler's message.
# The root does not import it, so only the dub build of the dependency can
# report it. CTFE does not build native dependencies, and the build does not
# depend on the backend that runs afterwards.
def test_dependency_that_fails_to_build_is_reported(tmp_path: Path) -> None:
    app = tmp_path / "app"
    dependency = tmp_path / "dependency"
    (app / "source").mkdir(parents=True)
    (dependency / "source").mkdir(parents=True)
    (app / "dub.sdl").write_text(
        f'name "{dub_name("app")}"\ntargetType "library"\n'
        f'dependency "{dub_name("dep")}" path="../dependency"\n',
        encoding="utf-8",
    )
    (app / "source" / "app.d").write_text(
        "module app;\nunittest {}\n", encoding="utf-8",
    )
    (dependency / "dub.sdl").write_text(
        f'name "{dub_name("dep")}"\ntargetType "library"\n',
        encoding="utf-8",
    )
    (dependency / "source" / "dep.d").write_text(
        'module dep;\nstatic assert(false, "dependency does not build");\n',
        encoding="utf-8",
    )
    command = [
        sb_path(), "--backend=bytecode", "--no-optimise-image", str(app),
    ]

    result = subprocess.run(
        command, cwd=app, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )

    output = result.stdout + result.stderr
    assert result.returncode != 0, output
    assert "dependency does not build" in output, output


# CTFE does not build native dependencies or run dub build hooks, and the
# build does not depend on the backend that runs afterwards. The hook runs
# before the guest, so no guest runs here.
@pytest.mark.parametrize("stage,flags", [
    ("preBuildCommands", []),
    ("postBuildCommands", ["-noboundscheck"]),
])
def test_root_build_command_failure_is_reported(
    tmp_path: Path, stage: str, flags: list[str],
) -> None:
    marker = "root-build-command-failed"
    dependency = tmp_path / "dependency"
    (dependency / "source").mkdir(parents=True)
    (dependency / "dub.sdl").write_text(
        f'name "{dub_name("dep")}"\ntargetType "library"\n', encoding="utf-8",
    )
    (dependency / "source" / "dep.d").write_text(
        "module dep; int value() { return 1; }\n", encoding="utf-8",
    )
    (tmp_path / "source").mkdir()
    compiler_flags = list(flags)
    if flags:
        response = tmp_path / "checks.rsp"
        response.write_text("\n".join(json.dumps(flag) for flag in flags)
                            + "\n", encoding="utf-8")
        compiler_flags = [f"@{response}"]
    (tmp_path / "dub.json").write_text(json.dumps({
        "name": dub_name("app"), "targetType": "library",
        "dependencies": {dub_name("dep"): {"path": "dependency"}},
        "dflags": compiler_flags,
        stage: [f"echo {marker} >&2; exit 27"],
    }), encoding="utf-8")
    (tmp_path / "source" / "app.d").write_text(
        "module app; import dep;\nunittest { assert(value() == 1); }\n",
        encoding="utf-8",
    )
    command = [sb_path(), "--backend=bytecode", "--no-optimise-image",
               str(tmp_path)]
    result = subprocess.run(
        command, cwd=tmp_path, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )
    output = result.stdout + result.stderr
    assert result.returncode != 0, output
    assert marker in output, output
    assert "Command failed with exit code 27" in output, output
    assert not list((tmp_path / ".snakebite").rglob("dub-dependencies"))


def test_unrelated_root_compiler_flag_failure_is_reported(
    tmp_path: Path,
) -> None:
    dependency = tmp_path / "dependency"
    (dependency / "source").mkdir(parents=True)
    (dependency / "dub.sdl").write_text(
        f'name "{dub_name("dep")}"\ntargetType "library"\n', encoding="utf-8",
    )
    (dependency / "source" / "dep.d").write_text("module dep;\n", encoding="utf-8")
    (tmp_path / "source").mkdir()
    (tmp_path / "source" / "app.d").write_text(
        "module app; unittest {}\n", encoding="utf-8",
    )
    check_flag = "-check=in=off"
    (tmp_path / "dub.json").write_text(json.dumps({
        "name": dub_name("app"), "targetType": "library",
        "dependencies": {dub_name("dep"): {"path": "dependency"}},
        "dflags": [check_flag, "--not-a-real-compiler-option"],
    }), encoding="utf-8")
    command = [sb_path(), "--backend=bytecode", "--no-optimise-image",
               str(tmp_path)]
    result = subprocess.run(
        command, cwd=tmp_path, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )
    output = result.stdout + result.stderr
    assert result.returncode != 0, output
    assert "Dub dependency build failed" in output, output
    assert not list((tmp_path / ".snakebite").rglob("dub-dependencies"))


PRECONDITION_PROGRAM = """
    int positive(int x) in (x > 0) { return x; }
    unittest {
        log("start\\n");
        positive(-1);
        log("after\\n");
    }
"""


# `bin/sb` runs with the project as its working directory, so the response
# file is found by its relative name.
@pytest.mark.parametrize("backend", ["bytecode"])
@pytest.mark.parametrize("with_dependency", [False, True])
@pytest.mark.parametrize("flags,unchecked", [
    pytest.param(["-check=in=off"], None, id="preconditions"),
    pytest.param(["-noboundscheck"], True, id="noboundscheck"),
    pytest.param(["-check=bounds=on", "-noboundscheck"], False, id="check-bounds-first"),
])
def test_response_file_check_flags_apply_to_guest_and_image(
    tmp_path: Path, backend: str, with_dependency: bool,
    flags: list[str], unchecked: bool | None,
) -> None:
    response = tmp_path / "flags.rsp"
    imports = tmp_path / "imports with spaces"
    imports.mkdir()
    (imports / "marker.txt").write_text("response-file marker", encoding="utf-8")
    import_flag = f"-J{imports}"
    response.write_text("# check selection\n" + "\n".join(
        json.dumps(flag) for flag in [import_flag, *flags]
    ) + "\n", encoding="utf-8")
    response_argument = "@" + response.name
    (tmp_path / "source").mkdir()
    program = PRECONDITION_PROGRAM if unchecked is None else f"""\
unittest {{
    log("start\\n");
    version (D_NoBoundsChecks) enum unchecked = true;
    else enum unchecked = false;
    assert(unchecked == {str(unchecked).lower()});
    log("after\\n");
}}
"""
    (tmp_path / "source" / "app.d").write_text(
        PRELUDE + 'static assert(import("marker.txt") == "response-file marker");\n'
        + program, encoding="utf-8",
    )
    recipe = {
        "name": dub_name("app"), "targetType": "library",
        "dflags": (["-check=in=on"] if unchecked is None else [])
        + [response_argument],
    }
    if with_dependency:
        dependency = tmp_path / "dependency"
        (dependency / "source").mkdir(parents=True)
        (dependency / "dub.sdl").write_text(
            f'name "{dub_name("dep")}"\ntargetType "library"\n', encoding="utf-8",
        )
        (dependency / "source" / "dep.d").write_text(
            "module dep;\n", encoding="utf-8",
        )
        recipe["dependencies"] = {dub_name("dep"): {"path": "dependency"}}
    (tmp_path / "dub.json").write_text(json.dumps(recipe), encoding="utf-8")
    command = [sb_path(), f"--backend={backend}", "--no-optimise-image",
               str(tmp_path)]
    result = subprocess.run(
        command, cwd=tmp_path, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )
    assert_passes_after_start(backend, outcome_of(result))


@pytest.mark.parametrize("backend", BACKENDS)
def test_changed_response_file_changes_checks_on_cached_runs(
    tmp_path: Path, backend: str,
) -> None:
    response = tmp_path / "checks.rsp"
    (tmp_path / "source").mkdir()
    (tmp_path / "source" / "app.d").write_text(
        PRELUDE + PRECONDITION_PROGRAM, encoding="utf-8",
    )
    (tmp_path / "dub.json").write_text(json.dumps({
        "name": dub_name("app"), "targetType": "library", "dflags": [f"@{response}"],
    }), encoding="utf-8")
    for index, enabled in enumerate([False, True, False]):
        response.write_text(
            f"-check=in={'on' if enabled else 'off'}\n", encoding="utf-8",
        )
        outcome = outcome_of(subprocess.run(
            [sb_path(), f"--backend={backend}", "--no-optimise-image",
             str(tmp_path)],
            cwd=tmp_path, capture_output=True, check=False, text=True,
            timeout=TIMEOUT,
        ))
        if enabled:
            assert_raises_after_start(backend, outcome, "AssertError")
        else:
            assert_passes_after_start(backend, outcome)


BETTERC_DEPENDENCY = """\
module dep;
version (D_BetterC) enum moduleBetterC = true;
else enum moduleBetterC = false;
bool nativeBody() {
    version (D_BetterC) return true;
    else return false;
}
template selected(T) {
    version (D_BetterC) enum selected = true;
    else enum selected = false;
}
bool body(T)() {
    version (D_BetterC) return true;
    else return false;
}
version (D_BetterC) {
    bool conditional(T)() { return true; }
} else {
    bool conditional(T)() { return false; }
}
bool imported(T)() {
    import helper;
    return helperBody!T();
}
bool phobos(T)() {
    import std.algorithm.searching: countUntil;
    T[3] values = [1, 2, 3];
    return values[].countUntil(2) == 1;
}
bool druntime(T)() {
    import core.lifetime: emplace;
    T storage;
    emplace!T(&storage, T(7));
    return storage == 7;
}
mixin template Mixed(T) {
    version (D_BetterC) enum mixed = true;
    else enum mixed = false;
}
T positive(T)(T value) in (value > 0) { return value; }
"""


# One program asserts each way a dependency template sees `D_BetterC`.
@pytest.mark.parametrize("backend", BACKENDS)
def test_betterc_dependency_versions(tmp_path: Path, backend: str) -> None:
    dependency = tmp_path / "dependency"
    (dependency / "source").mkdir(parents=True)
    (dependency / "dub.sdl").write_text(
        f'name "{dub_name("dep")}"\ntargetType "library"\n', encoding="utf-8",
    )
    (dependency / "source" / "dep.d").write_text(
        BETTERC_DEPENDENCY, encoding="utf-8",
    )
    (dependency / "source" / "helper.d").write_text("""\
module helper;
bool helperBody(T)() {
    version (D_BetterC) return true;
    else return false;
}
""", encoding="utf-8")
    root = tmp_path / "root"
    (root / "source").mkdir(parents=True)
    (root / "dub.json").write_text(json.dumps({
        "name": dub_name("app"), "targetType": "library",
        "dependencies": {dub_name("dep"): {"path": "../dependency"}},
        "dflags": ["-betterC"],
        "dflags-dmd": ["-check=in=off"],
        "dflags-ldc": ["--enable-preconditions=false"],
        "libs-dmd": ["phobos2"],
        "configurations": [{
            "name": "unittest", "targetType": "executable",
            "mainSourceFile": "source/app.d",
        }],
    }), encoding="utf-8")
    (root / "source" / "app.d").write_text(PRELUDE + f"""
import dep;
mixin Mixed!int;
static assert(moduleBetterC);
static assert(selected!int);
version (D_ModuleInfo) static assert(false);
version (D_TypeInfo) static assert(false);
version (D_Exceptions) static assert(false);
unittest {{
    log("start\\n");
    assert(body!int());
    assert(conditional!int());
    assert(imported!int());
    assert(mixed);
    assert(phobos!int());
    assert(druntime!int());
    if (!__ctfe) assert(!nativeBody());
    assert(positive(-1) == -1);
    log("after\\n");
}}
extern(C) int main() {{
    foreach (test; __traits(getUnitTests, app)) test();
    return 0;
}}
""", encoding="utf-8")
    command = [sb_path(), f"--backend={backend}", "--no-optimise-image",
               str(root)]
    result = subprocess.run(
        command, cwd=root, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )
    assert_passes_after_start(backend, outcome_of(result))


@pytest.mark.parametrize("backend", [*BACKENDS, "native-ldc"])
@pytest.mark.parametrize("entry", ["c", "d", "betterc", "explicit"])
def test_dependency_entry_startup(
    tmp_path: Path, backend: str, entry: str,
) -> None:
    dependency = tmp_path / "dependency"
    (dependency / "source").mkdir(parents=True)
    (dependency / "dub.sdl").write_text(
        'name "dep"\ntargetType "library"\n', encoding="utf-8",
    )
    (dependency / "source" / "dep.d").write_text("""\
module dep;
import core.stdc.stdio;
shared static this() { fputs("DEP_CTOR\\n", stderr); }
static this() { fputs("DEP_TLS_CTOR\\n", stderr); }
int ordinary() {
    version (D_BetterC) return 1;
    else return 2;
}
extern(C) int callback(int function() next) { return next(); }
""", encoding="utf-8")
    root = tmp_path / "root"
    (root / "source").mkdir(parents=True)
    (root / "dub.json").write_text(json.dumps({
        "name": "app", "targetType": "executable",
        "dependencies": {"dep": {"path": "../dependency"}},
        "dflags": ["-betterC"] if entry == "betterc" else [],
        "libs-dmd": ["phobos2"],
        "mainSourceFile": "source/app.d",
        "configurations": [{
            "name": "unittest", "targetType": "executable",
            "mainSourceFile": "source/app.d",
        }],
    }), encoding="utf-8")
    linkage = "" if entry == "d" else "extern(C) "
    startup = "" if entry == "betterc" else """\
shared static this() { fputs("ROOT_CTOR\\n", stderr); }
static this() { fputs("ROOT_TLS_CTOR\\n", stderr); }
unittest {
    fputs("UNITTEST\\n", stderr);
    assert(ordinary() == 2);
    assert(callback(&next) == 7);
}
"""
    initialize = "" if entry != "explicit" else """\
    fputs("INIT\\n", stderr);
    if (!rt_init()) return 3;
"""
    (root / "source" / "app.d").write_text(f"""\
module app;
import dep;
import core.stdc.stdio;
extern(C) int rt_init();
{startup}
extern(C) int next() {{ return 7; }}
{linkage}int main() {{
{initialize}    fputs("MAIN\\n", stderr);
    return ordinary() == 2 && callback(&next) == 7 ? 0 : 1;
}}
""", encoding="utf-8")
    if backend in ["native", "native-ldc"]:
        compiler = native_compiler() if backend == "native" else shutil.which("ldc2")
        if compiler is None:
            pytest.skip("ldc2 is not on PATH")
        command = ["dub", "test", f"--compiler={compiler}"]
    else:
        command = [sb_path(), f"--backend={backend}", "--no-optimise-image", str(root)]
    result = subprocess.run(
        command, cwd=root, capture_output=True, check=False, text=True,
        timeout=TIMEOUT,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    markers = [line for line in output.splitlines() if line in {
        "DEP_CTOR", "DEP_TLS_CTOR", "ROOT_CTOR", "ROOT_TLS_CTOR",
        "UNITTEST", "INIT", "MAIN",
    }]
    if entry in ["c", "betterc"]:
        assert markers == ["MAIN"], output
    else:
        assert markers.count("DEP_CTOR") == 1, output
        assert markers.count("DEP_TLS_CTOR") == 1, output
        assert markers.count("ROOT_CTOR") == 1, output
        assert markers.count("ROOT_TLS_CTOR") == 1, output
        assert markers.index("DEP_CTOR") < markers.index("DEP_TLS_CTOR"), output
        assert markers.index("ROOT_CTOR") < markers.index("ROOT_TLS_CTOR"), output
        assert markers.index("DEP_CTOR") < markers.index("ROOT_CTOR"), output
        assert markers.index("DEP_TLS_CTOR") < markers.index("ROOT_TLS_CTOR"), output
        if entry == "d":
            assert markers.count("UNITTEST") == 1, output
            assert "MAIN" not in markers, output
        else:
            assert markers[0] == "INIT", output
            assert markers[-1] == "MAIN", output


# The tests can run in parallel (see build/pytest-workers.sh) because the
# state that they share, the `.snakebite` directory and the dub package store,
# is keyed by project path and published with an atomic rename.
if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
