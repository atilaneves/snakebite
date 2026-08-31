module snakebite.backends.bytecode.compiler;


private:


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Function, Vm;
    import snakebite.exception: SnakebiteException;
    import snakebite.framestack: defaultFrameCapacity;

    private Vm _vm;
    private FuncDeclaration _funcDeclaration;
    private Function _executable;

    public this(const Program program) {
        super(program);
        _vm = Vm(defaultFrameCapacity);
    }

    public void compile(Program program) {
        if (program.main.func is null)
            throw new SnakebiteException(
                "bytecode compiler needs a program entry function",
            );

        auto executable = compileFunction(program.main.func);
        _funcDeclaration = program.main.func;
        _executable = executable;
    }

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        if (args.length != 0)
            throw new SnakebiteException(
                "bytecode compiler does not support arguments yet",
            );

        if (_funcDeclaration is function_) {
            _vm.call(_executable, returnPlace);
            return;
        }

        auto executable = compileFunction(function_);
        _vm.call(executable, returnPlace);
    }

    public override string eval(FuncDeclaration function_) {
        throw new SnakebiteException(
            "eval not implemented for the bytecode backend yet",
        );
    }
}


private imported!"snakebite.backends.bytecode.vm".Function compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: Tint32;
    import snakebite.backends.bytecode.vm:
        Function, Instruction, opConstantI32, opReturnI32;
    import snakebite.exception: SnakebiteException;
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import std.conv: text;

    if (function_ is null)
        throw new SnakebiteException(
            "bytecode compiler cannot compile a null function",
        );

    auto functionType = typeFunctionOf(function_);
    if (function_.vthis !is null || functionType.parameterList.length != 0)
        throw new SnakebiteException(text(
            "bytecode compiler only supports a zero-argument function: `",
            function_.toString, "`",
        ));

    auto returnType = function_.type.nextOf;
    if (returnType is null || returnType.ty != Tint32)
        throw new SnakebiteException(text(
            "bytecode compiler only supports an `int` return: `",
            function_.toString, "`",
        ));

    auto body = function_.fbody is null
        ? null
        : function_.fbody.isCompoundStatement;
    if (body is null || body.statements is null
            || body.statements.length != 1)
        throw new SnakebiteException(text(
            "bytecode compiler only supports one return statement: `",
            function_.toString, "`",
        ));

    auto returnStatement = (*body.statements)[0].isReturnStatement;
    auto expression = returnStatement is null ? null : returnStatement.exp;
    auto integer = expression is null ? null : expression.isIntegerExp;
    if (integer is null && expression !is null) {
        auto call = expression.isCallExp;
        if (call !is null && call.f !is null
                && (call.arguments is null || call.arguments.length == 0))
            return compileFunction(call.f);
    }

    if (integer is null)
        throw new SnakebiteException(text(
            "bytecode compiler only supports returning an `int` constant: `",
            function_.toString, "`",
        ));

    return Function(
        [
            Instruction(&opConstantI32, 0, cast(int) integer.toInteger),
            Instruction(&opReturnI32, 0, 0),
        ],
        int.sizeof,
        int.alignof,
    );
}
