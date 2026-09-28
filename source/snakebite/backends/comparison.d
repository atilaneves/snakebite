module snakebite.backends.comparison;

private:

import snakebite.nativelayout: TypeFacts;

package struct ComparisonPlan {
    enum Kind {
        integral,
        floating,
        // Equal when both the real and the imaginary halves are equal.
        complex,
        reference,
        // One comparison per lane, each leaving all-ones or zero bits.
        vector,
    }

    Kind kind;
    TypeFacts facts;
    // `vector` only: how one lane compares, and its facts.
    Kind laneKind;
    TypeFacts laneFacts;
}

// Semantic analysis has already applied D's usual arithmetic conversions.
// This plan records the one operand representation and category that both
// backends must use for the comparison.
package ComparisonPlan comparisonPlan(
    imported!"dmd.expression".BinExp expression,
) {
    import dmd.typesem: toBasetype;

    auto type = expression.e1.type.toBasetype;
    auto plan = ComparisonPlan(kindOf(type), TypeFacts.of(type));
    if (plan.kind == ComparisonPlan.Kind.vector) {
        auto lane = type.isTypeVector.elementType;
        plan.laneKind = kindOf(lane);
        plan.laneFacts = TypeFacts.of(lane);
    }
    return plan;
}

private ComparisonPlan.Kind kindOf(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    final switch (type.ty) with (TY) with (ComparisonPlan.Kind) {
        case Tpointer, Tclass, Tnull:
            return reference;

        case Tfloat32, Tfloat64, Tfloat80,
            Timaginary32, Timaginary64, Timaginary80:
            return floating;

        case Tcomplex32, Tcomplex64, Tcomplex80:
            return complex;

        case Tvector:
            return vector;

        case Tbool, Tchar, Twchar, Tdchar, Tint8, Tuns8, Tint16, Tuns16,
            Tint32, Tuns32, Tint64, Tuns64:
            return integral;

        // The backends compare these before they ask for a plan, and dmd
        // lowers every other comparison of them to a call or an identity.
        case Tstruct, Tarray, Tsarray, Tdelegate, Taarray:
            assert(0);

        // Semantic rejects `cent`/`ucent`, and `toBasetype` leaves no
        // enum; no other kind here is a value.
        case Tint128, Tuns128, Tenum, Tvoid, Tfunction, Tnoreturn,
            Treference, Tident, Tnone, Terror, Tinstance, Ttypeof, Ttuple,
            Tslice, Treturn, Ttraits, Tmixin, Ttag:
            assert(0);
    }
}
