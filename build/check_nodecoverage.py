#!/usr/bin/env python3
"""Check frontend node coverage freshness, with optional compile-fail controls."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def verify(frontend: Path, manifest: Path) -> None:
    expected = dict(
        (name, digest)
        for digest, name in (line.split(maxsplit=1) for line in manifest.read_text().splitlines())
    )
    actual = {
        str(path.relative_to(frontend)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(frontend.rglob("*.d"))
    }
    if actual != expected:
        added = sorted(actual.keys() - expected.keys())
        removed = sorted(expected.keys() - actual.keys())
        changed = sorted(name for name in actual.keys() & expected.keys()
                         if actual[name] != expected[name])
        detail = "; ".join(f"{kind}: {', '.join(names)}" for kind, names in
                           (("added", added), ("removed", removed), ("changed", changed))
                           if names)
        raise ValueError("node coverage: stale frontend fingerprint; " + detail)


def verify_forwarding(frontend: Path, contract: Path) -> None:
    # Source hashes first fix the syntax this bounded extraction accepts.
    pattern = re.compile(
        r"void visit\(AST(?:Codegen)?\.(\w+) [se]\) "
        r"\{ visit\(cast\(AST(?:Codegen)?\.(\w+)\)[se]\); \}")
    edges = {}
    for name in ("visitor/package.d", "visitor/parsetime.d"):
        edges.update(pattern.findall((frontend / name).read_text()))
    records = re.findall(r"Forward!\((\w+),\s*(\w+)\)", contract.read_text())
    if not records:
        raise ValueError("node coverage: no forwarding records found")
    for node, target in records:
        if edges.get(node) != target:
            raise ValueError(f"node coverage: wrong frontend forwarding edge: {node} -> {target}")


def compile_controls(compiler: str, frontend: Path) -> None:
    command = [
        compiler, "-o-", "-version=NoBackend", "-version=GC",
        "-version=NoMain", "-version=MARS", "-version=DMDLIB",
        "-I" + str(ROOT / "source"), "-I" + str(ROOT / "vendor/dmd-backend"),
        "-I" + str(frontend.parent), "-J" + str(frontend / "res"),
        "-J" + str(frontend.parents[2] / "generated/dub"),
        str(ROOT / "tests/nodecoverage/controls.d"),
        str(ROOT / "tests/nodecoverage/addednode.d"),
    ]
    controls = {
        "": "",
        "MissingLeaf": "ParentOnly has no exact AddAssignExp visit",
        "CheckedMissing": "ModeVisitor!true has no exact AddAssignExp visit",
        "WrongTarget": "wrong forwarding target: AddAssignExp",
        "ForwardCycle": "forwarding cycle: AddAssignExp",
        "DuplicateRecord": "duplicate forwarding record: AddAssignExp",
        "MissingTarget": "forwarding target has no exact BinAssignExp visit",
        "MissingClass": "Visitor node absent from class inventory",
        "MissingVisit": "class absent from Visitor inventory",
        "AddedModule": "class absent from Visitor inventory: AddedNode",
    }
    for name, diagnostic in controls.items():
        argv = command + (["-version=" + name] if name else [])
        result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
        output = result.stdout + result.stderr
        passed = result.returncode == 0 if not name else (
            result.returncode != 0 and "node coverage: " + diagnostic in output)
        if not passed:
            raise RuntimeError(f"{name or 'Success'} failed (exit {result.returncode}):\n{output}")
        print(f"{name or 'Success'}: exit {result.returncode}; expected diagnostic verified")


def fingerprint_controls() -> None:
    with tempfile.TemporaryDirectory(prefix="nodecoverage-") as directory:
        root = Path(directory)
        frontend = root / "frontend"
        frontend.mkdir()
        source = frontend / "expression.d"
        source.write_text("class Expression { int flags; }\n")
        original = source.read_bytes()
        manifest = root / "hashes.txt"
        manifest.write_text(hashlib.sha256(original).hexdigest() + "  expression.d\n")
        verify(frontend, manifest)
        for name, change in (
            ("StaleFingerprint", lambda: source.write_bytes(original + b"// changed\n")),
            ("NewSchemaMember", lambda: source.write_bytes(original.replace(
                b"int flags;", b"int flags; int addedFlag;"))),
            ("AddedModuleFingerprint", lambda: (frontend / "added.d").write_text(
                "class AddedNode : Expression {}\n")),
        ):
            source.write_bytes(original)
            change()
            try:
                verify(frontend, manifest)
            except ValueError as error:
                if "node coverage: stale frontend fingerprint" not in str(error):
                    raise
                print(f"{name}: expected fingerprint failure verified")
            else:
                raise RuntimeError(f"{name}: fingerprint unexpectedly accepted")


def forwarding_controls(frontend: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="nodecoverage-edge-") as directory:
        wrong = Path(directory) / "wrong.d"
        wrong.write_text("Forward!(AddAssignExp, BinExp)")
        try:
            verify_forwarding(frontend, wrong)
        except ValueError as error:
            if "wrong frontend forwarding edge: AddAssignExp -> BinExp" not in str(error):
                raise
            print("WrongFrontendEdge: expected source-edge failure verified")
        else:
            raise RuntimeError("WrongFrontendEdge: invalid source edge accepted")


def locate_frontend() -> Path:
    result = subprocess.run(["dub", "describe", "--config=unittest"],
                            cwd=ROOT, text=True, capture_output=True, check=True)
    description = json.loads(result.stdout)
    roots = {Path(package["path"]) / path / "dmd"
             for package in description["packages"]
             for path in package.get("importPaths", [])
             if (Path(package["path"]) / path / "dmd/expression.d").is_file()}
    if len(roots) != 1:
        raise RuntimeError(f"expected one frontend tree, found {sorted(map(str, roots))}")
    return roots.pop()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controls", action="store_true",
                        help="run positive and negative coverage controls")
    parser.add_argument("--compiler", default=os.environ.get("DC", "dmd"))
    parser.add_argument("--frontend", type=Path)
    args = parser.parse_args()
    try:
        frontend = args.frontend or locate_frontend()
        verify(frontend, ROOT / "build/nodecoverage/frontend-source-hashes.txt")
        verify_forwarding(frontend, ROOT / "source/snakebite/backends/nodecoverage.d")
        if not args.controls:
            return 0
        forwarding_controls(frontend)
        compile_controls(args.compiler, frontend)
        fingerprint_controls()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
