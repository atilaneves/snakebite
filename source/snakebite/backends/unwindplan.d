module snakebite.backends.unwindplan;


private:


import snakebite.internalfailure: internalFailure;


import object: Throwable, TypeInfo_Class;


// `throwable` is `null` while an exception that is no `Throwable` unwinds,
// and then it is already in flight.
public void unwindFinally(
    Throwable throwable,
    scope void delegate() cleanup,
) {
    if (throwable is null) {
        cleanup();
        return;
    }

    try {
        throw throwable;
    } finally {
        cleanup();
    }
}


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

    // The finalizers of the candidates that the exception passes, in order.
    // A view of the candidates: a throw inside a destructor that the GC
    // finalizer runs cannot allocate.
    public struct Finalizers {
        private const(ExceptionCandidate)[] _candidates;
        private size_t _next;
        private size_t _end;

        public int opApply(scope int delegate(Step) @safe body_) const @safe {
            foreach (index; _next .. _end)
                if (_candidates[index].kind
                        == ExceptionCandidate.Kind.finally_)
                    if (const result = body_(step(index)))
                        return result;
            return 0;
        }

        public size_t length() const @safe @nogc nothrow pure {
            size_t count;
            foreach (index; _next .. _end)
                count += _candidates[index].kind
                    == ExceptionCandidate.Kind.finally_;
            return count;
        }

        public Step opIndex(in size_t position) const @safe @nogc nothrow pure {
            size_t seen;
            foreach (index; _next .. _end)
                if (_candidates[index].kind
                        == ExceptionCandidate.Kind.finally_) {
                    if (seen == position)
                        return step(index);
                    ++seen;
                }
            internalFailure("no such finalizer");
        }

        private Step step(in size_t index) const @safe @nogc nothrow pure {
            const candidate = _candidates[index];
            return Step(
                candidate.owner, candidate.kind, candidate.payload, index);
        }
    }

    public Finalizers finalizers;
    public Step handler;
    public bool hasHandler;
    public size_t nextCandidate;
}

// Candidates are ordered from the innermost protected scope outwards.
// Catch candidates for one scope stay in source order. A finalizer runs
// before the next enclosing scope can handle the same exception. The plan
// refers to `candidates`, which therefore outlive it. A `null` `actual` is an
// exception that is no `Throwable`: no catch takes it and every finalizer
// runs.
public UnwindPlan unwindPlanOf(
    return scope const(ExceptionCandidate)[] candidates,
    TypeInfo_Class actual,
    size_t startCandidate = 0,
) @safe {
    import snakebite.backends.exceptions: catchMatches;

    UnwindPlan plan;
    plan.nextCandidate = startCandidate;
    plan.finalizers = UnwindPlan.Finalizers(
        candidates, startCandidate, candidates.length);
    foreach (index; startCandidate .. candidates.length) {
        const candidate = candidates[index];
        plan.nextCandidate = index + 1;
        with (ExceptionCandidate.Kind) final switch (candidate.kind) {
        case finally_:
            continue;
        case catch_:
            if (!catchMatches(candidate.type, actual))
                continue;

            plan.handler = UnwindPlan.Step(
                candidate.owner, candidate.kind, candidate.payload, index,
            );
            plan.hasHandler = true;
            plan.finalizers._end = index;
            break;
        }
        break;
    }

    return plan;
}
