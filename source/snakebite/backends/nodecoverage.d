module snakebite.backends.nodecoverage;


private:

import dmd.expression;
import dmd.statement;
import std.meta: AliasSeq, NoDuplicates, staticIndexOf;
import std.traits: Parameters, isAbstractClass;
import dmd.visitor: FrontendVisitor = Visitor;
import snakebite.backends.loweringvisitor: LoweringVisitor;


// An existing pre-runtime audit claim, with a pending reason. It retains
// the old structural exemption until its producer/escape-path proof is
// reviewed. `handledAnyway` records an existing intentional adapter.
package struct Unreachable(Node, string reason, string handledAnywayReason = "") {
    alias Class = Node;
    enum handledAnyway = handledAnywayReason;
}

package alias UnreachableNodes = AliasSeq!(
    Unreachable!(ErrorExp,
        "semantic analysis reports an error, so no module with it loads"),
    Unreachable!(VoidInitExp,
        "only dmd's CTFE interpreter creates it, for a `void` initialiser"),
    Unreachable!(IdentifierExp,
        "expression semantic resolves it to a symbol expression or "
            ~ "reports an error"),
    Unreachable!(DollarExp,
        "expression semantic resolves `$` to the length or an `opDollar` call"),
    Unreachable!(DsymbolExp,
        "expression semantic resolves it to a variable, function or "
            ~ "type expression"),
    Unreachable!(InterpExp,
        "expression semantic rewrites it to a tuple of interpolation values"),
    Unreachable!(CompoundLiteralExp,
        "a C literal; expression semantic rewrites it to a comma "
            ~ "expression or a global"),
    Unreachable!(TypeExp,
        "a type in value position is an error that dmd's glue reports"),
    Unreachable!(ScopeExp,
        "a scope in value position is an error that dmd's glue reports"),
    Unreachable!(TemplateExp,
        "expression semantic resolves it into a call or reports an error"),
    Unreachable!(NewAnonClassExp,
        "expression semantic rewrites it to a `DeclarationExp` and a `NewExp`"),
    Unreachable!(SymbolExp,
        "a base class that dmd never constructs directly; `VarExp` "
            ~ "and `SymOffExp` replace it"),
    Unreachable!(OverExp,
        "call semantic picks one overload, or reports an error"),
    Unreachable!(TraitsExp,
        "expression semantic folds `__traits` to its value"),
    Unreachable!(IsExp,
        "expression semantic folds `is(...)` to a boolean"),
    Unreachable!(MixinExp,
        "expression semantic compiles the string and replaces the node"),
    Unreachable!(ImportExp,
        "expression semantic replaces it with a `StringExp`"),
    Unreachable!(DotIdExp,
        "expression semantic resolves it to a member access or a call"),
    Unreachable!(DotTemplateExp,
        "call semantic resolves it to a function call"),
    Unreachable!(DotTemplateInstanceExp,
        "call semantic resolves it to a function call"),
    Unreachable!(UAddExp,
        "expression semantic replaces `+e` with `e` or an operator "
            ~ "overload call"),
    Unreachable!(ArrayExp,
        "expression semantic rewrites it to an `opIndex` call or "
            ~ "reports an error"),
    Unreachable!(DotExp,
        "only wraps a template or overload set, which call semantic "
            ~ "resolves; dmd's glue asserts"),
    Unreachable!(IntervalExp,
        "only an operand of a slice that semantic rewrites to an "
            ~ "`opSlice` call"),
    Unreachable!(PreExp,
        "expression semantic rewrites `++e` to `e += 1` or an overload call"),
    Unreachable!(BinAssignExp,
        "a base class that dmd never constructs directly",
        "the bytecode compiler overrides it once for every compound "
            ~ "assignment operator, and the interpreter has one override "
            ~ "for each operator"),
    Unreachable!(PowAssignExp,
        "expression semantic rewrites `a ^^= b` to `a = a ^^ b`",
        "the bytecode compiler reaches it through its `BinAssignExp` "
            ~ "override"),
    Unreachable!(PowExp,
        "expression semantic rewrites `^^` to a multiplication, a "
            ~ "division or a `std.math.pow` call"),
    Unreachable!(InExp,
        "expression semantic rewrites it to a `_d_aaIn` call; dmd's "
            ~ "glue asserts"),
    Unreachable!(RemoveExp,
        "expression semantic rewrites it to a `_d_aaDel` call; "
            ~ "dmd's glue asserts"),
    Unreachable!(DefaultInitExp,
        "a base class that dmd never constructs directly"),
    Unreachable!(FileInitExp,
        "call semantic replaces it with a string literal at the call site"),
    Unreachable!(LineInitExp,
        "call semantic replaces it with an integer literal at the call site"),
    Unreachable!(ModuleInitExp,
        "call semantic replaces it with a string literal at the call site"),
    Unreachable!(FuncInitExp,
        "call semantic replaces it with a string literal at the call site"),
    Unreachable!(PrettyFuncInitExp,
        "call semantic replaces it with a string literal at the call site"),
    Unreachable!(CTFEExp,
        "only dmd's CTFE interpreter creates it, as a control-flow marker"),
    Unreachable!(ThrownExceptionExp,
        "only dmd's CTFE interpreter creates it, to carry a thrown exception"),
    Unreachable!(ObjcClassReferenceExp,
        "only Objective-C interfaces create it; the target has no "
            ~ "Objective-C support"),
    Unreachable!(GenericExp,
        "a C `_Generic`; expression semantic selects one branch"),
    Unreachable!(ErrorStatement,
        "statement semantic reports an error, so no module with "
            ~ "this node loads"),
    Unreachable!(PeelStatement,
        "statement semantic unwraps it to the statement inside"),
    Unreachable!(MixinStatement,
        "statement semantic compiles the string and replaces the node"),
    Unreachable!(ForwardingStatement,
        "statement semantic replaces it with the statement inside"),
    Unreachable!(WhileStatement,
        "statement semantic rewrites it to a `ForStatement`"),
    Unreachable!(ForeachStatement,
        "statement semantic rewrites it to a `ForStatement`, an "
            ~ "unrolled loop or an `opApply` call"),
    Unreachable!(ForeachRangeStatement,
        "statement semantic rewrites it to a `ForStatement`"),
    Unreachable!(ConditionalStatement,
        "statement semantic keeps only the branch the condition selects"),
    Unreachable!(StaticForeachStatement,
        "statement flattening expands it into the unrolled statements"),
    Unreachable!(PragmaStatement,
        "statement semantic replaces it with its body"),
    Unreachable!(StaticAssertStatement,
        "statement semantic checks it and removes it"),
    Unreachable!(CaseRangeStatement,
        "statement semantic expands it into one `CaseStatement` per value"),
    Unreachable!(SynchronizedStatement,
        "statement semantic rewrites it to a `TryFinallyStatement` "
            ~ "around the monitor calls"),
    Unreachable!(DebugStatement,
        "statement semantic replaces it with the statement inside"),
    Unreachable!(AsmStatement,
        "inline assembler fails the load (ADR-0012)"),
    Unreachable!(InlineAsmStatement,
        "inline assembler fails the load (ADR-0012)"),
    Unreachable!(GccAsmStatement,
        "inline assembler fails the load (ADR-0012)"),
);

