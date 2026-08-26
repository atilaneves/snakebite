module snakebite.backends.ctfe;


private:


// Runs guest code with dmd's own compile-time function evaluator.
public final class Ctfe: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;

    // With no `entryPoint`, does what druntime's default test mode does:
    // every unittest in the program's root modules, exit status 0 only if
    // all of them pass. CTFE has no druntime and no I/O, so `main` is not
    // run. A guest failure (a failed assert, an uncaught exception)
    // surfaces as a CTFE diagnostic, which is reported the way druntime
    // reports an escaped `Throwable`: printed, exit status 1.
    public override int run(
        Program program,
        FuncDeclaration entryPoint = null,
    ) {
        if (entryPoint !is null)
            return interpretAsEntryPoint(entryPoint);

        int status;
        foreach (module_; program.rootModules)
            foreach (test; unitTests(module_))
                if (interpretAsEntryPoint(test) != 0)
                    status = 1;
        return status;
    }

    public override string eval(FuncDeclaration function_) {
        // `const` would qualify the dmd AST reference inside the result.
        auto result = interpret(function_);
        if (result.error !is null)
            throw new Exception(result.error);
        return stringValue(result.value);
    }
}

// One function as the whole program: interpret it, report a guest failure
// the way druntime reports an escaped `Throwable` (printed, exit status 1).
private int interpretAsEntryPoint(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import core.stdc.stdio: fprintf, stderr;
    import std.string: toStringz;

    // `const` would qualify the dmd AST reference inside the result.
    auto result = interpret(function_);
    if (result.error is null)
        return 0;

    fprintf(stderr, "%s\n", result.error.toStringz);
    return 1;
}

// Every unittest in the module, however deeply nested: at module scope,
// behind attribute declarations (`@("name")`, `static:`, ...), or inside
// aggregates - the same set druntime's default runner executes.
private imported!"dmd.func".FuncDeclaration[] unitTests(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.arraytypes: Dsymbols;
    import dmd.func: FuncDeclaration;

    FuncDeclaration[] tests;

    void collect(Dsymbols* symbols) {
        if (symbols is null)
            return;

        foreach (symbol; *symbols) {
            if (symbol is null)
                continue;

            if (auto test = symbol.isUnitTestDeclaration) {
                tests ~= test;
                continue;
            }

            if (auto attributes = symbol.isAttribDeclaration) {
                collect(attributes.decl);
                continue;
            }

            if (auto aggregate = symbol.isAggregateDeclaration)
                collect(aggregate.members);
        }
    }

    collect(module_.members);
    return tests;
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
