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

        auto walker = new StatementWalker(function_.type.nextOf, returnPlace);
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

    private Type returnType;
    private void* returnPlace;
    private bool returned;

    this(Type returnType, void* returnPlace) {
        this.returnType = returnType;
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

        foreach (one; *statement.statements) {
            if (returned)
                return;
            if (one !is null)
                one.accept(this);
        }
    }

    override void visit(ReturnStatement statement) {
        returned = true;
        writeReturnValue(returnType, statement.exp, returnPlace);
    }
}

// Writes one evaluated expression into the caller's native return place, in
// native layout, exactly the return type's size. `null` (the caller does
// not want the value) and `void` (there is no value) both write nothing.
private void writeReturnValue(
    imported!"dmd.mtype".Type returnType,
    imported!"dmd.expression".Expression expression,
    void* returnPlace,
) {
    import dmd.astenums: Tfloat32, Tfloat64, Tvoid;
    import dmd.typesem: size;
    import std.conv: text;

    if (returnPlace is null || returnType.ty == Tvoid)
        return;

    auto evaluator = new ExpressionEvaluator;
    expression.accept(evaluator);

    if (returnType.ty == Tfloat32) {
        *cast(float*) returnPlace = evaluator.isFloat
            ? cast(float) evaluator.realValue
            : cast(float) cast(long) evaluator.integerValue;
        return;
    }

    if (returnType.ty == Tfloat64) {
        *cast(double*) returnPlace = evaluator.isFloat
            ? cast(double) evaluator.realValue
            : cast(double) cast(long) evaluator.integerValue;
        return;
    }

    if (returnType.isIntegral) {
        const integer = evaluator.isFloat
            ? cast(ulong) cast(long) evaluator.realValue
            : evaluator.integerValue;
        switch (returnType.size) {
            case 1: *cast(ubyte*) returnPlace = cast(ubyte) integer; return;
            case 2: *cast(ushort*) returnPlace = cast(ushort) integer; return;
            case 4: *cast(uint*) returnPlace = cast(uint) integer; return;
            case 8: *cast(ulong*) returnPlace = cast(ulong) integer; return;
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

// Evaluates one expression node directly (dmd's `IntegerExp`/`RealExp`
// already carry their literal value), throwing on anything it does not know
// how to evaluate instead of returning silent garbage.
extern(C++) private final class ExpressionEvaluator: Visitor {
    import dmd.expression: CastExp, Expression, IntegerExp, RealExp;

    alias visit = Visitor.visit;

    public ulong integerValue;
    public real realValue;
    public bool isFloat;

    override void visit(Expression expression) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toChars, "`"),
        );
    }

    override void visit(IntegerExp expression) {
        integerValue = expression.toInteger;
        isFloat = false;
    }

    override void visit(RealExp expression) {
        realValue = expression.toReal;
        isFloat = true;
    }

    // Implicit conversions (e.g. an `int` literal returned from a `double`
    // function) show up as a `CastExp` wrapping the underlying literal;
    // the target size/kind is applied by `writeReturnValue` from the
    // function's return type, so evaluating the operand is enough.
    override void visit(CastExp expression) {
        expression.e1.accept(this);
    }
}
