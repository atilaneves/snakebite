module snakebite.backends.interpreter;


private:


// Interprets guest code by walking dmd's own AST, using visitor classes
// derived from dmd's `Visitor` base (`dmd.visitor.Visitor`). No frame stack
// or locals yet (future work); the interpreter only needs to evaluate a
// function body down to its `return`, which is all the current tests
// exercise.
public final class Interpreter: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        if (args.length != 0)
            throw new Exception(
                "arguments not yet supported by the interpreter backend",
            );

        auto body_ = function_.fbody;
        if (body_ is null) {
            import std.conv: text;

            throw new Exception(
                "interpreter cannot call a function with no body: `" ~
                    function_.toChars.text ~ "`",
            );
        }

        scope walker = new StatementWalker(function_.type.nextOf, returnPlace);
        body_.accept(walker);
    }

    public override string eval(FuncDeclaration function_) {
        throw new Exception(
            "eval not implemented for the interpreter yet",
        );
    }
}

import dmd.visitor: Visitor;

// Walks statements looking for a `return`, writing its value into the
// caller-chosen return place. Any statement kind it does not know throws,
// naming the AST node kind, instead of silently doing nothing.
extern(C++) private final class StatementWalker: Visitor {
    import dmd.mtype: Type;
    import dmd.statement: CompoundStatement, ReturnStatement, Statement;

    alias visit = Visitor.visit;

    // The enclosing function's return type, not this walker's own; a
    // statement walker has no return type of its own.
    private Type functionReturnType;
    private void* returnPlace;

    this(Type functionReturnType, void* returnPlace) {
        this.functionReturnType = functionReturnType;
        this.returnPlace = returnPlace;
    }

    override void visit(Statement statement) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot execute a `", statement.stmt,
                "` statement: `", statement.toChars, "`"),
        );
    }

    override void visit(CompoundStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements) {
            if (child !is null)
                child.accept(this);
        }
    }

    override void visit(ReturnStatement statement) {
        writeReturnValue(functionReturnType, statement.exp, returnPlace);
    }
}

// Evaluates the returned expression, if there is one, then writes its value
// into the caller's native return place, in native layout, exactly the
// return type's size. Evaluation always happens, for any side effects it
// may have; only the write is skipped when `returnPlace` is `null` (the
// caller does not want the value) or the return type is `void` (there is no
// value).
private void writeReturnValue(
    imported!"dmd.mtype".Type returnType,
    imported!"dmd.expression".Expression expression,
    void* returnPlace,
) {
    import dmd.astenums: Tfloat32, Tfloat64, Tvoid;
    import dmd.typesem: size;
    import std.conv: text;

    if (expression is null)
        return;

    scope evaluator = new ExpressionEvaluator;
    expression.accept(evaluator);

    if (returnPlace is null || returnType.ty == Tvoid)
        return;

    if (returnType.ty == Tfloat32) {
        *cast(float*) returnPlace = cast(float) evaluator.value.toReal;
        return;
    }

    if (returnType.ty == Tfloat64) {
        *cast(double*) returnPlace = cast(double) evaluator.value.toReal;
        return;
    }

    if (returnType.isIntegral) {
        const integer = evaluator.value.toInteger;
        switch (returnType.size) {
            case 1: *cast(ubyte*) returnPlace = cast(ubyte) integer; return;
            case 2: *cast(ushort*) returnPlace = cast(ushort) integer; return;
            case 4: *cast(uint*) returnPlace = cast(uint) integer; return;
            case 8: *cast(ulong*) returnPlace = integer; return;
            default:
                throw new Exception(
                    text("interpreter cannot return an integral of size ",
                        returnType.size, ": `", returnType.toChars, "`"),
                );
        }
    }

    throw new Exception(
        text("interpreter cannot return a value of type `",
            returnType.toChars, "`"),
    );
}

// Evaluates one expression node directly, keeping the literal `Expression`
// itself rather than pulling its value out into separate integer/real
// fields: `Expression.toInteger`/`toReal` already convert it correctly for
// whichever kind it is, so a caller that knows the wanted kind (from the
// return type) does not need this class to track it too. Throws on
// anything it does not know how to evaluate instead of returning silent
// garbage.
extern(C++) private final class ExpressionEvaluator: Visitor {
    import dmd.expression: Expression, IntegerExp, RealExp;

    alias visit = Visitor.visit;

    public Expression value;

    override void visit(Expression expression) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toChars, "`"),
        );
    }

    override void visit(IntegerExp expression) {
        value = expression;
    }

    override void visit(RealExp expression) {
        value = expression;
    }
}
