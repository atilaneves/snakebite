module snakebite.backends.interpreter;


private:


// Interprets guest code by walking dmd's own AST, using visitor classes
// derived from dmd's `Visitor` base (`dmd.visitor.Visitor`). No frame stack
// or locals yet (future work); the interpreter can evaluate a function body
// down to its `return`, including calls to other guest functions whose own
// bodies do the same, which is all the current tests exercise.
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
                    function_.toString.text ~ "`",
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
// caller-chosen return place (skipped when `returnPlace` is `null`, e.g. a
// nested call only wants `value`, not a byte write). Any statement kind it
// does not know throws, naming the AST node kind, instead of silently doing
// nothing.
extern(C++) private final class StatementWalker: Visitor {
    import dmd.astenums: Tvoid;
    import dmd.expression: Expression;
    import dmd.mtype: Type;
    import dmd.statement: CompoundStatement, ReturnStatement, Statement;

    alias visit = Visitor.visit;

    // The return type of the function whose body this walker is walking.
    private Type functionReturnType;
    private void* returnPlace;

    // The evaluated `return` expression's value, if the walk reached one.
    // A nested call reads this directly instead of going through
    // `returnPlace`, since it has no native memory of its own to write
    // into yet - its result feeds straight into the enclosing expression.
    public Expression value;

    this(Type functionReturnType, void* returnPlace) {
        this.functionReturnType = functionReturnType;
        this.returnPlace = returnPlace;
    }

    override void visit(Statement statement) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot execute a `", statement.stmt,
                "` statement: `", statement.toString, "`"),
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
        // Evaluation always happens, for any side effects it may have; only
        // the write into `returnPlace` is skipped when there is none, or
        // when the caller does not want the value (`returnPlace is null`),
        // or the return type is `void` (there is no value).
        if (statement.exp is null)
            return;

        scope evaluator = new ExpressionEvaluator;
        statement.exp.accept(evaluator);
        value = evaluator.value;

        if (returnPlace !is null && functionReturnType.ty != Tvoid)
            writeNativeValue(functionReturnType, value, returnPlace);
    }
}

// Writes one evaluated expression's value into `place` in native layout,
// exactly `type`'s size - the same conversion whether `place` is a
// function's return slot or a parameter's frame slot.
private void writeNativeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    import dmd.astenums: Tfloat32, Tfloat64;
    import dmd.typesem: size;
    import std.conv: text;

    if (type.ty == Tfloat32) {
        *cast(float*) place = cast(float) value.toReal;
        return;
    }

    if (type.ty == Tfloat64) {
        *cast(double*) place = cast(double) value.toReal;
        return;
    }

    if (type.isIntegral) {
        const integer = value.toInteger;
        switch (type.size) {
            case 1: *cast(ubyte*) place = cast(ubyte) integer; return;
            case 2: *cast(ushort*) place = cast(ushort) integer; return;
            case 4: *cast(uint*) place = cast(uint) integer; return;
            case 8: *cast(ulong*) place = integer; return;
            default:
                throw new Exception(
                    text("interpreter cannot write an integral of size ",
                        type.size, ": `", type.toString, "`"),
                );
        }
    }

    throw new Exception(
        text("interpreter cannot write a value of type `",
            type.toString, "`"),
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
    import dmd.expression: CallExp, Expression, IntegerExp, RealExp;

    alias visit = Visitor.visit;

    public Expression value;

    override void visit(Expression expression) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toString, "`"),
        );
    }

    override void visit(IntegerExp expression) {
        value = expression;
    }

    override void visit(RealExp expression) {
        value = expression;
    }

    override void visit(CallExp expression) {
        value = evaluateCall(expression);
    }
}

// Calls a guest function reached from within an expression, as opposed to
// `Interpreter.call`, the host-facing entry point: the callee is already
// statically resolved onto the `CallExp` by semantic analysis (`call.f`),
// so no name lookup or virtual dispatch happens here. Arguments are
// evaluated into the callee's own parameter frame, then the callee body is
// walked for its `return` value the same way a top-level call is, just
// with no native return place to write into - the value is read back from
// the walker directly and becomes this call expression's value.
private imported!"dmd.expression".Expression evaluateCall(
    imported!"dmd.expression".CallExp call,
) {
    import std.conv: text;

    auto function_ = call.f;
    if (function_ is null)
        throw new Exception(
            text("interpreter cannot call an unresolved function: `",
                call.toString, "`"),
        );

    auto body_ = function_.fbody;
    if (body_ is null)
        throw new Exception(
            text("interpreter cannot call a function with no body: `",
                function_.toString, "`"),
        );

    // The frame is built for its evaluation side effects and to hold the
    // arguments in native parameter storage; nothing reads it back yet
    // since no test here has a callee body that references a parameter.
    // Growing that support means adding a `VarExp` visit that looks a
    // parameter up in this same frame, not a different mechanism.
    calleeFrame(function_, call.arguments);

    scope walker = new StatementWalker(function_.type.nextOf, null);
    body_.accept(walker);
    return walker.value;
}

// Builds one function activation's parameter storage: a contiguous native
// buffer with one slot per parameter, at the byte offset that parameter
// would have in a compiled call's frame, and evaluates each argument
// expression directly into its slot. Evaluation happens for every
// argument, even ones the callee body never reads, since evaluating an
// argument can have effects of its own.
private ubyte[] calleeFrame(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.expression".Expressions* arguments,
) {
    import dmd.typesem: size;
    import std.conv: text;

    auto parameters = function_.parameters;
    const argCount = arguments is null ? 0 : arguments.length;
    const paramCount = parameters is null ? 0 : parameters.length;
    if (argCount != paramCount)
        throw new Exception(
            text("interpreter: `", function_.toString, "` expects ",
                paramCount, " argument(s), got ", argCount),
        );

    auto offsets = new size_t[paramCount];
    size_t frameSize = 0;
    if (parameters !is null) {
        foreach (i, parameter; *parameters) {
            frameSize = alignUp(frameSize, parameter.type.size);
            offsets[i] = frameSize;
            frameSize += parameter.type.size;
        }
    }

    auto frame = new ubyte[frameSize];
    if (arguments !is null) {
        foreach (i, argumentExpression; *arguments) {
            auto parameter = (*parameters)[i];
            scope argumentEvaluator = new ExpressionEvaluator;
            argumentExpression.accept(argumentEvaluator);
            writeNativeValue(
                parameter.type, argumentEvaluator.value,
                frame.ptr + offsets[i],
            );
        }
    }

    return frame;
}

// Rounds `offset` up to the next multiple of `alignment`, so each
// parameter's slot starts at an address as aligned as the type itself.
private size_t alignUp(in size_t offset, in size_t alignment) {
    if (alignment == 0)
        return offset;

    return (offset + alignment - 1) / alignment * alignment;
}