// This structural gate retains the old pre-runtime exemptions. Their
// producer and escape-path proofs are pending; this is not a semantic
// coverage certificate (docs/agents/node-coverage.md).
package template AssertEveryNodeHandled(Visitor) {
    static assert(AssertForwardingRecords!ForwardedNodes);
    static assert(AssertNodeUniverse!(NodeSet!FrontendNodes, NodeSet!VisitorNodes));
    private enum missing = missingNodes!Visitor;
    static assert(missing.length == 0,
        Visitor.stringof ~ " has no `visit` override for:" ~ missing);

    private enum unnecessary = unnecessaryEntries!Visitor;
    static assert(unnecessary.length == 0,
        Visitor.stringof ~ " handles classes that `UnreachableNodes` lists:"
            ~ unnecessary);

    enum AssertEveryNodeHandled = true;
}

private string unnecessaryEntries(Visitor)() {
    string result;
    static foreach (Entry; UnreachableNodes) {
        static if (Entry.handledAnyway.length == 0
                && hasRuntimeVisit!(Visitor, Entry.Class))
            result ~= " " ~ Entry.Class.stringof;
    }
    return result;
}

private string missingNodes(Visitor)() {
    string result;
    static foreach (Node; ConcreteNodes) {
        static if (!isUnreachable!Node && !hasRuntimeVisit!(Visitor, Node))
            result ~= " " ~ Node.stringof;
    }
    return result;
}

package alias FrontendNodes = NoDuplicates!(AliasSeq!(
    nodeClasses!(imported!"dmd.expression", Expression),
    nodeClasses!(imported!"dmd.statement", Statement),
));

private alias ConcreteNodes = concreteNodes!FrontendNodes;

private template concreteNodes(Nodes...) {
    alias concreteNodes = AliasSeq!();
    static foreach (Node; Nodes) {
        static if (!isAbstractClass!Node)
            concreteNodes = AliasSeq!(concreteNodes, Node);
    }
}

private template visitParameters(Visitor) {
    alias visitParameters = AliasSeq!();
    static foreach (method; __traits(getOverloads, Visitor, "visit")) {
        static if (Parameters!method.length == 1) {
            static if (is(Parameters!method[0] : Expression)
                    || is(Parameters!method[0] : Statement))
                visitParameters = AliasSeq!(visitParameters, Parameters!method[0]);
        }
    }
}

