module snakebite.backends.interpreter;


private:


// Interprets guest code by walking dmd's own AST, using visitor classes
// derived from dmd's `Visitor` base (`dmd.visitor.Visitor`). Every
// intermediate result is evaluated straight into a caller-designated
// native address, in native layout, never boxed into a dmd AST node or any
// other host-side representation - a nested guest-to-guest call reuses the
// same destination its enclosing expression was given, so `f(g(x))` writes
// `g`'s result directly where `f` wants it. No frame stack or locals yet
// (future work); only function parameters have storage right now.
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

        scope walker = new StatementWalker(
            function_.type.nextOf, returnPlace, Frame.init,
        );
        body_.accept(walker);
    }

    public override string eval(FuncDeclaration function_) {
        throw new Exception(
            "eval not implemented for the interpreter yet",
        );
    }
}

// One function activation's native parameter storage: a contiguous buffer
// laid out at the byte offsets a compiled call would use, plus a lookup
// from each parameter's `VarDeclaration` to its offset, so a body that
// reads a parameter (`VarExp`) finds it directly instead of re-evaluating
// anything. Locals join this once a test needs them; for now only
// parameters have slots.
private struct Frame {
    import dmd.declaration: VarDeclaration;

    ubyte[] bytes;
    size_t[VarDeclaration] offsetOf;
}

import dmd.visitor: Visitor;

// Walks statements looking for a `return`, evaluating its expression
// straight into `returnPlace`. Any statement kind it does not know throws,
// naming the AST node kind, instead of silently doing nothing.
extern(C++) private final class StatementWalker: Visitor {
    import dmd.astenums: Tvoid;
    import dmd.mtype: Type;
    import dmd.statement: CompoundStatement, ReturnStatement, Statement;
    import dmd.typesem: size;

    alias visit = Visitor.visit;

    // The return type of the function whose body this walker is walking.
    private Type functionReturnType;
    private void* returnPlace;
    // This function's own parameter storage, so a `return` expression
    // that reads a parameter can resolve it.
    private const Frame frame;

    this(Type functionReturnType, void* returnPlace, in Frame frame) {
        this.functionReturnType = functionReturnType;
        this.returnPlace = returnPlace;
        this.frame = frame;
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
        import std.conv: text;

        if (statement.exp is null)
            return;

        // A `void` return type has no native destination to evaluate
        // into. No current test returns a call/expression from a `void`
        // function (only a bare `return;`, handled above), so that case
        // throws loudly instead of being guessed at.
        if (functionReturnType.ty == Tvoid)
            throw new Exception(
                text("interpreter cannot evaluate a `void`-typed ",
                    "`return` expression: `", statement.exp.toChars, "`"),
            );

        // Evaluation always happens, for any side effects it may have.
        // When the caller does not want the value (`returnPlace is
        // null`), evaluation still happens, into scratch space that is
        // then discarded, rather than being skipped.
        ubyte[] scratch;
        auto target = returnPlace;
        if (target is null) {
            scratch = new ubyte[functionReturnType.size];
            target = scratch.ptr;
        }

        scope evaluator =
            new ExpressionEvaluator(functionReturnType, target, frame);
        statement.exp.accept(evaluator);
    }
}

// Writes one evaluated literal's value into `place` in native layout,
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

