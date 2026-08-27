#!/usr/bin/env python3
"""Turn extracted guest snippets into snakebite test cases.

quickbite states a guest program as a module of `unittest` blocks and runs
them all. snakebite's harness runs a `main` and checks the exit status, so
the transform is: rename each `unittest` block to a `main`, and assert the
status. Several blocks become one `main` calling each in turn, matching the
order druntime runs them in, stopping at the first failure.

The expected status comes from the call-site tail the extractor kept: a
snippet paired with `.shouldThrowWithMessage(...)` asserts something
deliberately false to reveal a computed value, so it exits 1, not 0. The
message itself is lost - `run` reports a guest failure as a status.

    ./extract-snippets.py --quickbite DIR | ./port-snippet.py -m ut.ported

Snippets the harness cannot express are reported on stderr and skipped
rather than emitted broken. See ai/research-porting-quickbite-tests.md.
"""

import argparse
import json
import re
import sys

# Where a snippet belongs, by the most specific construct it reaches. First
# match wins, so the order is most specific first: a snippet declaring a
# class inside a template is a template test, not a class test.
#
# quickbite files a snippet by the file its author happened to open, which
# put 497 of its 1344 in one 16629-line `expressions.d`. Routing by AST node
# instead is derived from the snippet, so it stays true as the corpus grows.
ROUTES = (
    ("templates", ("TemplateDeclaration", "TemplateInstance")),
    ("exceptions", ("ThrowStatement", "TryCatchStatement",
                    "TryFinallyStatement", "ThrowExp")),
    ("classes", ("ClassDeclaration", "InterfaceDeclaration")),
    ("delegates", ("DelegateExp", "FuncExp", "DelegatePtrExp",
                   "DelegateFuncptrExp")),
    ("associative", ("AssocArrayLiteralExp", "AssociativeArrayDeclaration",
                    "TypeAArray")),
    ("structs", ("StructDeclaration", "UnionDeclaration")),
    ("enums", ("EnumDeclaration", "EnumMember")),
    ("arrays", ("ArrayLiteralExp", "SliceExp", "IndexExp", "CatExp",
                "CatAssignExp", "TypeDArray", "TypeSArray")),
    ("control", ("ForeachStatement", "ForeachRangeStatement",
                      "SwitchStatement", "CaseStatement", "WhileStatement",
                      "DoStatement", "ForStatement", "GotoStatement")),
    ("allocation", ("NewExp", "DeleteExp")),
)
DEFAULT_ROUTE = "expressions"


def route_for(nodes):
    """Which ported module a snippet belongs in, by what its AST reaches."""
    reached = set(nodes)
    for module, markers in ROUTES:
        if reached.intersection(markers):
            return module
    return DEFAULT_ROUTE

BLOCK = re.compile(r"^([ \t]*)(?:@\([^)]*\)[ \t]*\n[ \t]*)?unittest[ \t]*\{", re.M)
CALL = re.compile(r"\w+\s*\(")


def top_level_lines(body):
    """Yield each line of `body` that sits at brace depth zero."""
    depth = 0
    for line in body.split("\n"):
        if depth == 0:
            yield line
        depth += line.count("{") - line.count("}")


def excuse_for(body, tail):
    """Why this snippet cannot be ported, or None."""
    if tail.strip().rstrip(")").strip().startswith(","):
        return "needs import paths or frontend flags"
    if "classinfo" in body:
        return "faults the host process, which runs guests in-process"
    if re.search(r"\bmain\s*\(\s*[\w\[\]]+\s+\w+", body):
        return "the native oracle calls a zero-argument main"

    # The native oracle mixes the snippet into a struct at function scope,
    # where a guest function is nested, and D reserves UFCS for functions at
    # module scope.
    declared = set()
    for line in top_level_lines(body):
        match = re.match(r"\s*(?:[\w\[\]\*\.!\(\)]+\s+)+(\w+)\s*\(", line)
        if match and match.group(1) not in ("if", "while", "for", "switch"):
            declared.add(match.group(1))
    for name in declared:
        if re.search(rf"\.{name}\b", body):
            return "calls a guest function through UFCS"

    # Same nesting: a delegate literal that closes over a local needs a
    # context pointer the template's `alias` parameter cannot carry once the
    # template is itself nested.
    if re.search(r"\(\s*alias\s+\w+\s*\)", body) and re.search(r"!\(\s*\{", body):
        return "passes a closure to a guest template"

    # A real module runs a variable's initialiser in a module constructor.
    # The native oracle mixes the snippet into a `static:` struct at function
    # scope, where the same initialiser must fold at compile time instead.
    for line in top_level_lines(body):
        stripped = line.strip()
        if stripped.startswith(("//", "unittest", "@", "}", "{")) or not stripped:
            continue
        if "=" in stripped and CALL.search(stripped.split("=", 1)[1]):
            return "module-level variable with a runtime initialiser"
    return None


