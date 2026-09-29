module snakebite.backends.exceptionplan;


private:


import object: TypeInfo_Class;
import snakebite.backends.controlflow: ScopeFrame;
import snakebite.backends.unwindplan:
    ExceptionCandidate;


public struct CatchPlan {
    public struct Clause {
        import dmd.statement: Catch;

        public Catch syntax;
        public TypeInfo_Class type;
    }

    public Clause[] clauses;

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
        import dmd.statement: Statement;

        public const(void)* owner;
        public Statement body;
    }

    // D runs inner cleanup before outer cleanup.
    public Finalizer[] finalizers;
}

public UnwindPlan unwindPlanOf(
    scope ScopeFrame[] source,
    scope ScopeFrame[] destination,
) @safe {
    import snakebite.backends.unwindplan: resolve = unwindPlanOf;

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

    ExceptionCandidate[] candidates;
    ScopeFrame[] finalizerFrames;
    foreach (frame; source[0 .. sourceEnd]) {
        if (!frame.cleanup)
            continue;

        candidates ~= ExceptionCandidate(
            frame.owner,
            ExceptionCandidate.Kind.finally_,
            null,
        );
        finalizerFrames ~= frame;
    }

    auto resolved = resolve(candidates, null);
    UnwindPlan plan;
    foreach (finalizer; resolved.finalizers)
        plan.finalizers ~= UnwindPlan.Finalizer(
            finalizerFrames[finalizer.candidateIndex].owner,
            finalizerFrames[finalizer.candidateIndex].finallyBody,
        );
    return plan;
}

public UnwindPlan unwindPlanOf(
    scope ScopeFrame[] source,
) @safe {
    return unwindPlanOf(source, null);
}
