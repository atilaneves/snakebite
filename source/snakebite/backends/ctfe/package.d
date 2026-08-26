module snakebite.backends.ctfe;


private:


// Runs guest code with dmd's own compile-time function evaluator.
public final class Ctfe: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;

    // CTFE has no druntime and no I/O, so there is no way to do what
    // compiled D does for a program.
    public override int run(
        Program program,
        FuncDeclaration entryPoint = null,
    ) {
        assert(0, "`run` is not implemented for the CTFE backend");
    }

    public override string eval(FuncDeclaration function_) {
        return stringValue(interpret(function_));
    }
}

// Call `function_` with no arguments under CTFE and return the result.
// `ctfeInterpret` takes an expression, so the call is synthesised and typed
// by hand: a zero-argument call's type is the function's return type.
private imported!"dmd.expression".Expression interpret(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.dinterpret: ctfeInterpret;
    import dmd.expression: CallExp, Expression, VarExp;
    import dmd.globals: global;
    import dmd.location: Loc;
    import snakebite.frontend.compiler:
        diagnosticMessage,
        resetErrors,
        withCompilerLock;

    Expression result;

    // CTFE keeps its state (call stack, depth) in dmd's globals.
    withCompilerLock({
        resetErrors;

        auto callee = new VarExp(Loc.initial, function_);
        callee.type = function_.type;
        auto call = CallExp.create(Loc.initial, callee);
        call.type = function_.type.nextOf;

        result = call.ctfeInterpret;

        if (result.isErrorExp !is null || global.errors != 0)
            throw new Exception(diagnosticMessage);
    });

    return result;
}

// A CTFE string is a `StringExp` when it came from a literal, but a string
// built up at compile time (as `std.conv.text` does) is an `ArrayLiteralExp`
// of character elements.
private string stringValue(imported!"dmd.expression".Expression expression) {
    import std.conv: text;

    if (auto literal = expression.isStringExp)
        return literal.peekString.idup;

    if (auto array = expression.isArrayLiteralExp) {
        string result;
        foreach (element; *array.elements)
            result ~= cast(char) element.toInteger;
        return result;
    }

    throw new Exception(
        text("CTFE result is not a string: `", expression.toChars, "`"),
    );
}
