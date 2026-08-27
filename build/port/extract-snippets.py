#!/usr/bin/env python3
"""Extract guest-program snippets from a D test tree.

Test suites embed the D program under study as a `q{...}` token string
handed to a harness call. This pulls those bodies out by brace matching,
which a regex cannot do.

Each snippet is emitted with whatever follows the closing brace up to the
statement's semicolon. That tail carries the expectation - a snippet that
asserts something deliberately false is paired with a
`.shouldThrowWithMessage(...)` naming the real value - so dropping it turns
a passing test into a failing one.

    ./extract-snippets.py --quickbite ../quickbite/tests/ut/backends/runner
    ./extract-snippets.py --snakebite tests
"""

import argparse
import json
import os
import re
import sys

# The harness call whose argument is the guest program, per repo.
CALLS = {
    "quickbite": r"runBackendSourceFixtureTest\w*!backend\(q\{",
    "snakebite": r"q\{",
}


def snippets(source, pattern, origin):
    for match in re.finditer(pattern, source):
        opening = match.end() - 1
        depth = 0
        for i in range(opening, len(source)):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    break
        else:
            continue

        end = source.find(";", i)
        yield {
            "origin": origin,
            "line": source.count("\n", 0, opening) + 1,
            "body": source[opening + 1:i],
            "tail": source[i + 1:end] if end != -1 else "",
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quickbite", metavar="DIR")
    parser.add_argument("--snakebite", metavar="DIR")
    parser.add_argument("-o", "--output", default="-")
    args = parser.parse_args()

    found = []
    for flavour in ("quickbite", "snakebite"):
        root = getattr(args, flavour)
        if root is None:
            continue
        for directory, _, files in os.walk(root):
            for name in sorted(files):
                if not name.endswith(".d"):
                    continue
                path = os.path.join(directory, name)
                with open(path) as handle:
                    found += snippets(handle.read(), CALLS[flavour], path)

    out = sys.stdout if args.output == "-" else open(args.output, "w")
    json.dump(found, out)
    print(f"{len(found)} snippets", file=sys.stderr)


if __name__ == "__main__":
    main()
