module snakebite.backends.exceptions;


private:


import object: TypeInfo_Class;


// Whether a guest `catch` naming `expected` accepts a throwable whose own
// runtime type is `actual` - the same relation the bytecode VM already
// reads straight off native `TypeInfo_Class` objects for a compiled catch
// clause (`vm.findHandler`), now shared with the interpreter's own
// `matchesThrowable` for the one case it still needs a `TypeInfo_Class`
// comparison at all: a native throwable, which has no guest declaration
// for an AST-level comparison to fall back to. `expected` is `null` for a
// catch clause this backend never resolved a runtime type for; such a
// clause matches nothing.
public bool catchMatches(
    const TypeInfo_Class expected, const TypeInfo_Class actual,
) @nogc nothrow pure {
    return expected !is null && actual !is null && expected.isBaseOf(actual);
}

// What a failed `assert` throws, decided once from the assertion itself
// so that a guest catch sees the same `AssertError` whichever backend
// evaluated it: `message` is D's own (`core.exception.onAssertError`'s
// wording, or the literal an `assert(cond, "text")` names), and
// `file`/`line` are the assertion's own guest source location, not
// wherever in this project's sources a backend happened to build the
// error. A message that is not a literal is not evaluated here.
public struct AssertFailure {
    public string message;
    public string file;
    public size_t line;
}

public AssertFailure assertFailureOf(
    imported!"dmd.expression".AssertExp expression,
) {
    import std.string: fromStringz;

    auto literal = expression.msg is null ? null : expression.msg.isStringExp;
    const message = literal is null
        ? "Assertion failure"
        : literal.toStringz.fromStringz.idup;

    return AssertFailure(
        message,
        expression.loc.filename.fromStringz.idup,
        expression.loc.linnum,
    );
}
