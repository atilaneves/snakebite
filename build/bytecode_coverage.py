"""Write LCOV from optimized LDC counters in the bytecode backend."""

import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parent.parent
BYTECODE = ROOT / "source/snakebite/backends/bytecode"


def instrument_bytecode(directory):
    output = subprocess.check_output(
        ["ninja", "-t", "commands", "bin/sb-prof"], cwd=ROOT, text=True
    )
    commands = [shlex.split(line) for line in output.splitlines()]
    # Use the regular target's flags and objects for the chained-dispatch
    # build. Instrument the bytecode partition without rebuilding its dependencies.
    (compile_command,) = (
        command for command in commands
        if "-c" in command and str(BYTECODE / "jit.d") in command
        and any(arg.startswith("-makedeps=") for arg in command)
    )
    (link_command,) = (
        command for command in commands if "-ofbin/sb-prof" in command
    )
    (object_option,) = (arg for arg in compile_command if arg.startswith("-of"))
    (dependencies_option,) = (
        arg for arg in compile_command if arg.startswith("-makedeps=")
    )
    instrumented = directory / "bytecode.o"
    object_path = object_option[len("-of"):]
    compile_command[compile_command.index(object_option)] = f"-of{instrumented}"
    compile_command[compile_command.index(dependencies_option)] = (
        f"-makedeps={directory / 'bytecode.dep'}"
    )
    link_command[link_command.index(object_path)] = str(instrumented)
    executable = directory / "sb-source-cov"
    link_command[link_command.index("-ofbin/sb-prof")] = f"-of{executable}"
    for command in (compile_command, link_command):
        subprocess.run([*command, "-cov"], cwd=ROOT, check=True)
    return executable


def lcov_report(listings):
    records = []
    covered_sources = set()
    for listing in sorted(listings.glob("*.lst")):
        rows = listing.read_text().splitlines()
        footer = re.fullmatch(r"(.+\.d) (?:is \d+% covered|has no code)", rows[-1])
        if footer is None:
            raise ValueError(f"Invalid LDC coverage listing {listing}")
        source = Path(footer[1])
        if source.parent != BYTECODE:
            continue
        entries = [row.split("|", 1) for row in rows[:-1]]
        if [text for _, text in entries] != source.read_text().splitlines():
            raise ValueError(f"Coverage listing differs from source {source}")
        counts = {
            number: int(count) for number, (count, _) in enumerate(entries, 1)
            if count.strip()
        }
        if not counts:
            continue
        covered_sources.add(source.name)
        records.extend(("TN:", f"SF:{source.relative_to(ROOT).as_posix()}"))
        records.extend(f"DA:{line},{count}" for line, count in counts.items())
        records.extend((f"LF:{len(counts)}", f"LH:{sum(n > 0 for n in counts.values())}",
                        "end_of_record"))
    if not {"jit.d", "jitflow.d", "vm.d"} <= covered_sources:
        raise ValueError("Missing bytecode source counters")
    return "\n".join(records) + "\n"


def main(fixture, report):
    with TemporaryDirectory(dir=ROOT / "coverage-runs") as directory:
        directory = Path(directory)
        executable = instrument_bytecode(directory)
        guest = directory / "guest"
        shutil.copytree(fixture, guest, ignore=shutil.ignore_patterns(".snakebite"))
        subprocess.run(
            [str(executable), "-b", "bytecode", "--no-optimise-image", str(guest)],
            cwd=ROOT, check=True,
        )
        report.write_text(lcov_report(guest))


if __name__ == "__main__":
    main(*(Path(arg).resolve() for arg in sys.argv[1:]))
