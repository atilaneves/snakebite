module snakebite.backends.arithmetic;

private:

import snakebite.nativelayout: TypeFacts;
import snakebite.nativevalue: ComplexOperands;

// How an arithmetic operator combines its operands. Semantic analysis has
// already applied D's usual arithmetic conversions, so the operation's own
// type decides it.
package struct ArithmeticPlan {
    enum Kind {
        integral,
        // `float`, `double`, `real` and the imaginary types. An imaginary
        // value is stored as its coefficient, and semantic types each mix
        // that changes the kind: `2i * 3i` is a `double`.
        floating,
        complex,
        // A pointer plus or minus an integral offset that dmd has already
        // scaled by the pointee's size.
        pointerOffset,
        // `p - q`: a byte count, which dmd's enclosing `DivExp` scales.
        pointerDifference,
        vector,
    }

    Kind kind;
    TypeFacts facts;
    // `complex` only: what each operand holds.
    ComplexOperands operands;
}

package ArithmeticPlan arithmeticPlan(
    imported!"dmd.expression".BinExp expression,
) {
    import dmd.astenums: Tpointer;
    import dmd.typesem: toBasetype;

    // DMD represents a compound assignment's operation at its target's
    // promoted type, which the assignment's own type does not show.
    auto operationType = expression.isBinAssignExp
        ? expression.e1.type : expression.type;
    auto type = operationType.toBasetype;
    auto kind = arithmeticKind(type);
    if (kind == ArithmeticPlan.Kind.integral
            && expression.e1.type.toBasetype.ty == Tpointer)
        kind = ArithmeticPlan.Kind.pointerDifference;
    auto plan = ArithmeticPlan(kind, TypeFacts.of(type));
    if (kind == ArithmeticPlan.Kind.complex)
        plan.operands = ComplexOperands(complexOperand(expression.e1.type),
            complexOperand(expression.e2.type));
    return plan;
}

package ArithmeticPlan arithmeticPlan(
    imported!"dmd.expression".UnaExp expression,
) {
    import dmd.typesem: toBasetype;
    import std.conv: text;

    auto type = expression.type.toBasetype;
    const kind = arithmeticKind(type);
    assert(kind != ArithmeticPlan.Kind.pointerOffset, text("`",
        expression.toString, "`: D has no unary arithmetic on a pointer"));
    return ArithmeticPlan(kind, TypeFacts.of(type));
}

// How arithmetic in `type` combines its operands.
package ArithmeticPlan.Kind arithmeticKind(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import std.conv: text;

    type = type.toBasetype;
    final switch (type.ty) with (TY) with (ArithmeticPlan.Kind) {
        case Tbool, Tchar, Twchar, Tdchar, Tint8, Tuns8, Tint16, Tuns16,
            Tint32, Tuns32, Tint64, Tuns64:
            return integral;

        case Tfloat32, Tfloat64, Tfloat80,
            Timaginary32, Timaginary64, Timaginary80:
            return floating;

        case Tcomplex32, Tcomplex64, Tcomplex80:
            return complex;

        case Tpointer:
            return pointerOffset;

        case Tvector:
            return vector;

        case Tarray, Tsarray:
            assert(0, text("arithmetic in `", type.toString, "` is an ",
                "array operation: dmd lowers it to a druntime call"));

        case Tstruct, Tclass:
            assert(0, text("arithmetic in `", type.toString, "` is on an ",
                "aggregate: dmd rewrites it to an operator overload call"));

        case Taarray, Tdelegate, Tfunction, Tnull, Tint128, Tuns128, Tenum,
            Tvoid, Tnoreturn, Treference, Tident, Tnone, Terror, Tinstance,
            Ttypeof, Ttuple, Tslice, Treturn, Ttraits, Tmixin, Ttag:
            assert(0, text("`", type.toString, "` is not arithmetic: ",
                "semantic rejects it, and `toBasetype` leaves no enum"));
    }
}

private imported!"snakebite.nativevalue".ComplexOperand complexOperand(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.nativevalue: ComplexOperand;
    import std.conv: text;

    type = type.toBasetype;
    final switch (type.ty) with (TY) with (ComplexOperand) {
        case Tfloat32, Tfloat64, Tfloat80:
            return real_;

        case Timaginary32, Timaginary64, Timaginary80:
            return imaginary;

        case Tcomplex32, Tcomplex64, Tcomplex80:
            return complex;

        case Tbool, Tchar, Twchar, Tdchar, Tint8, Tuns8, Tint16, Tuns16,
            Tint32, Tuns32, Tint64, Tuns64, Tint128, Tuns128, Tpointer,
            Tvector, Tarray, Tsarray, Tstruct, Tclass, Taarray, Tdelegate,
            Tfunction, Tnull, Tenum, Tvoid, Tnoreturn, Treference, Tident,
            Tnone, Terror, Tinstance, Ttypeof, Ttuple, Tslice, Treturn,
            Ttraits, Tmixin, Ttag:
            assert(0, text("`", type.toString, "` is an operand of complex ",
                "arithmetic: semantic converts it to a floating type"));
    }
}
