module snakebite.backends.ctfe;


private:


// Runs guest code with dmd's own compile-time function evaluator.
public final class Ctfe: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;

    // CTFE has no druntime and no I/O, so there is no way to do what
    // compiled D does for a program; only a non-null `entryPoint` can run.
    // A guest failure (a failed assert, an uncaught exception) surfaces as a
    // CTFE diagnostic, which is reported the way druntime reports an escaped
    // `Throwable`: printed, exit status 1.
    public override int run(
        Program program,
        FuncDeclaration entryPoint = null,
    ) {
        import core.stdc.stdio: fprintf, stderr;
        import std.string: toStringz;

        assert(
            entryPoint !is null,
            "`run` without an entry point is not implemented for the CTFE "
            ~ "backend",
        );

        // `const` would qualify the dmd AST reference inside the result.
        auto result = interpret(entryPoint);
        if (result.error is null)
            return 0;

        fprintf(stderr, "%s\n", result.error.toStringz);
        return 1;
    }

    public override string eval(FuncDeclaration function_) {
        // `const` would qualify the dmd AST reference inside the result.
        auto result = interpret(function_);
        if (result.error !is null)
            throw new Exception(result.error);
        return stringValue(result.value);
    }
}

// One CTFE call's outcome: the value on success, the diagnostic text on
// failure. A guest failure is data, not a host exception, because `run` maps
// it to an exit status while `eval` maps it to a thrown `Exception`.
private struct InterpretResult {
    imported!"dmd.expression".Expression value;
    string error;
}

// Call `function_` with no arguments under CTFE. `ctfeInterpret` takes an
// expression, so the call is synthesised and typed by hand: a zero-argument
// call's type is the function's return type.
private InterpretResult interpret(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.dinterpret: ctfeInterpret;
    import dmd.expression: CallExp, VarExp;
    import dmd.globals: global;
    import dmd.location: Loc;
    import snakebite.frontend.compiler:
        diagnosticMessage,
        resetErrors,
        withCompilerLock;

    InterpretResult result;

    // CTFE keeps its state (call stack, depth) in dmd's globals.
    withCompilerLock({
        resetErrors;

        auto callee = new VarExp(Loc.initial, function_);
        callee.type = function_.type;
        auto call = CallExp.create(Loc.initial, callee);
        call.type = function_.type.nextOf;

        result.value = call.ctfeInterpret;

        if (result.value.isErrorExp !is null || global.errors != 0)
            result.error = diagnosticMessage;
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
