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

// Druntime's `_d_invariant` (`rt.invariant_`) has plain `extern(D)`
// linkage, so its linker symbol is its mangled name, not the bare
// identifier - the same mangled string dmd's own backend hardcodes for
// `RTLSYM.DINVARIANT` (`dmd.backend.drtlsym`), since D name mangling is
// part of the language ABI, not something either compiler is free to
// invent independently. Both backends resolve this same symbol through
// the FFI barrier rather than a `FuncDeclaration` - `_d_invariant` is
// never referenced by any guest `CallExp`, so there is no other way to
// name it.
public enum string classInvariantSymbol =
    "_D2rt10invariant_12_d_invariantFC6ObjectZv";

public AssertInvariantPlan assertInvariantPlanOf(
    imported!"dmd.expression".AssertExp expression,
) {
    import dmd.astenums: CHECKENABLE, Tclass, Tpointer, Tstruct;
    import dmd.globals: global;
    import dmd.typesem: nextOf, toBasetype;

    auto none = AssertInvariantPlan(AssertInvariantPlan.Kind.none);

    if (global.params.useInvariants != CHECKENABLE.on)
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
