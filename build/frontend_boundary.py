#!/usr/bin/env python3
"""Fail when an own D file outside the frontend package imports dmd.

Only `source/snakebite/frontend/` names dmd modules (ADR 0015). Other code
takes node types and enums from `snakebite.frontend.ast` and reaches every
other dmd function through `snakebite.frontend.compiler.inFrontend`, which
takes the frontend lock.

Usage: frontend_boundary.py [--root DIRECTORY] [--expect FILE] FILE...

Each FILE is checked when it is own code: a file under `source/`, `tests/`,
`bench/`, `validation/` or `acceptance/` of the project (or of `--root`),
except the frontend package and the `dmd.iasm` shim (`source/dmd/`). Generated
and vendored D code is not own code: it is not under those directories, or it
is not given. With `--expect`, the check passes only when FILE, and no other
file, imports dmd: the build runs it on a fixture project before it checks
the files of a binary.

What the check reads is code: comments and the contents of string literals
are not (except the module name that `imported!` takes). A token string
(`q{...}`) is code. An import that a string mixin makes from other strings is
not seen.
"""

import pathlib
import re
import sys

PROJECT = pathlib.Path(__file__).resolve().parent.parent
OWN = ("source/", "tests/", "bench/", "validation/", "acceptance/")
ALLOWED = ("source/snakebite/frontend/", "source/dmd/")


def code(text):
    """`text` with comments and the contents of string literals blanked.

    A string that `imported!` takes keeps its contents: it names a module.
    """
    out = list(text)
    i, n = 0, len(text)

    def blank(start, end):
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    def skip_quoted(start, quote):
        j = start + 1
        while j < n and text[j] != quote:
            j += 2 if text[j] == "\\" else 1
        return j

    while i < n:
        pair = text[i:i + 2]
        if pair == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif pair == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif pair == "/+":
            depth, j = 1, i + 2
            while j < n and depth:
                if text[j:j + 2] == "/+":
                    depth, j = depth + 1, j + 2
                elif text[j:j + 2] == "+/":
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif text[i] in "\"'`":
            quote = text[i]
            raw = quote == "`" or (quote == '"' and text[i - 1:i] == "r"
                                   and not re.match(r"\w", text[i - 2:i - 1]))
            j = text.find(quote, i + 1) if raw else skip_quoted(i, quote)
            j = n if j < 0 else j
            if not re.search(r"\bimported\s*!\s*$", text[:i]):
                blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)


IMPORT = re.compile(r"\bimport\s+(?=[A-Za-z_])([^;:]*)[;:]")
IMPORTED = re.compile(r"\bimported\s*!\s*\"(dmd(?:\.[\w.]*)?)\"")


def dmd_imports(text):
    """(line, module) of each dmd module that `text` imports."""
    checked = code(text)
    for match in IMPORT.finditer(checked):
        for module in match.group(1).split(","):
            name = module.split("=")[-1].strip()
            if name == "dmd" or name.startswith("dmd."):
                yield checked.count("\n", 0, match.start()) + 1, name
    for match in IMPORTED.finditer(checked):
        yield checked.count("\n", 0, match.start()) + 1, match.group(1)


def is_checked(path, root):
    try:
        relative = path.resolve().relative_to(root).as_posix()
    except ValueError:
        return False
    return relative.startswith(OWN) and not relative.startswith(ALLOWED)


def violations(paths, root=PROJECT):
    found = []
    for path in paths:
        path = pathlib.Path(path)
        if path.suffix != ".d" or not is_checked(path, root):
            continue
        for line, module in dmd_imports(path.read_text()):
            found.append((path, line, module))
    return found


def main(arguments):
    root, expected = PROJECT, None
    if arguments[:1] == ["--root"]:
        root, arguments = pathlib.Path(arguments[1]).resolve(), arguments[2:]
    if arguments[:1] == ["--expect"]:
        expected, arguments = pathlib.Path(arguments[1]).resolve(), arguments[2:]
    found = violations(arguments, root)
    if expected is not None:
        if {path.resolve() for path, _, _ in found} == {expected}:
            return 0
        sys.stderr.write(f"frontend_boundary.py does not report exactly {expected}:"
                         f" it reports {sorted({str(p) for p, _, _ in found})}\n")
        return 1
    for path, line, module in found:
        sys.stderr.write(
            f"{path}:{line}: error: imports `{module}`. Only the frontend package"
            " (source/snakebite/frontend/) imports dmd. Take node types and enums"
            " from `snakebite.frontend.ast`; call any other dmd function through"
            " `snakebite.frontend.compiler.inFrontend`, which takes the frontend"
            " lock. See docs/adr/0015-frontend-memory-uses-an-arena.md.\n")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
