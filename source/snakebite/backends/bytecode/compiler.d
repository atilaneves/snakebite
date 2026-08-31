module snakebite.backends.bytecode.compiler;


private:


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Function, Vm;
    import snakebite.exception: SnakebiteException;
    import snakebite.framestack: defaultFrameCapacity;

    private Vm _vm;
    private Function[FuncDeclaration] _compiled;
    private bool _prepared;

    public this(const Program program) {
        super(program);
        _vm = Vm(defaultFrameCapacity);
    }

    // Eagerly compiles every execution root of `_program` and everything
    // each root reaches, so a construct none of them can run is rejected
    // before any of them executes. A snippet program with no roots at all
    // (a bare function under test, called directly by `call`) has nothing
    // to prepare here; `call` still compiles such a function on first use.
    public void compile(Program program) {
        prepare;
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

        prepare;

        if (auto found = function_ in _compiled) {
            _vm.call(*found, returnPlace);
            return;
        }

        auto executable = compileFunction(function_);
        _compiled[function_] = executable;
        _vm.call(executable, returnPlace);
    }

    public override string eval(FuncDeclaration function_) {
        throw new SnakebiteException(
            "eval not implemented for the bytecode backend yet",
        );
    }

    // The execution roots this program starts from: module constructors,
    // then either its `main` or every one of its unittests, whichever
    // `_program.main.kind` says this program's entry point actually is.
    // Neither `main` nor a unittest is special-cased by name or shape here
    // - `Program` already resolved which root set applies.
    // `cast()`/`cast(FuncDeclaration[])`: `_program` is a const view, but
    // `compileFunction` and `_compiled` both work in terms of dmd's own
    // (not const-correct) AST types, and this only reads the declarations.
    private FuncDeclaration[] roots() const {
        import snakebite.frontend.dmd.functions: findUnittests;

        auto found = cast(FuncDeclaration[]) _program.moduleConstructors;

        if (_program.main.kind == Program.Main.Kind.dubTestRunner) {
            foreach (module_; _program.rootModules)
                found ~= findUnittests(cast() module_);
        } else if (_program.main.func !is null)
            found ~= cast() _program.main.func;

        return found;
    }

    private void prepare() {
        if (_prepared)
            return;

        foreach (root; roots)
            if (root !in _compiled)
                _compiled[root] = compileFunction(root);

        _prepared = true;
    }
}


private imported!"snakebite.backends.bytecode.vm".Function compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: Tint32, Tvoid;
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
        throw rejection(function_, function_.loc, "a function with parameters");

    auto returnType = function_.type.nextOf;
    const isVoidReturn = returnType !is null && returnType.ty == Tvoid;
    const isIntReturn = returnType !is null && returnType.ty == Tint32;
    if (!isVoidReturn && !isIntReturn)
        throw rejection(function_, function_.loc, text(
            "a `", returnType is null ? "auto" : returnType.toString,
            "` return",
        ));

    auto body = function_.fbody is null
        ? null
        : function_.fbody.isCompoundStatement;
    auto statements = body is null ? null : body.statements;
    const statementCount = statements is null ? 0 : statements.length;

    if (isVoidReturn) {
        foreach (i; 0 .. statementCount) {
            auto statement = (*statements)[i];
            if (!isVoidCompatible(statement))
                throw rejection(function_, statement.loc, statementText(statement));
        }

        return voidReturn;
    }

    if (statementCount != 1)
        throw rejection(function_, function_.loc,
            "a body other than a single `return` statement");

    auto returnStatement = (*statements)[0].isReturnStatement;
    auto expression = returnStatement is null ? null : returnStatement.exp;
    auto integer = expression is null ? null : expression.isIntegerExp;
    if (integer is null && expression !is null) {
        auto call = expression.isCallExp;
        if (call !is null && call.f !is null
                && (call.arguments is null || call.arguments.length == 0))
            return compileFunction(call.f);
    }

    if (integer is null)
        throw rejection(
            function_,
            expression is null ? (*statements)[0].loc : expression.loc,
            statementText((*statements)[0]),
        );

    return Function(
        [
            Instruction(&opConstantI32, 0),
            Instruction(&opReturnI32, 0),
        ],
        [cast(int) integer.toInteger],
        int.sizeof,
        int.alignof,
    );
}

// Whether `statement` carries no meaning the bytecode VM needs to run: an
// empty scope (nested compound statements are transparent, the way any
// number of `{ }` nesting is), or a `return`. A `void`-declared function's
// type forbids a `return` with a value everywhere except the implicit one
// dmd itself appends to `main` for the C entry point's `int` result, so
// accepting any `return` here needs no name check to stay honest to that.
private bool isVoidCompatible(imported!"dmd.statement".Statement statement) {
    if (statement is null)
        return true;

    if (statement.isReturnStatement !is null)
        return true;

    auto compound = statement.isCompoundStatement;
    if (compound is null)
        return false;

    if (compound.statements is null)
        return true;

    foreach (child; *compound.statements)
        if (!isVoidCompatible(child))
            return false;

    return true;
}

private imported!"snakebite.backends.bytecode.vm".Function voidReturn() {
    import snakebite.backends.bytecode.vm: Function, Instruction, opReturnVoid;

    return Function([Instruction(&opReturnVoid, 0)], [], 0, 1);
}

// Renders `statement` back to source text for a rejection message, on one
// line: dmd's own renderer (`toChars`) includes the trailing newline a
// statement carries in source.
private string statementText(imported!"dmd.statement".Statement statement) {
    import dmd.hdrgen: toChars;
    import std.string: fromStringz, strip;
    import std.conv: text;

    return text("`", toChars(statement).fromStringz.strip, "`");
}

// A rejection naming where in the guest source it happened (`loc`), what
// the compiler refused (`operation`), and which function it was compiling.
private imported!"snakebite.exception".SnakebiteException rejection(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.location".Loc loc,
    string operation,
) {
    import snakebite.exception: SnakebiteException;
    import std.conv: text;
    import std.string: fromStringz;

    return new SnakebiteException(text(
        loc.toChars.fromStringz, ": bytecode compiler cannot compile ",
        operation, " in `", function_.toString, "`",
    ));
}
