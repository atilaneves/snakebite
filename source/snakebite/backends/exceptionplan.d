module snakebite.backends.exceptionplan;


private:


import object: TypeInfo_Class;
import snakebite.backends.controlflow: ScopeFrame;
import snakebite.backends.exceptions: catchMatches;


public struct CatchPlan {
    public struct Clause {
        public imported!"dmd.statement".Catch syntax;
        public TypeInfo_Class type;
    }

    public Clause[] clauses;

    public size_t matchingClause(TypeInfo_Class actual)
        const @nogc nothrow pure scope
    {
        foreach (index, clause; clauses)
            if (catchMatches(clause.type, actual))
                return index;

        return size_t.max;
    }
}

public CatchPlan catchPlanOf(
    imported!"dmd.statement".TryCatchStatement statement,
    scope TypeInfo_Class delegate(imported!"dmd.statement".Catch) typeOf,
) {
    CatchPlan plan;
    foreach (catch_; *statement.catches)
        plan.clauses ~= CatchPlan.Clause(catch_, typeOf(catch_));
    return plan;
}

public struct UnwindPlan {
    public struct Finalizer {
        public const(void)* owner;
        public imported!"dmd.statement".Statement body;
    }

    // D runs inner cleanup before outer cleanup.
    public Finalizer[] finalizers;
}

public UnwindPlan unwindPlanOf(
    scope ScopeFrame[] source,
    scope ScopeFrame[] destination,
) @safe {
    size_t sourceEnd = source.length;
    size_t destinationEnd = destination.length;
    while (sourceEnd != 0 && destinationEnd != 0
            && source[sourceEnd - 1].owner
                == destination[destinationEnd - 1].owner) {
        --sourceEnd;
        --destinationEnd;
    }

    // Semantic analysis does not allow a control transfer into a protected
    // scope. Every transfer to a valid destination leaves a suffix of the
    // source path.
    assert(destinationEnd == 0);

    UnwindPlan plan;
    foreach (frame; source[0 .. sourceEnd]) {
        if (!frame.cleanup)
            continue;

        plan.finalizers ~= UnwindPlan.Finalizer(
            frame.owner, frame.finallyBody,
        );
    }
    return plan;
}

public UnwindPlan unwindPlanOf(
    scope ScopeFrame[] source,
) @safe {
    return unwindPlanOf(source, null);
}