// Evaluates one expression node straight into `place`, in native layout,
// exactly `type`'s size - never through a boxed intermediate value. A
// nested call (`CallExp`) reuses `place` as the callee's own return slot,
// so a chain of calls writes straight into the outermost destination
// instead of hopping through any intermediate representation. Throws on
// anything it does not know how to evaluate instead of returning silent
// garbage.
extern(C++) private final class ExpressionEvaluator: Visitor {
    import dmd.expression: CallExp, Expression, IntegerExp, RealExp, VarExp;
    import dmd.mtype: Type;

    alias visit = Visitor.visit;

    private Type type;
    private void* place;
    // The currently executing function's own parameter storage, so an
    // argument expression that reads a parameter (e.g. forwarding it to
    // another call) can resolve it.
    private const Frame frame;

    this(Type type, void* place, in Frame frame) {
        this.type = type;
        this.place = place;
        this.frame = frame;
    }

    override void visit(Expression expression) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toString, "`"),
        );
    }

    override void visit(IntegerExp expression) {
        writeNativeValue(type, expression, place);
    }

    override void visit(RealExp expression) {
        writeNativeValue(type, expression, place);
    }

    override void visit(VarExp expression) {
        import core.stdc.string: memcpy;
        import dmd.typesem: size;
        import std.conv: text;

        auto variable = expression.var.isVarDeclaration;
        auto offset = variable is null ? null : variable in frame.offsetOf;
        if (offset is null)
            throw new Exception(
                text("interpreter cannot read `", expression.toChars,
                    "`: not a parameter in the current frame"),
            );

        // Both sides already agree on `type`'s size and layout (the
        // parameter's declared type), so this is a plain copy, not a
        // conversion.
        memcpy(place, frame.bytes.ptr + *offset, type.size);
    }

    override void visit(CallExp expression) {
        evaluateCall(expression, place, frame);
    }
}

// Calls a guest function reached from within an expression, as opposed to
// `Interpreter.call`, the host-facing entry point: the callee is already
// statically resolved onto the `CallExp` by semantic analysis (`call.f`),
// so no name lookup or virtual dispatch happens here. Arguments are
// evaluated into the callee's own parameter frame, then the callee body is
// walked the same way a top-level call is, writing its `return` value
// straight into `place` - the same destination this call expression itself
// was asked to evaluate into.
private void evaluateCall(
    imported!"dmd.expression".CallExp call,
    void* place,
    in Frame callerFrame,
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

    auto frame = buildFrame(function_, call.arguments, callerFrame);

    scope walker = new StatementWalker(function_.type.nextOf, place, frame);
    body_.accept(walker);
}

// Builds the callee's parameter frame: one slot per parameter at the byte
// offset it would have in a compiled call's frame, and evaluates each
// argument expression straight into its slot, not into some intermediate
// value that then gets copied in. Argument expressions are evaluated
// against the *caller's* own frame (`callerFrame`), since they run before
// the callee's frame exists. Evaluation happens for every argument, even
// ones the callee body never reads, since evaluating an argument can have
// effects of its own.
private Frame buildFrame(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.expression".Expressions* arguments,
    in Frame callerFrame,
) {
    import dmd.astenums: STC;
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

    size_t frameSize = 0;
    if (parameters !is null)
        foreach (parameter; *parameters)
            frameSize = alignUp(frameSize, parameter.type.alignsize) +
                parameter.type.size;

    Frame frame;
    frame.bytes = new ubyte[frameSize];

    if (parameters !is null) {
        size_t offset = 0;
        foreach (i, parameter; *parameters) {
            // A `ref`/`out` parameter occupies a pointer slot in a
            // compiled frame, and `lazy` a delegate; `parameter.type` is
            // still the pointed-to/lazily-evaluated type either way, so
            // writing the argument's value at that type's size would put
            // the wrong bytes in the slot. Not supported yet, so this
            // throws instead of silently writing a value where compiled D
            // would have a pointer.
            if (parameter.storage_class &
                    (STC.ref_ | STC.out_ | STC.lazy_))
                throw new Exception(
                    text("interpreter cannot pass `ref`/`out`/`lazy` ",
                        "parameter `", parameter.toChars, "` by value"),
                );

            offset = alignUp(offset, parameter.type.alignsize);
            frame.offsetOf[parameter] = offset;

            scope argumentEvaluator = new ExpressionEvaluator(
                parameter.type, frame.bytes.ptr + offset, callerFrame,
            );
            (*arguments)[i].accept(argumentEvaluator);

            offset += parameter.type.size;
        }
    }

    return frame;
}

// Rounds `offset` up to the next multiple of `alignment`, so each
// parameter's slot starts at an address as aligned as the type itself.
private size_t alignUp(in size_t offset, in size_t alignment) {
    return (offset + alignment - 1) / alignment * alignment;
}