package alias VisitorNodes = NoDuplicates!(visitParameters!FrontendVisitor);

// CTFEExp has no Visitor overload: its accept path is Expression.accept.
// Its separate entry must remain visible in the pre-runtime audit.
package struct NodeSet(Nodes...) {
    alias Types = AliasSeq!Nodes;
}

package template AssertNodeUniverse(Classes, Visits) {
    static foreach (Node; Visits.Types)
        static assert(staticIndexOf!(Node, Classes.Types) >= 0,
            "node coverage: Visitor node absent from class inventory: " ~ Node.stringof);
    static foreach (Node; Classes.Types)
        static assert(staticIndexOf!(Node, Visits.Types) >= 0 || is(Node == CTFEExp),
            "node coverage: class absent from Visitor inventory: " ~ Node.stringof);
    enum AssertNodeUniverse = true;
}

private template nodeClasses(alias mod, Base) {
    import std.traits: isAbstractClass;

    alias nodeClasses = AliasSeq!();
    static foreach (name; __traits(allMembers, mod)) {
        static if (__traits(compiles, __traits(getMember, mod, name))
                && is(__traits(getMember, mod, name) == class)
                && is(__traits(getMember, mod, name) : Base))
            nodeClasses = AliasSeq!(
                nodeClasses, __traits(getMember, mod, name));
    }
}

private enum isUnreachable(Node) = isUnreachableIn!(Node, UnreachableNodes);

private template isUnreachableIn(Node, Entries...) {
    static if (Entries.length == 0)
        enum isUnreachableIn = false;
    else static if (is(Entries[0].Class == Node))
        enum isUnreachableIn = true;
    else
        enum isUnreachableIn = isUnreachableIn!(Node, Entries[1 .. $]);
}

// These records permit only the pinned frontend's named forwarding edges.
// The target must have an exact execution adapter. The source proof and
// field obligations are recorded in docs/agents/node-coverage.md.
package struct Forward(Node, Target) {
    alias Class = Node;
    alias Destination = Target;
}

package alias ForwardedNodes = AliasSeq!(
    Forward!(SuperExp, ThisExp),
    Forward!(DtorExpStatement, ExpStatement),
    Forward!(CompoundDeclarationStatement, CompoundStatement),
    Forward!(CompoundAsmStatement, CompoundStatement),
    Forward!(AddAssignExp, BinAssignExp),
    Forward!(MinAssignExp, BinAssignExp),
    Forward!(MulAssignExp, BinAssignExp),
    Forward!(DivAssignExp, BinAssignExp),
    Forward!(ModAssignExp, BinAssignExp),
    Forward!(AndAssignExp, BinAssignExp),
    Forward!(OrAssignExp, BinAssignExp),
    Forward!(XorAssignExp, BinAssignExp),
    Forward!(ShlAssignExp, BinAssignExp),
    Forward!(ShrAssignExp, BinAssignExp),
    Forward!(UshrAssignExp, BinAssignExp),
);

package template AssertForwardingRecords(Entries...) {
    static foreach (i, Entry; Entries) {
        static assert(!is(Entry.Class == Entry.Destination),
            "node coverage: forwarding cycle: " ~ Entry.Class.stringof);
        static foreach (Previous; Entries[0 .. i])
            static assert(!is(Previous.Class == Entry.Class),
                "node coverage: duplicate forwarding record: " ~ Entry.Class.stringof);
        static assert(staticIndexOf!(Entry, ForwardedNodes) >= 0
                && is(Entry.Class : Entry.Destination),
            "node coverage: wrong forwarding target: " ~ Entry.Class.stringof);
        static assert(!is(Entry.Destination == Expression)
                && !is(Entry.Destination == Statement),
            "node coverage: forwarding target is a catch-all: " ~ Entry.Class.stringof);
    }
    enum AssertForwardingRecords = true;
}

package bool hasRuntimeVisit(Visitor, Node)() @safe @nogc nothrow pure {
    static if (hasExactVisit!(Visitor, Node))
        return true;
    else {
        static foreach (Entry; ForwardedNodes) {
            static if (is(Node == Entry.Class))
                return hasExactVisit!(Visitor, Entry.Destination);
        }
        return false;
    }
}

// A backend declares its own exact adapters. Shared policies count only
// when final, so a change of parent class cannot silently earn coverage.
package bool hasExactVisit(Visitor, Node)() @safe @nogc nothrow pure {
    static if (is(Node == Expression) || is(Node == Statement))
        return false;
    else {
        static foreach (method; __traits(getOverloads, Visitor, "visit")) {
            static if (Parameters!method.length == 1) {
                static if (is(Parameters!method[0] == Node)
                        && (is(__traits(parent, method) == Visitor)
                            || (is(__traits(parent, method) == LoweringVisitor)
                                && __traits(isFinalFunction, method))))
                    return true;
            }
        }
        return false;
    }
}
