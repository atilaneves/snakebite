module snakebite.backends.nodecoverage;


private:

import dmd.expression;
import dmd.statement;
import std.meta: AliasSeq;


// A frontend node class that no backend ever receives, and why. A class on
// this list needs no `visit` override.
package struct Unreachable(Node, string reason) {
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
        "a base class that dmd never constructs directly"),
    Unreachable!(PowAssignExp,
        "expression semantic rewrites `a ^^= b` to `a = a ^^ b`"),
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
    Unreachable!(ScopeGuardStatement,
        "statement semantic rewrites it to try-finally or try-catch "
            ~ "in the enclosing block"),
    Unreachable!(DebugStatement,
        "statement semantic replaces it with the statement inside"),
    Unreachable!(AsmStatement,
        "inline assembler fails the load (ADR-0012)"),
    Unreachable!(InlineAsmStatement,
        "inline assembler fails the load (ADR-0012)"),
    Unreachable!(GccAsmStatement,
        "inline assembler fails the load (ADR-0012)"),
);

// Fails the build, naming each class, when a concrete frontend `Expression`
// or `Statement` class has neither a `visit` override in `Visitor` nor an
// entry in `UnreachableNodes`. An override of the `Expression` or `Statement`
// catch-all itself does not count as handling a class.
package template AssertEveryNodeHandled(Visitor) {
    private enum missing = missingNodes!Visitor;
    static assert(missing.length == 0,
        "visitor has no `visit` override for: " ~ missing);
    enum AssertEveryNodeHandled = true;
}

private string missingNodes(Visitor)() {
    import dmd.expression: Expression;
    import dmd.statement: Statement;

    string result;
    static foreach (Node; ConcreteNodes) {
        static if (!isUnreachable!Node && !isHandled!(Visitor, Node,
                Expression, Statement))
            result ~= " " ~ Node.stringof;
    }
    return result;
}

private alias ConcreteNodes = AliasSeq!(
    concreteClasses!(imported!"dmd.expression", Expression),
    concreteClasses!(imported!"dmd.statement", Statement),
);

private template concreteClasses(alias mod, Base) {
    import std.traits: isAbstractClass;

    alias concreteClasses = AliasSeq!();
    static foreach (name; __traits(allMembers, mod)) {
        static if (__traits(compiles, __traits(getMember, mod, name))
                && is(__traits(getMember, mod, name) == class)
                && is(__traits(getMember, mod, name) : Base)
                && !isAbstractClass!(__traits(getMember, mod, name)))
            concreteClasses = AliasSeq!(
                concreteClasses, __traits(getMember, mod, name));
    }
}

private enum isUnreachable(Node) = isUnreachableIn!(Node, UnreachableNodes);

private template isUnreachableIn(Node, Entries...) {
    static if (Entries.length == 0)
        enum isUnreachableIn = false;
    else static if (is(Entries[0] == Unreachable!(Node, reason), string reason))
        enum isUnreachableIn = true;
    else
        enum isUnreachableIn = isUnreachableIn!(Node, Entries[1 .. $]);
}

// The nearest ancestor-or-self of `Node` that `Visitor` itself (not dmd's
// default forwarding in `dmd.visitor.Visitor`) overrides `visit` for must
// not be one of the catch-all classes. Names stand in for the types so one
// string search replaces a pairwise type comparison, which costs seconds.
private template isHandled(Visitor, Node, Expression, Statement) {
    import std.algorithm.searching: canFind;
    import std.traits: BaseClassesTuple;

    enum overridden = overriddenParameterNames!Visitor;

    template nearest(Chain...) {
        static if (Chain.length == 0)
            enum nearest = "";
        else static if (overridden.canFind(Chain[0].stringof))
            enum nearest = Chain[0].stringof;
        else
            enum nearest = nearest!(Chain[1 .. $]);
    }

    enum found = nearest!(Node, BaseClassesTuple!Node);
    enum isHandled = found.length != 0
        && found != Expression.stringof && found != Statement.stringof;
}

private template overriddenParameterNames(Visitor) {
    import std.traits: Parameters;
    import dmd.visitor: FrontendVisitor = Visitor;

    enum overriddenParameterNames = () {
        string[] names;
        static foreach (method; __traits(getOverloads, Visitor, "visit")) {
            static if (!is(FrontendVisitor : __traits(parent, method))
                    && Parameters!method.length == 1)
                names ~= Parameters!method[0].stringof;
        }
        return names;
    }();
}
