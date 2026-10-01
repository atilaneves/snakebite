module snakebite.backends.checkplan;


private:


import snakebite.frontend.checks: Checks;


// What a run-time check does when it fails, decided once from the
// program's compiler flags so that every backend does the same.
public struct FailurePlan {
    public enum Kind {
        ignore, // the check is not compiled: its operands are not evaluated
        raise,  // throw the error that druntime defines for the check
        halt,   // end the process
    }

    public Kind kind;
}

public FailurePlan assertPlanOf(in Checks checks) @safe pure nothrow @nogc {
    return planFor(checks.assertion, checks);
}

// `function_` is the function whose code holds the check:
// `-release` checks bounds only in `@safe` code.
public FailurePlan boundsPlanOf(
    in Checks checks,
    imported!"dmd.func".FuncDeclaration function_,
) @safe nothrow @nogc {
    import dmd.astenums: CHECKENABLE, TRUST;

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

private FailurePlan planFor(
    in imported!"dmd.astenums".CHECKENABLE enable,
    in Checks checks,
) @safe pure nothrow @nogc {
    import dmd.astenums: CHECKENABLE;

    final switch (enable) with (CHECKENABLE) {
        case _default:
            assert(0);
        case off:
        case safeonly:
            return FailurePlan(FailurePlan.Kind.ignore);
        case on:
            return FailurePlan(
                checks.failure == Checks.Failure.halt
                    ? FailurePlan.Kind.halt
                    : FailurePlan.Kind.raise,
            );
    }
}
