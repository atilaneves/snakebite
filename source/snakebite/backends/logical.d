module snakebite.backends.logical;


private:

// What `&&` and `||` do with their right operand. An operand of type `void`
// or `noreturn` has no value for the truth test: dmd types `a || throw e` as
// `bool` anyway, and the only path that completes is the one where the left
// operand decided the answer.
package struct LogicalPlan {
    enum Right {
        value,
        effect,
    }

    bool andAnd;
    Right right;
    bool hasValue;
}

package LogicalPlan logicalPlan(
    imported!"dmd.expression".LogicalExp expression,
) {
    import dmd.astenums: Tnoreturn, Tvoid;
    import dmd.tokens: EXP;
    import dmd.typesem: toBasetype;

    const rightType = expression.e2.type.toBasetype.ty;
    const hasNoValue = rightType == Tvoid || rightType == Tnoreturn;
    return LogicalPlan(
        expression.op == EXP.andAnd,
        hasNoValue ? LogicalPlan.Right.effect : LogicalPlan.Right.value,
        expression.type.toBasetype.ty != Tvoid,
    );
}
