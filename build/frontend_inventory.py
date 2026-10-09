#!/usr/bin/env python3
"""Check the pinned whole frontend source inventory before a build succeeds."""

import argparse
import hashlib
from pathlib import Path
import re
import sys


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frontend", type=Path)
    parser.add_argument("--manifest", type=Path,
                        default=Path(__file__).parent / "nodecoverage/frontend-source-hashes.txt")
    parser.add_argument("--forwarding-contract", type=Path,
                        default=Path(__file__).parent.parent /
                        "source/snakebite/backends/nodecoverage.d")
    args = parser.parse_args()
    try:
        verify(args.frontend, args.manifest)
        verify_forwarding(args.frontend, args.forwarding_contract)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
