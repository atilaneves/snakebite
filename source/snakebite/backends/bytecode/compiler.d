module snakebite.backends.bytecode.compiler;


private:


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Executable, Vm;
    import snakebite.exception: SnakebiteException;

    private enum frameCapacity = 1024 * 1024;

    private Vm _vm;
    private FuncDeclaration _compiledFunction;
    private Executable _compiledExecutable;

    public this(const Program program) {
        super(program);
        _vm = Vm(frameCapacity);
    }

    public void compile(Program program) {
        if (program.main.func is null)
            throw new SnakebiteException(
                "bytecode compiler needs a program entry function",
            );

        auto executable = compileFunction(program.main.func);
        _compiledFunction = program.main.func;
        _compiledExecutable = executable;
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

        if (_compiledFunction is function_) {
            _vm.call(_compiledExecutable, returnPlace);
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


private imported!"snakebite.backends.bytecode.vm".Executable compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: Tint32;
    import snakebite.backends.bytecode.vm:
        Executable, Instruction, opConstantI32, opReturnI32;
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
    auto integer = returnStatement is null || returnStatement.exp is null
        ? null
        : returnStatement.exp.isIntegerExp;
    if (integer is null)
        throw new SnakebiteException(text(
            "bytecode compiler only supports returning an `int` constant: `",
            function_.toString, "`",
        ));

    return Executable(
        [
            Instruction(&opConstantI32, 0, cast(int) integer.toInteger),
            Instruction(&opReturnI32, 0, 0),
        ],
        int.sizeof,
        int.alignof,
    );
}
