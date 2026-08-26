module snakebite.backends.ctfe;


private:


// Runs guest code with dmd's own compile-time function evaluator.
public final class Ctfe: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        if (args.length != 0)
            throw new Exception(
                "arguments not yet supported by the CTFE backend",
            );

        // `const` would qualify the dmd AST reference inside the result.
        auto result = interpret(function_);
        if (result.error !is null)
            throw new Exception(result.error);

        writeResult(function_, result.value, returnPlace);
    }

    public override string eval(FuncDeclaration function_) {
        // `const` would qualify the dmd AST reference inside the result.
        auto result = interpret(function_);
        if (result.error !is null)
            throw new Exception(result.error);
        return stringValue(result.value);
    }
}

// Writes a CTFE result into the caller's native return place. `null` (the
// caller does not want the value) and `void` (there is no value) both write
// nothing. Integrals and floating point are laid out exactly as compiled D
// would; anything else is not supported yet.
private void writeResult(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.expression".Expression value,
    void* returnPlace,
) {
    import dmd.astenums: Tfloat32, Tfloat64, Tvoid;
    import dmd.typesem: size;
    import std.conv: text;

    auto type = function_.type.nextOf;

    if (returnPlace is null || type.ty == Tvoid)
        return;

    if (type.ty == Tfloat32) {
        *cast(float*) returnPlace = cast(float) value.toReal;
        return;
    }

    if (type.ty == Tfloat64) {
        *cast(double*) returnPlace = cast(double) value.toReal;
        return;
    }

    if (type.isIntegral) {
        const integer = value.toInteger;
        switch (type.size) {
            case 1: *cast(ubyte*) returnPlace = cast(ubyte) integer; return;
            case 2: *cast(ushort*) returnPlace = cast(ushort) integer; return;
            case 4: *cast(uint*) returnPlace = cast(uint) integer; return;
            case 8: *cast(ulong*) returnPlace = cast(ulong) integer; return;
            default:
                throw new Exception(
                    text("CTFE backend cannot return an integral of size ",
                        type.size, ": `", type.toChars, "`"),
                );
        }
    }

    throw new Exception(
        text("CTFE backend cannot return a value of type `",
            type.toChars, "`"),
    );
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
