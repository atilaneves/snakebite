module snakebite.backends.unwindplan;


private:


import object: TypeInfo_Class;


public struct ExceptionCandidate {
    public enum Kind {
        finally_, catch_,
    }

    public const(void)* owner;
    public Kind kind;
    public TypeInfo_Class type;
    public const(void)* payload;
}

public struct UnwindPlan {
    public struct Step {
        public const(void)* owner;
        public ExceptionCandidate.Kind kind;
        public const(void)* payload;
        public size_t candidateIndex;
    }

    public Step[] finalizers;
    public Step handler;
    public bool hasHandler;
    public size_t nextCandidate;
}

// Candidates are ordered from the innermost protected scope outwards.
// Catch candidates for one scope stay in source order. A finalizer runs
// before the next enclosing scope can handle the same exception.
public UnwindPlan unwindPlanOf(
    scope const(ExceptionCandidate)[] candidates,
    TypeInfo_Class actual,
    size_t startCandidate = 0,
) @safe {
    import snakebite.backends.exceptions: catchMatches;

    UnwindPlan plan;
    plan.nextCandidate = startCandidate;
    foreach (index; startCandidate .. candidates.length) {
        auto candidate = candidates[index];
        plan.nextCandidate = index + 1;
        with (ExceptionCandidate.Kind) final switch (candidate.kind) {
        case finally_:
            plan.finalizers ~= UnwindPlan.Step(
                candidate.owner, candidate.kind, candidate.payload, index,
            );
            continue;
        case catch_:
            if (!catchMatches(candidate.type, actual))
                continue;

            plan.handler = UnwindPlan.Step(
                candidate.owner, candidate.kind, candidate.payload, index,
            );
            plan.hasHandler = true;
            break;
        }
        break;
    }

    return plan;
}
