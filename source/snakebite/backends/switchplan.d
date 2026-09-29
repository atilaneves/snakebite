module snakebite.backends.switchplan;

private:

package struct SwitchPlan {
    imported!"dmd.statement".CaseStatement[] cases;
    long[] values;
    imported!"dmd.statement".DefaultStatement defaultTarget;
}

// Semantic analysis has converted string switches to integer dispatch and
// expanded case ranges. Keep the resulting comparison values and targets
// in one plan so both backends select the same case.
package SwitchPlan switchPlan(
    imported!"dmd.statement".SwitchStatement statement,
) {
    import dmd.statement: CaseStatement;
    import dmd.expressionsem: toInteger;

    CaseStatement[] cases;
    long[] values;
    if (statement.cases !is null) {
        foreach (case_; *statement.cases) {
            cases ~= case_;
            values ~= cast(long) case_.exp.toInteger;
        }
    }
    return SwitchPlan(cases, values, statement.sdefault);
}

package imported!"dmd.statement".CaseStatement selectCase(
    SwitchPlan plan,
    long value,
)
    @safe @nogc nothrow scope
{
    foreach (index, case_; plan.cases)
        if (plan.values[index] == value)
            return case_;
    return null;
}

package bool containsTarget(
    SwitchPlan plan,
    imported!"dmd.statement".Statement target,
)
    @safe @nogc nothrow scope
{
    if (target is plan.defaultTarget)
        return true;
    foreach (case_; plan.cases)
        if (target is case_)
            return true;
    return false;
}

package imported!"dmd.statement".CaseStatement gotoCaseTarget(
    imported!"dmd.statement".GotoCaseStatement statement,
)
    @safe @nogc nothrow pure scope
{
    return statement.cs;
}

package imported!"dmd.statement".DefaultStatement gotoDefaultTarget(
    imported!"dmd.statement".GotoDefaultStatement statement,
)
    @safe @nogc nothrow pure scope
{
    return statement.sw is null ? null : statement.sw.sdefault;
}
