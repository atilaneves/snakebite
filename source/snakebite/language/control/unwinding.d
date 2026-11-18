module snakebite.language.control.unwinding;


private:


import object: TypeInfo_Class;
import snakebite.language.control.transfer: ScopeFrame;
import snakebite.failure.unwind:
    ExceptionCandidate;


// `Type` is how a backend holds the class that a clause catches: a
// `TypeInfo_Class`, or a `Linked!TypeInfo_Class` for a compile that can hold
// its name (`snakebite.ffi.names`).
public struct CatchPlan(Type = TypeInfo_Class) {
    public struct Clause {
        import snakebite.frontend.ast: Catch;

        public Catch syntax;
        // `Type.init` for a clause that no D throwable can match.
        public Type type;
    }

    public Clause[] clauses;

}

public CatchPlan!Type catchPlanOf(Type)(
    imported!"snakebite.frontend.ast".TryCatchStatement statement,
    scope Type delegate(imported!"snakebite.frontend.ast".Catch) typeOf,
) {
    CatchPlan!Type plan;
    foreach (catch_; *statement.catches)
        plan.clauses ~= CatchPlan!Type.Clause(
            catch_, catchesCppClass(catch_) ? Type.init : typeOf(catch_));
    return plan;
}

// A C++ class matches by the C++ type of an in-flight C++ exception. A
// `Throwable` is a D class, so it never matches such a clause, and the
// clause has no `TypeInfo_Class` to match by.
private bool catchesCppClass(imported!"snakebite.frontend.ast".Catch catch_) {
    import snakebite.frontend.typefacts: baseType;

    return catch_.type.baseType.isClassHandle.isCPPclass;
}

public struct UnwindPlan {
    public struct Finalizer {
        import snakebite.frontend.ast: Statement;

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
    import snakebite.failure.unwind: resolve = unwindPlanOf;

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
