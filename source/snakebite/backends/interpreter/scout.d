module snakebite.backends.interpreter.scout;


private:

import dmd.dclass: ClassDeclaration;
import dmd.declaration: Declaration, VarDeclaration;
import dmd.expression:
    AddAssignExp, AddExp, AssignExp, CallExp, CmpExp, DeclarationExp,
    DelegateExp, DeleteExp, EqualExp, Expression, FuncExp, IndexExp, IntegerExp,
    MinAssignExp, MinExp, NewExp, PostExp, SliceExp, StringExp, StructLiteralExp,
    SymOffExp, ThisExp, TypeidExp, VarExp;
import dmd.func: FuncDeclaration;
import dmd.mtype: Type;
import dmd.typesem: nextOf, toBasetype;
import dmd.statement:
    ExpStatement, GotoCaseStatement, GotoDefaultStatement, GotoStatement,
    Statement, SwitchStatement, TryCatchStatement, TryFinallyStatement;
import dmd.visitor: SemanticTimeTransitiveVisitor;
import snakebite.backends.loweringvisitor: LoweredExpressionTypes;
import snakebite.frontend.dmd.functions: unresolvedCalleeOf;
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
    package void delegate(Type) zeroInitialized;
    package void delegate(Type) typeInfo;
    package void delegate(ClassDeclaration) stackClass;
    package void delegate(DeleteExp) deletion;
    package void delegate(StructLiteralExp) structLiteral;
    package void delegate(StringExp) stringLiteral;
    package void delegate(TryCatchStatement) tryCatch;
    package void delegate(TryFinallyStatement) tryFinally;
    package void delegate(TryFinallyStatement, Statement) gotoOutOf;
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
    private TryFinallyStatement[] _finallies;
    private SwitchStatement[] _switches;

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
        _preparation.zeroInitialized(variable.type);
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

    // The name of a function in a call is the call's own `f`, so only a
    // variable is a reference here.
    private extern(D) void handle(VarExp expression) {
        if (auto variable = expression.var.isVarDeclaration)
            _preparation.variable(variable);
    }

    private extern(D) void handle(DelegateExp expression) {
        _preparation.reference(expression.func);
    }

    private extern(D) void handle(ThisExp expression) {
        if (expression.var !is null)
            reference(expression.var);
    }

    private extern(D) void handle(SymOffExp expression) {
        reference(expression.var);
    }

    // The callee that execution names: `f` when the frontend resolved it,
    // otherwise the function that the called expression names.
    private extern(D) void handle(CallExp expression) {
        auto callee = expression.f is null
            ? unresolvedCalleeOf(expression) : expression.f;
        if (callee !is null)
            _preparation.call(expression, callee);
    }

    // The one address of a literal's text is made at its first use.
    private extern(D) void handle(StringExp expression) {
        _preparation.stringLiteral(expression);
    }

    private extern(D) void handle(StructLiteralExp expression) {
        _preparation.structLiteral(expression);
    }

    // A `scope` class instance lives in the frame, and its runtime
    // information is made when the program first needs it: the first
    // object of a class that a destructor makes is that one.
    private extern(D) void handle(NewExp expression) {
        import snakebite.backends.aggregateinit: NewPlan, planNew;

        const plan = planNew(expression);
        if (plan.destination == NewPlan.Destination.stack
                && plan.objectKind == NewPlan.ObjectKind.class_)
            _preparation.stackClass(
                expression.newtype.toBasetype.isTypeClass.sym);
    }

    private extern(D) void handle(DeleteExp expression) {
        _preparation.deletion(expression);
    }

    private extern(D) void handle(TypeidExp expression) {
        import dmd.dtemplate: isType;

        if (auto type = isType(expression.obj))
            _preparation.typeInfo(type);
    }

    // The encoding of a struct whose default value is all zero bytes.
    private extern(D) void handle(IntegerExp expression) {
        if (expression.type !is null)
            _preparation.zeroInitialized(expression.type);
    }

    // Execution of each of these asks for the size of the element or the
    // pointee of an operand, and of nothing else below the operand's type.
    private extern(D) void handle(IndexExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(SliceExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(PostExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(AddExp expression) {
        element(expression.e1);
        element(expression.e2);
    }

    private extern(D) void handle(MinExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(AddAssignExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(MinAssignExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(EqualExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(CmpExp expression) {
        element(expression.e1);
    }

    private extern(D) void handle(AssignExp expression) {
        element(expression);
    }

    private extern(D) void element(Expression operand) {
        import dmd.astenums: Tarray, Tpointer, Tsarray;

        if (operand.type is null)
            return;

        auto base = operand.type.toBasetype;
        if (base.ty == Tpointer || base.ty == Tarray || base.ty == Tsarray)
            _preparation.type(base.nextOf);
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
        _finallies ~= statement;
        super.visit(statement);
        _finallies.length -= 1;
        _preparation.tryFinally(statement);
    }

    override void visit(SwitchStatement statement) {
        _switches ~= statement;
        super.visit(statement);
        _switches.length -= 1;
    }

    // Whether a `finally` body runs when a `goto` leaves it depends on the
    // scope that the jump goes to, so each `try` that encloses the jump is
    // asked about that scope.
    override void visit(GotoStatement statement) {
        if (statement.label !is null && statement.label.statement !is null)
            gotoTo(statement.label.statement.tryBody);
    }

    override void visit(GotoCaseStatement statement) {
        if (_switches.length != 0)
            gotoTo(_switches[$ - 1].tryBody);
    }

    override void visit(GotoDefaultStatement statement) {
        if (statement.sw !is null)
            gotoTo(statement.sw.tryBody);
    }

    private extern(D) void gotoTo(Statement destination) {
        foreach (enclosing; _finallies)
            _preparation.gotoOutOf(enclosing, destination);
    }
}
