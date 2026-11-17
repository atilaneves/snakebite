"""Fail when an own D file outside the frontend package imports dmd.

Only `source/snakebite/frontend/` names dmd modules (ADR 0015). Other code
takes node types and enums from `snakebite.frontend.ast` and reaches every
other dmd function through `snakebite.frontend.compiler.inFrontend`, which
takes the frontend lock.

Usage: frontend_boundary.py FILE...
       frontend_boundary.py --selftest DIRECTORY

Each FILE must be own code: a file under `source/`, `tests/`, `bench/`,
`validation/` or `acceptance/` of the project. The frontend package and the
`dmd.iasm` shim (`source/dmd/`) may import dmd; every other file may not.
The vendored code in `vendor/` is the one named exception: it is skipped.
A FILE in no known directory is an error, not a skip: the check cannot say
anything about a file it does not know, and a build that passes it with
nothing checked proves nothing. Generated D code must not be given to it, or
its directory must be added here. A run that is given files and checks none
also fails.

`--selftest` runs on a fixture project: each file `reported_*.d` outside the
frontend package must be reported, and every other file in it must not be.

What the check reads is code: comments and the contents of string literals
are not, except the module name that `imported!` takes (with or without
parentheses, from a plain, raw, back-quoted, hex or delimited string, or
from adjacent literals). A token string (`q{...}`) is code. An import that
a string mixin builds, and one through an alias of `imported`, are not seen.
"""

import pathlib
import re
import sys

PROJECT = pathlib.Path(__file__).resolve().parent.parent
OWN = ("source/", "tests/", "bench/", "validation/", "acceptance/")
ALLOWED = ("source/snakebite/frontend/", "source/dmd/")
# Vendored third-party D code that dub puts on the compile line of each
# binary. It is not ours to constrain, and it is the only such directory.
VENDORED = ("vendor/",)


# Everything that is not code starts with one of these characters. A single
# character class makes the scan fast: the regex engine skips code at C speed.
_START = re.compile(r"[/\"'`]")
_PLAIN = re.compile(r'"[^"\\]*(?:\\.[^"\\]*)*"', re.DOTALL)
_CHAR = re.compile(r"'(?:\\[^'\n]*|[^'\\\n])'")
_HEREDOC = re.compile(r'q"([A-Za-z_]\w*)\r?\n.*?\n\1"', re.DOTALL)
_NEST = re.compile(r"/\+|\+/")
_BRACKETS = {"(": ")", "[": "]", "<": ">", "{": "}"}
_IMPORT = re.compile(r"\bimport\s+(?=[A-Za-z_])([^;:]*)[;:]")
_IMPORTED = re.compile(r"\bimported\s*!\s*(?:\(\s*)?((?:\x00\d*\x00\s*)+)")
_LITERAL = re.compile(r"\x00(\d*)\x00")


def _skip_nested(text, i):
    """End of the `/+ +/` comment that starts at `i`; they nest."""
    depth = 0
    while True:
        m = _NEST.search(text, i)
        if not m:
            return len(text)
        depth += 1 if m.group() == "/+" else -1
        i = m.end()
        if depth == 0:
            return i


def _skip_bracketed(text, i):
    """End of the `q"(...)"` string whose opening bracket is at `i`."""
    opening, closing = text[i], _BRACKETS[text[i]]
    depth = 0
    while i < len(text):
        if text[i] == opening:
            depth += 1
        elif text[i] == closing:
            depth -= 1
            if depth == 0:
                return min(i + 2, len(text))
        i += 1
    return len(text)


def _delimited_string(text, q):
    """End of the `q"..."` string whose `q` is at `q`, or -1."""
    delimiter = text[q + 2:q + 3]
    if delimiter in _BRACKETS:
        return _skip_bracketed(text, q + 2)
    if delimiter.isalpha() or delimiter == "_":
        m = _HEREDOC.match(text, q)
        return m.end() if m else -1
    end = text.find(delimiter + '"', q + 3)
    return -1 if end < 0 else end + 2


def _string_start(text, i):
    """(start, end) of the string literal whose `"` is at `i`, or None."""
    prefix = text[i - 1:i] if i else ""
    if prefix in ("q", "r", "x") and not re.match(r"\w", text[i - 2:i - 1]):
        if prefix == "q":
            end = _delimited_string(text, i - 1)
        else:
            end = text.find('"', i + 1) + 1 or -1
        return (i - 1, end) if end > 0 else None
    m = _PLAIN.match(text, i)
    return (i, m.end()) if m else None


