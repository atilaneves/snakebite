// Measures how much of D's grammar a corpus of guest snippets reaches.
//
// Drop into `tests/ut/`, add `"ut.astcover"` to `tests/main.d`, and build.
// It reads the JSON that `build/port/extract-snippets.py` writes and reports
// the distinct dmd AST node classes each corpus reaches, plus the smallest
// subset of snippets that reaches all of them.
//
// AST node coverage states which constructs a backend must handle. It does
// not state whether the backend handles them correctly - two snippets can
// reach the same nodes and pin different values.
module ut.astcover;

import ut;
import dmd.dmodule: Module;
import dmd.visitor: SemanticTimeTransitiveVisitor;
import std.meta: Filter, NoDuplicates, staticMap;
import std.traits: Parameters;


// Records the class of every AST node reached in a module. dmd's transitive
// visitor already walks the whole tree; overriding each `visit` overload in
// turn is what makes the walk observable, and `astTypeName` is dmd's own
// answer to "which node class is this".
extern(C++) final class Recorder: SemanticTimeTransitiveVisitor {
    alias visit = SemanticTimeTransitiveVisitor.visit;

    bool[string] seen;

    private alias Overloads =
        __traits(getOverloads, SemanticTimeTransitiveVisitor, "visit");
    private template NodeType(alias overload) {
        alias NodeType = Parameters!overload[0];
    }
    private enum takesNode(alias overload) =
        Parameters!overload.length == 1 && is(Parameters!overload[0] == class);

    // Deduplicated: a node class visited by more than one inherited overload
    // would otherwise be overridden twice.
    public alias NodeTypes =
        NoDuplicates!(staticMap!(NodeType, Filter!(takesNode, Overloads)));

    static foreach (NodeClass; NodeTypes) {
        override void visit(NodeClass node) {
            import dmd.asttypename: astTypeName;
            seen[astTypeName(node)] = true;
            super.visit(node);
        }
    }
}


// The AST node classes one snippet reaches. A snippet the frontend rejects
// contributes nothing rather than failing the run: the corpus comes from
// another project, and one unparseable member of it is not a test failure.
public bool[string] astNodesOf(in string source) {
    import snakebite.frontend.compiler: parseSnippets;

    bool[string] nodes;
    Module[] modules;

    try
        modules = parseSnippets([source]);
    catch (Throwable)
        return nodes;

    foreach (module_; modules) {
        scope recorder = new Recorder;
        try
            module_.accept(recorder);
        catch (Throwable)
            continue;
        foreach (name; recorder.seen.byKey)
            nodes[name] = true;
    }

    return nodes;
}


// Writes each snippet's node set as JSON, keyed by its index in the corpus,
// for `port-snippet.py --nodes` to route a snippet to a module by what it
// actually exercises rather than by which quickbite file it came from.
public void writeNodeSets(in bool[string][] perSnippet, in string path) {
    import std.file: write;
    import std.array: appender;
    import std.format: formattedWrite;

    auto json = appender!string;
    json ~= "[";

    foreach (i, nodes; perSnippet) {
        if (i)
            json ~= ",";
        json ~= "[";
        bool first = true;
        foreach (name; nodes.byKey) {
            if (!first)
                json ~= ",";
            json.formattedWrite(`"%s"`, name);
            first = false;
        }
        json ~= "]";
    }

    json ~= "]";
    write(path, json[]);
}


// The smallest subset reaching every node the whole corpus reaches, by
// repeatedly taking whichever snippet adds the most that is still missing.
// Set cover is NP-hard; this is the standard greedy approximation.
public size_t[] minimalCover(in bool[string][] perSnippet) {
    bool[string] have;
    size_t[] chosen;
    auto taken = new bool[perSnippet.length];

    while (true) {
        size_t best, bestGain;

        foreach (i, nodes; perSnippet) {
            if (taken[i])
                continue;
            size_t gain;
            foreach (name; nodes.byKey)
                if (name !in have)
                    ++gain;
            if (gain > bestGain) {
                bestGain = gain;
                best = i;
            }
        }

        if (bestGain == 0)
            return chosen;

        taken[best] = true;
        foreach (name; perSnippet[best].byKey)
            have[name] = true;
        chosen ~= best;
    }
}
