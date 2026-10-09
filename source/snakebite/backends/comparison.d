module snakebite.backends.comparison;

private:


import snakebite.internalfailure: internalFailure;

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
        // Equal element by element; dmd lowers ordering to `__cmp`. At
        // least one operand is dynamic; the other may be static.
        dynamicArray,
        // Both operands are static; their lengths may differ.
        staticArray,
        // Equal when both words are; ordered as one unsigned integer whose
        // high word is the function pointer.
        delegate_,
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
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;

    auto type = expression.e1.type.toBasetype;
    auto plan = ComparisonPlan(kindOf(type), TypeFacts.of(type));
    // dmd's `e2ir.d` compares a static array with a dynamic one as two
    // `{length, ptr}` values.
    if (plan.kind == ComparisonPlan.Kind.staticArray
            && expression.e2.type.toBasetype.ty == TY.Tarray)
        plan.kind = ComparisonPlan.Kind.dynamicArray;
    if (plan.kind == ComparisonPlan.Kind.vector) {
        auto lane = type.isTypeVector.elementType;
        plan.laneKind = kindOf(lane);
        plan.laneFacts = TypeFacts.of(lane);
    }
    return plan;
}

private ComparisonPlan.Kind kindOf(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import std.conv: text;

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

        case Tarray:
            return dynamicArray;

        case Tsarray:
            return staticArray;

        case Tdelegate:
            return delegate_;

        case Tbool, Tchar, Twchar, Tdchar, Tint8, Tuns8, Tint16, Tuns16,
            Tint32, Tuns32, Tint64, Tuns64:
            return integral;

        case Tstruct, Taarray:
            internalFailure(text("dmd rewrites every comparison of `",
                type.toString, "`: a struct's to an identity or to its ",
                "fields', an associative array's to a call"));

        case Tint128, Tuns128, Tenum, Tvoid, Tfunction, Tnoreturn,
            Treference, Tident, Tnone, Terror, Tinstance, Ttypeof, Ttuple,
            Tslice, Treturn, Ttraits, Tmixin, Ttag:
            internalFailure(text("`", type.toString, "` is not a comparable ",
                "value: semantic rejects `cent`/`ucent`, and `toBasetype` ",
                "leaves no enum"));
    }
}