def code(text):
    """(`text` without comments and strings, the strings).

    A comment becomes a space and a string becomes `\\x00N\\x00`, where N is
    the index in the second value (empty when the file has no `imported`).
    Each keeps its line breaks, so line numbers stay right. A token string
    (`q{...}`) is code and stays.
    """
    keep = "imported" in text
    out, strings, pos, n = [], [], 0, len(text)
    while True:
        m = _START.search(text, pos)
        if not m:
            break
        i = m.start()
        quote, following = text[i], text[i + 1:i + 2]
        comment = False
        if quote == "/":
            if following == "/":
                end = text.find("\n", i)
                end = n if end < 0 else end
            elif following == "*":
                end = text.find("*/", i + 2)
                end = n if end < 0 else end + 2
            elif following == "+":
                end = _skip_nested(text, i)
            else:
                out.append(text[pos:i + 1])
                pos = i + 1
                continue
            start, comment = i, True
        elif quote == "`":
            end = text.find("`", i + 1)
            start, end = i, n if end < 0 else end + 1
        elif quote == "'":
            c = _CHAR.match(text, i)
            if not c:
                out.append(text[pos:i + 1])
                pos = i + 1
                continue
            start, end = i, c.end()
        else:
            found = _string_start(text, i)
            if not found:
                out.append(text[pos:i + 1])
                pos = i + 1
                continue
            start, end = found
        out.append(text[pos:start])
        skipped = text[start:end]
        if comment:
            out.append(" ")
        elif quote == "'":
            out.append("''")
        elif keep:
            out.append("\x00%d\x00" % len(strings))
            strings.append(skipped)
        else:
            out.append("\x00\x00")
        newlines = skipped.count("\n")
        if newlines:
            out.append("\n" * newlines)
        pos = end
    out.append(text[pos:])
    return "".join(out), strings


_BODY = [
    re.compile(r'(?<!\w)[rx]"(.*)"\Z', re.DOTALL),
    re.compile(r"`(.*)`\Z", re.DOTALL),
    re.compile(r'"(.*)"\Z', re.DOTALL),
    re.compile(r'q"[^\w\s(\[<{](.*).?"\Z', re.DOTALL),
    re.compile(r'q"[(\[<{](.*)[)\]>}]"\Z', re.DOTALL),
    re.compile(r'q"[A-Za-z_]\w*\r?\n(.*)\n[A-Za-z_]\w*"\Z', re.DOTALL),
]


def _contents(literal):
    for pattern in _BODY:
        m = pattern.match(literal)
        if m:
            return m.group(1)
    return ""


def dmd_imports(text):
    """(line, module) of each dmd module that `text` imports."""
    checked, strings = code(text)
    for match in _IMPORT.finditer(checked):
        for module in match.group(1).split(","):
            name = module.split("=")[-1].strip()
            if name == "dmd" or name.startswith("dmd."):
                yield checked.count("\n", 0, match.start()) + 1, name
    for match in _IMPORTED.finditer(checked):
        name = "".join(_contents(strings[int(index)])
                       for index in _LITERAL.findall(match.group(1)) if index)
        if name == "dmd" or name.startswith("dmd."):
            yield checked.count("\n", 0, match.start()) + 1, name


def relative_path(path, root):
    """`path` relative to `root`, or None when it is not under it."""
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return None


def violations(paths, root=PROJECT):
    """(violations, files that are not own code, number of files checked)."""
    found, unknown, checked = [], [], 0
    for path in map(pathlib.Path, paths):
        if path.suffix != ".d":
            continue
        relative = relative_path(path, root)
        if relative is not None and relative.startswith(VENDORED):
            continue
        if relative is None or not relative.startswith(OWN):
            unknown.append(path)
            continue
        if relative.startswith(ALLOWED):
            continue
        checked += 1
        for line, module in dmd_imports(path.read_text()):
            found.append((path, line, module))
    return found, unknown, checked


def selftest(root):
    """Check the fixture project at `root`; return the number of faults."""
    root = pathlib.Path(root).resolve()
    files = sorted(root.rglob("*.d"))
    found, unknown, _ = violations(files, root)
    reported = {path.resolve() for path, _, _ in found}
    expected = {path.resolve() for path in files
                if path.name.startswith("reported_")
                and not relative_path(path, root).startswith(ALLOWED)}
    faults = 0
    for path in sorted(expected - reported):
        sys.stderr.write(f"{path}: the check does not report this file\n")
        faults += 1
    for path in sorted(reported - expected):
        sys.stderr.write(f"{path}: the check reports this file, wrongly\n")
        faults += 1
    for path in unknown:
        sys.stderr.write(f"{path}: not under a known directory\n")
        faults += 1
    if not expected:
        sys.stderr.write("the fixture has no reported_*.d file\n")
        faults += 1
    return faults


def main(arguments):
    if arguments[:1] == ["--selftest"]:
        return 1 if selftest(arguments[1]) else 0
    found, unknown, checked = violations(arguments)
    for path in unknown:
        sys.stderr.write(
            f"{path}: error: not own code of this project. The check knows"
            f" only {', '.join(OWN)} under {PROJECT}; it cannot say that a"
            " file elsewhere does not import dmd, and a build that passes"
            " it unchecked proves nothing. Do not give generated or vendored"
            " D code to the check.\n")
    for path, line, module in found:
        sys.stderr.write(
            f"{path}:{line}: error: imports `{module}`. Only the frontend package"
            " (source/snakebite/frontend/) imports dmd. Take node types and enums"
            " from `snakebite.frontend.ast`; call any other dmd function through"
            " `snakebite.frontend.compiler.inFrontend`, which takes the frontend"
            " lock. See docs/adr/0015-frontend-memory-uses-an-arena.md.\n")
    if arguments and not checked and not unknown and not found:
        sys.stderr.write("error: the check was given files and checked none\n")
        return 1
    return 1 if found or unknown else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
