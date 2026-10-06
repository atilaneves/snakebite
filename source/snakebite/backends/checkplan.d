module snakebite.backends.checkplan;


private:


import snakebite.frontend.checks: Checks;


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

public FailurePlan nullDerefPlanOf(in Checks checks) @safe pure nothrow @nogc {
    return planFor(checks.nullDeref, checks);
}

// What `-checkaction=C` passes to the C runtime for a null dereference.
public enum nullDerefCMessage = "null pointer dereference";

// A call that reads the vtable of its receiver: dmd's glue layer checks the
// receiver there, after it evaluates the arguments. A `final` method, a
// `super` call and a constructor are direct calls with no such read.
public bool readsVtable(
    in imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration callee,
) {
    import dmd.funcsem: isVirtualMethod;

    return !call.directcall && callee.isVirtualMethod;
}

// `function_` is the function whose code holds the check:
// `-release` checks bounds only in `@safe` code, and code in a C module is
// never checked, as dmd's glue layer decides (`IRState.arrayBoundsCheck`).
// A flexible array member has length 0 and is indexed past it.
public FailurePlan boundsPlanOf(
    in Checks checks,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: CHECKENABLE, FileType, TRUST;

    const module_ = function_ is null ? null : function_.getModule;
    if (module_ !is null && module_.filetype == FileType.c)
        return planFor(CHECKENABLE.off, checks);

    final switch (checks.arrayBounds) with (CHECKENABLE) {
        case _default:
            assert(0);
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
public imported!"snakebite.backends.druntimehooks".DruntimeHook hookOf(
    in BoundsCheck check,
) @safe pure nothrow @nogc {
    import snakebite.backends.druntimehooks: DruntimeHook;

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
            assert(0);
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
