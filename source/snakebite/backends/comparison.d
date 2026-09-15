module snakebite.backends.comparison;

private:

import snakebite.nativelayout: TypeFacts;

package struct ComparisonPlan {
    enum Kind {
        integral,
        floating,
        reference,
    }

    Kind kind;
    TypeFacts facts;
}

// Semantic analysis has already applied D's usual arithmetic conversions.
// This plan records the one operand representation and category that both
// backends must use for the comparison.
package ComparisonPlan comparisonPlan(
    imported!"dmd.expression".BinExp expression,
) {
    import dmd.astenums: Tclass, Tfloat32, Tfloat64, Tfloat80, Tpointer;
    import dmd.typesem: toBasetype;

    auto type = expression.e1.type.toBasetype;
    const facts = TypeFacts.of(type);

    if (type.ty == Tpointer || type.ty == Tclass)
        return ComparisonPlan(ComparisonPlan.Kind.reference, facts);

    if (type.ty == Tfloat32 || type.ty == Tfloat64 || type.ty == Tfloat80)
        return ComparisonPlan(ComparisonPlan.Kind.floating, facts);

    return ComparisonPlan(ComparisonPlan.Kind.integral, facts);
}
