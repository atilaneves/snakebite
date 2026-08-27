#!/usr/bin/env python3
"""Choose a small set of snippets that reaches every AST node class.

`extract-snippets.py` gets the snippets and `astcover.d` says which AST node
classes each one reaches. A corpus of a thousand snippets reaches no more
node classes than a few dozen of them do, so this picks the few dozen: it
repeatedly takes whichever snippet adds the most classes that nothing chosen
so far reaches. Set cover is NP-hard, so this is the greedy approximation.

`--depth` asks for each class to be reached that many times over. Depth 1
leaves every construct pinned by one snippet, so one wrong value in a
backend passes unnoticed; depth 2 costs about three quarters more snippets.

Each test is named for the rarest node class it was picked for, since that
is what it is in the set to cover. Only the native oracle runs them: they
state what compiled D does, and a backend is added to one when it agrees.

    ./cover-set.py -i snippets.json --nodes nodes.json \
        -m ut.backends.run -d tests/ut/backends/run
"""

import argparse
import json
import subprocess
import sys
import tempfile

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from importlib import import_module

porter = import_module("port-snippet")

# Where a test belongs, by the node class it is in the set to cover. A
# snippet reaches many constructs incidentally - it needs an array to have
# something to concatenate - so filing it by what it happens to contain puts
# a `real` literal test under arrays. The node that earned its place is the
# one that says what it is for.
TOPICS = (
    ("associative", ("AssocArray",)),
    ("templates", ("Template",)),
    ("exceptions", ("Throw", "TryCatch", "TryFinally", "ScopeGuard")),
    ("classes", ("Class", "Interface", "Super", "TypeInfo")),
    ("structs", ("Struct", "Union", "PostBlit", "Anon", "Invariant",
                 "This", "Ctor", "Dtor")),
    ("delegates", ("Delegate", "FuncExp", "FuncLiteral")),
    ("enums", ("Enum",)),
    ("arrays", ("Array", "Cat", "Slice", "Index", "New", "Dollar")),
)

# Suffixes decide what the strong names above do not: a statement is control
# flow, an operator expression is an operator, a declaration is a
# declaration. Anything else has no home more specific than the expression
# it is.
OPERATORS = ("Add", "Min", "Mul", "Div", "Mod", "Pow", "And", "Or", "Xor",
             "Com", "Neg", "Not", "Shl", "Shr", "Ushr", "Cmp", "Equal",
             "Identity", "Logical")


def topic_for(node):
    for topic, prefixes in TOPICS:
        if node.startswith(prefixes):
            return topic
    if node.endswith("Statement"):
        return "control"
    if node.endswith("AssignExp") or node.startswith(OPERATORS):
        return "operators"
    if node.endswith("Declaration"):
        return "declarations"
    return None


def label_for(node):
    """The AST node class, as a test name.

    The whole class name, since the part that says which kind of node it is
    is what distinguishes `TypeExp` from `TypeInfoDeclaration`, and the name
    has to say which construct the test is here to pin.
    """
    return node[0].lower() + node[1:]


def cover(node_sets, depth):
    """Greedy set cover: the indices to keep, and why each one is kept."""
    need = {}
    for nodes in node_sets:
        for node in nodes:
            need[node] = depth

    chosen, taken = [], [False] * len(node_sets)
    while True:
        best, gain = -1, 0
        for i, nodes in enumerate(node_sets):
            if taken[i]:
                continue
            count = sum(1 for node in nodes if need.get(node, 0) > 0)
            if count > gain:
                gain, best = count, i
        if gain == 0:
            return chosen

        taken[best] = True
        added = [node for node in node_sets[best] if need.get(node, 0) > 0]
        for node in added:
            need[node] -= 1
        chosen.append((best, added))


def native_status(ported):
    """What compiled D does with this program.

    The set exists to state native behaviour, so the expected status is
    measured rather than derived. Compiling and running are separate steps
    because `dmd -run` exits 1 for a program that does not compile as well
    as for one that dies, and those must not become the same answer.
    """
    with tempfile.TemporaryDirectory() as directory:
        source = f"{directory}/guest.d"
        binary = f"{directory}/guest"
        with open(source, "w") as out:
            out.write(ported)

        built = subprocess.run(["dmd", "-of=" + binary, source],
                               capture_output=True, cwd=directory)
        if built.returncode != 0:
            raise SystemExit(f"a chosen snippet does not compile:\n"
                             f"{built.stderr.decode()}")

        return subprocess.run([binary], capture_output=True).returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--input", required=True)
    parser.add_argument("--nodes", required=True)
    parser.add_argument("-m", "--module", default="ut.backends.run")
    parser.add_argument("-d", "--directory", default=".")
    parser.add_argument("--depth", type=int, default=1)
    args = parser.parse_args()

    snippets = json.load(open(args.input))
    node_sets = [set(nodes) for nodes in json.load(open(args.nodes))]

    # Reject what the harness cannot express before choosing, so the cover
    # picks another snippet for those node classes instead of losing them.
    portable = [i for i, snippet in enumerate(snippets)
                if porter.excuse_for(snippet["body"], snippet["tail"]) is None
                and porter.rename_blocks(snippet["body"]) is not None]
    snippets = [snippets[i] for i in portable]
    node_sets = [node_sets[i] for i in portable]

    # Rarity decides the name: the class fewest snippets reach says most
    # about why this snippet is in the set.
    frequency = {}
    for nodes in node_sets:
        for node in nodes:
            frequency[node] = frequency.get(node, 0) + 1

    parts, used = {}, {}

    for index, added in cover(node_sets, args.depth):
        snippet = snippets[index]
        body, tail = snippet["body"], snippet["tail"]
        ported = porter.rename_blocks(body)

        covers = min(added, key=lambda node: frequency[node])
        name = label_for(covers)
        used[name] = used.get(name, 0) + 1
        if used[name] > 1:
            name = f"{name}{used[name]}"

        status = native_status(ported)
        where = topic_for(covers) or porter.route_for(node_sets[index])
        parts.setdefault(where, []).append(
            "static foreach (backend; Matrix!(\n"
            "    Omit!(Ctfe, Because.unconfirmed),\n"
            "    Omit!(Interpreter, Because.unconfirmed),\n"
            ")) {\n"
            f'    @("{name}." ~ backend.stringof)\n'
            "    @Tags(backend.stringof)\n"
            "    unittest {\n"
            f"        {status}.shouldBeStatusOf!(backend, q{{{ported}}});\n"
            "    }\n"
            "}\n\n"
        )

    for stem, cases in sorted(parts.items()):
        name = f"{args.module}.{stem}"
        with open(f"{args.directory}/{stem}.d", "w") as out:
            out.write(
                f"module {name};\n\n\n"
                "// Every test here reaches an AST node class that no test\n"
                "// chosen before it reached, and is named for that class.\n"
                "// Together they reach every class the frontend produced\n"
                "// for a corpus of guest programs.\n"
                "//\n"
                "// The expected exit status is what `dmd -run` gives the\n"
                "// program, so each test states what compiled D does. A\n"
                "// backend joins a test's `Matrix` when it agrees.\n\n\n"
                "import ut.backends;\n\n\n" + "".join(cases))
        print(f'    "{name}",  // {len(cases)} tests', file=sys.stderr)

    print(f"{sum(len(c) for c in parts.values())} of {len(snippets)} "
          f"portable snippets cover {len(frequency)} node classes",
          file=sys.stderr)


if __name__ == "__main__":
    main()
