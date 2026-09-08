module snakebite.backends.exceptions;


private:


import object: TypeInfo_Class;
import core.exception: AssertError;


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

// The message a failed `assert` reports, shared so a guest catch sees the
// same wording regardless of which backend evaluated the assertion -
// `backend` is the one difference between them, naming which one failed
// it.
public string assertMessage(string backend, const(char)[] conditionText) {
    import std.conv: text;

    return text(backend, ": assertion failed: `", conditionText, "`");
}

// The `AssertError` D's own failed-assertion semantics produce: same
// shape regardless of which backend evaluates the assertion, built at
// `file`/`line` - the guest source location of the assertion itself, not
// wherever in this project's own sources the backend happened to build
// it.
public AssertError assertFailure(string message, string file, size_t line) {
    return new AssertError(message, file, line);
}
