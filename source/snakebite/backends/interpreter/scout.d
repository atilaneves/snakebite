module snakebite.backends.interpreter.scout;


private:

import dmd.declaration: Declaration, VarDeclaration;
import dmd.expression:
    CallExp, DeclarationExp, Expression, FuncExp, NewExp, StructLiteralExp,
    SymOffExp, ThisExp, VarExp;
import dmd.func: FuncDeclaration;
import dmd.mtype: Type;
import dmd.statement: ExpStatement, TryCatchStatement, TryFinallyStatement;
import dmd.visitor: SemanticTimeTransitiveVisitor;
import snakebite.backends.loweringvisitor: LoweredExpressionTypes;
import std.meta: staticIndexOf;


// What the interpreter fills while it prepares a callback, in place of
// when execution first needs it. Execution of a destructor that the GC
// finalizer runs can neither allocate from the GC nor wait for a lock that
// another thread can hold while it waits for the GC.
package struct Preparation {
    package void delegate(CallExp, FuncDeclaration) call;
    package void delegate(FuncDeclaration) reference;
    package void delegate(VarDeclaration) variable;
    package void delegate(Type) type;
    package void delegate(StructLiteralExp) structLiteral;
    package void delegate(TryCatchStatement) tryCatch;
    package void delegate(TryFinallyStatement) tryFinally;
}


// Every expression class that the transitive visitor can dispatch on.
private template ExpressionNodes() {
    import std.meta: AliasSeq, NoDuplicates;
    import std.traits: Parameters;

    private template Nodes(overloads...) {
        static if (overloads.length == 0)
            alias Nodes = AliasSeq!();
        else {
            alias Node = Parameters!(overloads[0])[0];
            static if (is(Node : Expression))
                alias Nodes = AliasSeq!(Node, Nodes!(overloads[1 .. $]));
            else
                alias Nodes = Nodes!(overloads[1 .. $]);
        }
    }

    alias ExpressionNodes = NoDuplicates!(Nodes!(
        __traits(getOverloads, SemanticTimeTransitiveVisitor, "visit")));
}


// Walks a function body the way execution does: into each statement, each
// expression and each `lowering`, and reports every function it can call
// by name, every static variable and every type that execution asks about.
package extern(C++) final class BodyScout: SemanticTimeTransitiveVisitor {
    alias visit = SemanticTimeTransitiveVisitor.visit;

    private Preparation _preparation;

    package extern(D) this(Preparation preparation) {
        _preparation = preparation;
    }

    // A local declaration is walked only for what it executes: the
    // initializer of a variable and its destructor. A function, an alias
    // or an aggregate declared there has its own body, which a call or a
    // reference walks when it is prepared.
    override void visit(DeclarationExp expression) {
        if (expression.type !is null)
            _preparation.type(expression.type);
        auto variable = expression.declaration.isVarDeclaration;
        if (variable is null)
            return;

        _preparation.type(variable.type);
        _preparation.variable(variable);
        if (variable._init !is null)
            if (auto initializer = variable._init.isExpInitializer)
                initializer.exp.accept(this);
        if (variable.edtor !is null)
            variable.edtor.accept(this);
    }

    // The transitive visitor walks the declaration of an `ExpStatement`
    // that holds one itself, and would go into a nested function's body.
    override void visit(ExpStatement statement) {
        if (statement.exp !is null)
            statement.exp.accept(this);
    }

    override void visit(FuncExp expression) {
        if (expression.type !is null)
            _preparation.type(expression.type);
        _preparation.reference(expression.fd);
    }

    static foreach (Node; ExpressionNodes!()) {
        static if (!is(Node == DeclarationExp) && !is(Node == FuncExp))
        override void visit(Node expression) {
            super.visit(expression);
            if (expression.type !is null)
                _preparation.type(expression.type);
            handle(expression);
            static if (staticIndexOf!(Node, LoweredExpressionTypes) >= 0) {
                if (expression.lowering !is null)
                    expression.lowering.accept(this);
            }
            static if (is(Node == NewExp)) {
                if (expression.argprefix !is null)
                    expression.argprefix.accept(this);
            }
        }
    }

    private extern(D) void handle(Expression) {
    }

    private extern(D) void handle(VarExp expression) {
        reference(expression.var);
    }

    private extern(D) void handle(ThisExp expression) {
        if (expression.var !is null)
            reference(expression.var);
    }

    private extern(D) void handle(SymOffExp expression) {
        reference(expression.var);
    }

    private extern(D) void handle(CallExp expression) {
        if (expression.f !is null)
            _preparation.call(expression, expression.f);
    }

    private extern(D) void handle(StructLiteralExp expression) {
        _preparation.structLiteral(expression);
    }

    private extern(D) void reference(Declaration declaration) {
        if (auto function_ = declaration.isFuncDeclaration)
            _preparation.reference(function_);
        else if (auto variable = declaration.isVarDeclaration)
            _preparation.variable(variable);
    }

    override void visit(TryCatchStatement statement) {
        super.visit(statement);
        _preparation.tryCatch(statement);
    }

    override void visit(TryFinallyStatement statement) {
        super.visit(statement);
        _preparation.tryFinally(statement);
    }
}
