module snakebite.backends.bytecode.admission;


private:


public enum hotTargetPercent = 90;

public struct Budget {
    public size_t maxBodyBytes;
    public size_t remainingBodyBytes;
    public size_t remainingCallerBytes;
    public uint maxDepth;
}

public struct Candidate {
    public uint targetCalls;
    public uint totalCalls;
    public size_t bodyBytes;
    public uint depth;
    public bool stable;
}

public enum Rejection {
    none,
    unstableProfile,
    noCalls,
    inconsistentCounts,
    targetShare,
    bodySize,
    callerSize,
    depth,
}

public struct Decision {
    public bool admitted;
    public Rejection rejection;
}

public Decision consider(in Candidate candidate, ref Budget budget)
    pure nothrow @safe
{
    if (!candidate.stable || candidate.totalCalls == uint.max
            || candidate.targetCalls == uint.max)
        return Decision(false, Rejection.unstableProfile);
    if (candidate.totalCalls == 0)
        return Decision(false, Rejection.noCalls);
    if (candidate.targetCalls > candidate.totalCalls)
        return Decision(false, Rejection.inconsistentCounts);

    const threshold = candidate.totalCalls - candidate.totalCalls / 10;
    if (candidate.targetCalls < threshold)
        return Decision(false, Rejection.targetShare);
    if (candidate.bodyBytes > budget.maxBodyBytes
            || candidate.bodyBytes > budget.remainingBodyBytes)
        return Decision(false, Rejection.bodySize);
    if (candidate.bodyBytes > budget.remainingCallerBytes)
        return Decision(false, Rejection.callerSize);
    if (candidate.depth >= budget.maxDepth)
        return Decision(false, Rejection.depth);

    budget.remainingBodyBytes -= candidate.bodyBytes;
    budget.remainingCallerBytes -= candidate.bodyBytes;
    return Decision(true, Rejection.none);
}
