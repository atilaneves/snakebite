module snakebite.backends.switchplan;

private:

package struct SwitchPlan {
    enum NoMatch { defaultTarget, exit }

    imported!"dmd.statement".CaseStatement[] cases;
    imported!"dmd.statement".DefaultStatement defaultTarget;
    // A case value is a `const` or `immutable` variable, known only at run
    // time. dmd then tests the cases in order (`hasVars`); otherwise each
    // case value is a constant.
    bool caseVariables;

    NoMatch noMatch() const @safe @nogc nothrow pure scope {
        // statementsem can omit the default for an exhaustive final enum
        // switch with assertions off. Native s2ir then uses the break block.
        return defaultTarget is null ? NoMatch.exit : NoMatch.defaultTarget;
    }
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
    return SwitchPlan(cases, statement.sdefault, statement.hasVars);
}

// The constant case values of a switch with no case variables, in
// ascending order, with the index in `plan.cases` of the case of each one.
// A value is the integral value of the case expression in the type of the
// condition, as a `long` with the bits that a value of that type has.
package struct CaseTable {
    long[] values;
    size_t[] cases;
}

package CaseTable caseTableOf(SwitchPlan plan) {
    import dmd.expressionsem: toInteger;
    import std.algorithm: sort;
    import std.range: zip;

    assert(!plan.caseVariables);
    auto table = CaseTable(new long[plan.cases.length],
        new size_t[plan.cases.length]);
    foreach (i, case_; plan.cases) {
        assert(case_.exp.isIntegerExp !is null,
            "dmd makes the value of a case with no variable a constant");
        table.values[i] = cast(long) case_.exp.toInteger;
        table.cases[i] = i;
    }
    zip(table.values, table.cases).sort!((a, b) => a[0] < b[0]);
    return table;
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
