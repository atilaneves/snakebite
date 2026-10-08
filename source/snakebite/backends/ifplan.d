module snakebite.backends.ifplan;


private:

// What an `if` does at run time. `__ctfe` is `false` there, so the body of
// an `if (__ctfe)` block never runs through the `if` itself. A `case` or
// `default` label in the body is still a target of the enclosing `switch`,
// and dmd leaves the statements of that body without their lowerings.
package struct IfPlan {
    enum Kind {
        condition,
        ctfeBlock,
    }

    Kind kind;
    bool bodyHasLabels;
}

package IfPlan ifPlan(imported!"dmd.statement".IfStatement statement) {
    if (!statement.isIfCtfeBlock)
        return IfPlan(IfPlan.Kind.condition, false);

    return IfPlan(
        IfPlan.Kind.ctfeBlock,
        statement.ifbody !is null && statement.ifbody.comeFrom,
    );
}
