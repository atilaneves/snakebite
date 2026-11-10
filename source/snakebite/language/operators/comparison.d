module snakebite.language.operators.comparison;

private:

import snakebite.frontend.typefacts: typeFacts;



import snakebite.failure.report: internalFailure;

import snakebite.native.value: TypeFacts;

package(snakebite) struct ComparisonPlan {
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
    // `dynamicArray` and `staticArray` only: the size of one element of the
    // left operand. Dmd leaves an `EqualExp` unlowered only when the
    // elements compare as their bytes, so every backend compares
    // `length * elementSize` bytes after comparing the lengths.
    size_t elementSize;
}

// Semantic analysis has already applied D's usual arithmetic conversions.
// This plan records the one operand representation and category that both
// backends must use for the comparison.
package(snakebite) ComparisonPlan comparisonPlan(
    imported!"dmd.expression".BinExp expression,
) {
    import dmd.astenums: TY;
    import dmd.typesem: nextOf, toBasetype;

    auto type = expression.e1.type.toBasetype;
    auto plan = ComparisonPlan(kindOf(type), typeFacts(type));
    // dmd's `e2ir.d` compares a static array with a dynamic one as two
    // `{length, ptr}` values.
    if (plan.kind == ComparisonPlan.Kind.staticArray
            && expression.e2.type.toBasetype.ty == TY.Tarray)
        plan.kind = ComparisonPlan.Kind.dynamicArray;
    if (plan.kind == ComparisonPlan.Kind.dynamicArray
            || plan.kind == ComparisonPlan.Kind.staticArray)
        plan.elementSize = typeFacts(type.nextOf).size;
    if (plan.kind == ComparisonPlan.Kind.vector) {
        auto lane = type.isTypeVector.elementType;
        plan.laneKind = kindOf(lane);
        plan.laneFacts = typeFacts(lane);
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


// The frontend has already established that an IdentityExp is legal.  This
// plan records the native comparison that DMD's e2ir.d emits for it.  The
// backends consume the plan; they do not classify the operand type again.
package(snakebite) struct IdentityPlan {
    size_t width;
    bool staticArray;
    size_t length;
    bool skipCompare;
    bool leftStorage;
    bool rightStorage;
    // A pointer or class reference is one word, and `is` on it compares
    // the words as integers.
    bool reference;
}

package(snakebite) IdentityPlan identityPlan(
    imported!"dmd.expression".IdentityExp expression,
) {
    import dmd.astenums: Tclass, Tfloat80, Tnull, Tpointer, Tsarray;
    import dmd.expressionsem: isLvalue, toInteger;
    import dmd.sideeffect: isTrivialExp;
    import dmd.target: target;
    import dmd.typesem: isFloating, size, toBasetype;

    auto type = expression.e1.type.toBasetype;
    auto width = type.size;
    if (type.isFloating && type.ty == Tfloat80)
        width -= target.realpad;
    if (type.ty == Tsarray) {
        auto array = type.isTypeSArray;
        return IdentityPlan(2 * size_t.sizeof, true,
            cast(size_t) array.dim.toInteger, false,
            !isLvalue(expression.e1), !isLvalue(expression.e2));
    }

    const emptyStruct = type.isTypeStruct !is null
        && type.isTypeStruct.sym.fields.length == 0;
    const skipCompare = emptyStruct
        && isTrivialExp(expression.e1) && isTrivialExp(expression.e2);
    const reference = type.ty == Tpointer || type.ty == Tclass
        || type.ty == Tnull;
    return IdentityPlan(width, false, 0, skipCompare, false, false, reference);
}
