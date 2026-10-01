module snakebite.backends.exceptions;


private:


import object: Throwable, TypeInfo_Class;


public void unwindFinally(
    Throwable throwable,
    scope void delegate() cleanup,
) {
    try {
        throw throwable;
    } finally {
        cleanup();
    }
}


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
) @safe @nogc nothrow pure {
    return expected !is null && actual !is null && expected.isBaseOf(actual);
}

// What a failed `assert` reports, decided once from the assertion itself
// so that every backend and mode says the same thing: `message` is D's own
// (`core.exception.onAssertError`'s wording, or the literal an
// `assert(cond, "text")` names), and `file`/`line` are the assertion's own
// guest source location, not wherever in this project's sources a backend
// happened to build the error. A message that is not a literal is
// `messageExpression`, which the backend evaluates when the assertion
// fails: it is what `assert(c, m())` names and what `-checkaction=context`
// makes of a plain `assert(a == b)`. `cAssertion` is the text
// `-checkaction=C` hands the C runtime: the literal, or the asserted
// expression itself; it is null when there is a `messageExpression`.
public struct AssertFailure {
    public string message;
    public string file;
    public size_t line;
    public imported!"dmd.expression".Expression messageExpression;
    public const(char)* cAssertion;
}

public AssertFailure assertFailureOf(
    imported!"dmd.expression".AssertExp expression,
) {
    import std.string: fromStringz;

    auto literal = expression.msg is null ? null : expression.msg.isStringExp;
    const dynamic = expression.msg !is null && literal is null;
    const message = literal is null
        ? "Assertion failure"
        : literal.toStringz.fromStringz.idup;

    return AssertFailure(
        message,
        expression.loc.filename.fromStringz.idup,
        expression.loc.linnum,
        dynamic ? expression.msg : null,
        dynamic ? null
            : literal is null ? expression.e1.toChars : literal.toStringz.ptr,
    );
}

// The arguments of the C runtime's assert failure function
// (`__assert_fail` of glibc and musl), as dmd's glue layer builds them for
// `-checkaction=C` (`e2ir.d`'s `callCAssert`).
public struct CAssertCall {
    public const(char)* assertion;
    public const(char)* file;
    public uint line;
    public const(char)* function_;
}

public CAssertCall cAssertCallOf(
    in const(char)* assertion,
    in imported!"dmd.location".Loc loc,
    imported!"dmd.func".FuncDeclaration function_,
) {
    return CAssertCall(
        assertion,
        loc.filename,
        cast(uint) loc.linnum,
        function_ is null ? "" : function_.toPrettyChars,
    );
}

// What `assert(e1)` must do about `e1`'s own invariant, once its condition
// has already held - dmd's own glue layer (`e2ir.d`'s `visitAssert`) runs
// this only after the condition check, from the same compiler temporary
// the condition itself was read from, so a null class reference or a
// failed condition never reaches an invariant call at all. A class
// reference's invariant is druntime's own job (`_d_invariant` walks every
// base class's own invariant), called through the FFI barrier rather than
// reimplemented; a struct pointer's invariant is a plain guest function
// call to its own merged `inv`, the same call shape
// `dmd.func.FuncDeclaration.addInvariant` already builds for a member
// function's entry/exit check.
public struct AssertInvariantPlan {
    public enum Kind {
        none,    // no invariant call: disabled, or `e1` is neither shape
        class_,  // `e1` is a class reference: call druntime's `_d_invariant`
        struct_, // `e1` is a struct pointer: call `structInvariant` on it
    }

    public Kind kind;
    public imported!"dmd.func".FuncDeclaration structInvariant;
}

// A class reference's invariant call itself goes through
// `snakebite.backends.druntimehooks`'s `DruntimeHook.classInvariant` -
// `_d_invariant` is never referenced by any guest `CallExp`, so there is
// no `FuncDeclaration` to resolve it by, and that module owns its
// mangled linker symbol.
public AssertInvariantPlan assertInvariantPlanOf(
    imported!"dmd.expression".AssertExp expression,
    in imported!"snakebite.frontend.checks".Checks checks,
) {
    import dmd.astenums: CHECKENABLE, Tclass, Tpointer, Tstruct;
    import dmd.typesem: nextOf, toBasetype;
    import snakebite.backends.checkplan: assertPlanOf, FailurePlan;

    auto none = AssertInvariantPlan(AssertInvariantPlan.Kind.none);

    // `-checkaction=halt` compiles `assert(e)` as `e || halt`, and `C` as
    // `e || __assert_fail(...)`: neither has an invariant call.
    if (checks.invariants != CHECKENABLE.on
            || assertPlanOf(checks).kind != FailurePlan.Kind.raise)
        return none;

    auto type = expression.e1.type.toBasetype;

    // Mirrors `e2ir.d`'s own two conditions exactly: an interface or a
    // C++ class has no `_d_invariant`-compatible invariant of its own, and
    // a struct pointer only qualifies once its pointee actually has a
    // merged `inv` - most structs do not.
    if (type.ty == Tclass) {
        auto sym = type.isTypeClass.sym;
        return sym.isInterfaceDeclaration is null && !sym.isCPPclass
            ? AssertInvariantPlan(AssertInvariantPlan.Kind.class_)
            : none;
    }

    if (type.ty != Tpointer || type.nextOf.ty != Tstruct)
        return none;

    auto inv = type.nextOf.isTypeStruct.sym.inv;
    return inv is null
        ? none
        : AssertInvariantPlan(AssertInvariantPlan.Kind.struct_, inv);
}