def rename_blocks(body):
    """Rewrite `unittest` blocks into a `main`, or None if there are none."""
    count = len(BLOCK.findall(body))
    if count == 0:
        return None
    if count == 1:
        return BLOCK.sub(r"\1void main() {", body, count=1)

    index = [0]

    def name(match):
        index[0] += 1
        return f"{match.group(1)}void block{index[0]}() {{"

    renamed = BLOCK.sub(name, body)
    calls = "\n".join(f"                block{n + 1}();" for n in range(count))
    return f"{renamed}\n            void main() {{\n{calls}\n            }}\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-m", "--module", default="ut.ported")
    parser.add_argument("-i", "--input", default="-")
    parser.add_argument("--nodes", metavar="JSON",
                        help="per-snippet AST node sets from astcover.d; "
                             "splits the output into one module per topic")
    parser.add_argument("-d", "--directory", default=".",
                        help="where to write the modules --nodes produces")
    parser.add_argument("--max-per-module", type=int, default=0, metavar="N",
                        help="split a topic over numbered modules of N tests, "
                             "so a change recompiles less and ninja has more "
                             "to run at once")
    args = parser.parse_args()

    handle = sys.stdin if args.input == "-" else open(args.input)
    snippets = json.load(handle)

    nodes = json.load(open(args.nodes)) if args.nodes else None
    parts = {}
    emitted = skipped = 0

    for n, snippet in enumerate(snippets):
        body, tail = snippet["body"], snippet["tail"]
        excuse = excuse_for(body, tail)
        ported = None if excuse else rename_blocks(body)

        if ported is None:
            why = excuse or "no unittest block"
            print(f"{snippet['origin']}:{snippet['line']}: {why}",
                  file=sys.stderr)
            skipped += 1
            continue

        status = 1 if "shouldThrow" in tail else 0
        where = route_for(nodes[n]) if nodes else None
        parts.setdefault(where, []).append(
            "static foreach (backend; Matrix!(\n"
            "    Omit!(Ctfe, Because.unconfirmed),\n"
            "    Omit!(Interpreter, Because.unconfirmed),\n"
            ")) {\n"
            f'    @("ported.{n}." ~ backend.stringof)\n'
            "    @Tags(backend.stringof)\n"
            "    unittest {\n"
            f"        {status}.shouldBeStatusOf!(backend, q{{{ported}}});\n"
            "    }\n"
            "}\n\n"
        )
        emitted += 1

    def write(stem, cases):
        name = f"{args.module}.{stem}"
        source = f"module {name};\n\n\nimport ut.backends;\n\n\n" + "".join(cases)
        with open(f"{args.directory}/{stem}.d", "w") as out:
            out.write(source)
        print(f'    "{name}",  // {len(cases)} tests', file=sys.stderr)

    for where, cases in sorted(parts.items(), key=lambda pair: pair[0] or ""):
        if where is None:
            sys.stdout.write(
                f"module {args.module};\n\n\nimport ut.backends;\n\n\n"
                + "".join(cases))
        elif not args.max_per_module or len(cases) <= args.max_per_module:
            write(where, cases)
        else:
            size = args.max_per_module
            for part in range((len(cases) + size - 1) // size):
                write(f"{where}{part}", cases[part * size:(part + 1) * size])

    print(f"{emitted} emitted, {skipped} skipped", file=sys.stderr)


if __name__ == "__main__":
    main()
