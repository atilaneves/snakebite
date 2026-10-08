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
        // `null` for a clause that no D throwable can match.
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
        plan.clauses ~= CatchPlan.Clause(
            catch_, catchesCppClass(catch_) ? null : typeOf(catch_));
    return plan;
}

// A C++ class matches by the C++ type of an in-flight C++ exception. A
// `Throwable` is a D class, so it never matches such a clause, and the
// clause has no `TypeInfo_Class` to match by.
private bool catchesCppClass(imported!"dmd.statement".Catch catch_) {
    import dmd.typesem: toBasetype;

    return catch_.type.toBasetype.isClassHandle.isCPPclass;
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

    // The indices shrink while the common protected-scope suffix is removed.
    auto sourceEnd = source.length;
    auto destinationEnd = destination.length;
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

    const resolved = resolve(candidates, null);
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
