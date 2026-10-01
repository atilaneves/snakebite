module snakebite.backends.switchplan;

private:

package struct SwitchPlan {
    imported!"dmd.statement".CaseStatement[] cases;
    imported!"dmd.statement".DefaultStatement defaultTarget;
}

// Semantic analysis has converted string switches to integer dispatch and
// expanded case ranges. Keep the cases and default target in one plan so
// both backends select the same case.
package SwitchPlan switchPlan(
    imported!"dmd.statement".SwitchStatement statement,
) {
    import dmd.statement: CaseStatement;

    CaseStatement[] cases;
    if (statement.cases !is null)
        cases = (*statement.cases)[];
    return SwitchPlan(cases, statement.sdefault);
}

package imported!"dmd.statement".CaseStatement selectCase(
    SwitchPlan plan,
    long value,
    scope long delegate(
        imported!"dmd.statement".CaseStatement,
    ) caseValue,
) {
    foreach (case_; plan.cases)
        if (switchCaseMatches(value, caseValue(case_)))
            return case_;
    return null;
}

package bool switchCaseMatches(long value, long caseValue)
    @safe @nogc nothrow pure scope
{
    return value == caseValue;
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
