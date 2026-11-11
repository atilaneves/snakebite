module snakebite.language.checks;


private:


import snakebite.failure.report: internalFailure;


import snakebite.frontend.checks: Checks;


public import snakebite.failure.unwind: catchMatches, unwindFinally;


// What a run-time check does when it fails, decided once from the
// program's compiler flags so that every backend does the same.
public struct FailurePlan {
    public enum Kind {
        ignore, // the check is not compiled: its operands are not evaluated
        raise,  // throw the error that druntime defines for the check
        halt,   // run the program's halt action
        cAssert, // call the C runtime's assert failure function
    }

    public Kind kind;
}

public FailurePlan assertPlanOf(in Checks checks) @safe pure nothrow @nogc {
    return planFor(checks.assertion, checks);
}

// `-check=nullderef` tests a dereference, the vtable read of a virtual call
// and the value of a function pointer or delegate that is called. It tests
// nothing for a `throw` or for the base of a pointer index: there the
// program does what compiled D does. A `throw` of null faults in druntime,
// and `&p[i]` is pointer arithmetic.
public FailurePlan nullDerefPlanOf(in Checks checks) @safe pure nothrow @nogc {
    return planFor(checks.nullDeref, checks);
}

// What `-checkaction=C` passes to the C runtime for a null dereference.
public enum nullDerefCMessage = "null pointer dereference";

// `function_` is the function whose code holds the check:
// `-release` checks bounds only in `@safe` code, and code in a C module is
// never checked, as dmd's glue layer decides (`IRState.arrayBoundsCheck`).
// A flexible array member has length 0 and is indexed past it.
public FailurePlan boundsPlanOf(
    in Checks checks,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: CHECKENABLE, FileType, TRUST;

    import snakebite.frontend.dmd.functions: moduleOf;

    const module_ = function_ is null ? null : moduleOf(function_);
    if (module_ !is null && module_.filetype == FileType.c)
        return planFor(CHECKENABLE.off, checks);

    final switch (checks.arrayBounds) with (CHECKENABLE) {
        case _default:
            internalFailure();
        case off:
        case on:
            return planFor(checks.arrayBounds, checks);
        case safeonly:
            const type = function_ is null
                ? null
                : function_.type.isTypeFunction;
            return planFor(
                type !is null && type.trust == TRUST.safe ? on : off,
                checks,
            );
    }
}

// dmd builds some nodes without analysing them, so they have no type: the
// `HaltExp` of a `switch` default, and under `-checkaction=C` the `assert(0)`
// there. A backend runs such a node for its effect and gives it no type.
public bool isUnanalysed(
    in imported!"dmd.expression".Expression expression,
) @safe nothrow @nogc {
    return expression.type is null;
}

// The three bounds checks dmd's glue layer emits, which differ in the
// message `-checkaction=C` passes to the C runtime.
public enum BoundsCheck {
    index,
    slice,
    sliceCopy,
}

public string cMessageOf(in BoundsCheck check) @safe pure nothrow @nogc {
    final switch (check) with (BoundsCheck) {
        case index:
            return "array index out of bounds";
        case slice:
            return "array slice out of bounds";
        case sliceCopy:
            return "array overflow";
    }
}

// The druntime function that raises the error of a failed bounds check
// under `-checkaction=D`: the one decision that a backend that raises does
// not make for itself.
public imported!"snakebite.language.call.druntimehook".DruntimeHook hookOf(
    in BoundsCheck check,
) @safe pure nothrow @nogc {
    import snakebite.language.call.druntimehook: DruntimeHook;

    final switch (check) with (BoundsCheck) {
        case index:
            return DruntimeHook.indexBounds;
        case slice:
            return DruntimeHook.sliceBounds;
        case sliceCopy:
            return DruntimeHook.rangeError;
    }
}

private FailurePlan planFor(
    in imported!"dmd.astenums".CHECKENABLE enable,
    in Checks checks,
) @safe pure nothrow @nogc {
    import dmd.astenums: CHECKACTION, CHECKENABLE;

    final switch (enable) with (CHECKENABLE) {
        case _default:
            internalFailure();
        case off:
        case safeonly:
            return FailurePlan(FailurePlan.Kind.ignore);
        case on:
            // `context` differs from `D` only in the message the frontend
            // gives a plain assert.
            final switch (checks.action) with (CHECKACTION) {
                case D:
                case context:
                    return FailurePlan(FailurePlan.Kind.raise);
                case C:
                    return FailurePlan(FailurePlan.Kind.cAssert);
                case halt:
                    return FailurePlan(FailurePlan.Kind.halt);
            }
    }
}


// What a failed `assert` reports, decided once from the assertion itself
// so that every backend and mode says the same thing: `message` is D's own
// (`core.exception.onAssertError`'s wording, or the literal an
// `assert(cond, "text")` names), and `file`/`line` are the assertion's own
// guest source location, not wherever in this project's sources a backend
// happened to build the error. A message that is not a literal is
// `messageExpression`, which the backend evaluates when the assertion
// fails: it is what `assert(c, m())` names and what `-checkaction=context`
// makes of a plain `assert(a == b)`.
public struct AssertFailure {
    public string message;
    public string file;
    public size_t line;
    public imported!"dmd.expression".Expression messageExpression;
}

// `function_` is the function that holds the assertion: druntime's failure
// hook for an assertion directly in a `unittest` block has its own default
// message.
public AssertFailure assertFailureOf(
    imported!"dmd.expression".AssertExp expression,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.string: fromStringz;

    auto literal = expression.msg is null ? null : expression.msg.isStringExp;
    const inUnittest = function_ !is null
        && function_.isUnitTestDeclaration !is null;
    const defaultMessage = inUnittest
        ? "unittest failure"
        : "Assertion failure";
    const message = literal is null
        ? defaultMessage
        : literal.toStringz.fromStringz.idup;

    return AssertFailure(
        message,
        expression.loc.filename.fromStringz.idup,
        expression.loc.linnum,
        messageExpressionOf(expression),
    );
}

// The message of `expression` when it is not a literal, which the backend
// evaluates only if the assertion fails.
public imported!"dmd.expression".Expression messageExpressionOf(
    imported!"dmd.expression".AssertExp expression,
) {
    const dynamic = expression.msg !is null
        && expression.msg.isStringExp is null;

    return dynamic ? expression.msg : null;
}

// The text `-checkaction=C` hands the C runtime for an assertion whose
// message is not an expression: the literal, or the asserted expression
// itself. It prints the expression, so it is made only when this mode
// asks for it.
public const(char)* cAssertionOf(
    imported!"dmd.expression".AssertExp expression,
) {
    auto literal = expression.msg is null ? null : expression.msg.isStringExp;

    return literal is null ? expression.e1.toChars : literal.toStringz.ptr;
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
    import snakebite.frontend.dmd.functions: prettyNameOf;

    return CAssertCall(
        assertion,
        loc.filename,
        cast(uint) loc.linnum,
        function_ is null ? "" : prettyNameOf(function_),
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
// `snakebite.language.call.druntimehook`'s `DruntimeHook.classInvariant` -
// `_d_invariant` is never referenced by any guest `CallExp`, so there is
// no `FuncDeclaration` to resolve it by, and that module owns its
// mangled linker symbol.
public AssertInvariantPlan assertInvariantPlanOf(
    imported!"dmd.expression".AssertExp expression,
    in imported!"snakebite.frontend.checks".Checks checks,
) {
    import dmd.astenums: CHECKENABLE, Tclass, Tpointer, Tstruct;
    import dmd.typesem: nextOf, toBasetype;

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
