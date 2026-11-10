module snakebite.backends.compoundassign;

private:

import dmd.typesem: toBasetype;

import snakebite.backends.arithmetic: ArithmeticPlan;
import snakebite.backends.casts: CastPlan;
import snakebite.frontend.typefacts: typeFacts;

// DMD represents the target of a compound assignment at its promoted
// operation type. The original target type remains on the assignment node;
// use that pair to remove only this frontend-generated lvalue promotion.
public imported!"dmd.expression".Expression compoundTarget(
    imported!"dmd.expression".BinAssignExp expression,
) {
    const type = expression.type.toBasetype;
    if (sameScalar(expression.e1.type.toBasetype, type))
        return expression.e1;

    // A shift by a wider count promotes the target twice, e.g.
    // `cast(long)cast(int)b` for a `byte`.
    for (auto promotion = expression.e1.isCastExp; promotion !is null;
            promotion = promotion.e1.isCastExp)
        if (sameScalar(promotion.e1.type.toBasetype, type))
            return promotion.e1;
    return expression.e1;
}

// The assignment's own type is `const` when it initialises a `const`
// variable, while the target it promotes is not. The ordinary case is the
// first comparison alone.
private bool sameScalar(
    imported!"dmd.mtype".Type a, in imported!"dmd.mtype".Type b,
) {
    return a.equals(b) || (a.ty == b.ty && a.isTypeBasic !is null);
}

// How a compound assignment `target op= step` moves its target in and out
// of the operation. dmd types the operation in the common type of both
// operands (`int += double` runs as a `double` operation), reads the target
// converted to that type and converts the result back to the target's own
// type. `step` has already been converted to the operation type by dmd.
package struct CompoundConversion {
    // The target and the operation differ in kind, not only in width: an
    // integral target under a floating operation. A same-kind width change
    // stays with the width-only handling each target kind already has.
    bool crossesKind;
    // The target is read before the right operand.
    bool readsTargetFirst;
    // `crossesKind` only. From the target's type to the type the operation
    // runs in.
    CastPlan load;
    // From the operation's own type to the type the operation runs in. The
    // step widens exactly; `copy` when the two are the same type.
    CastPlan step;
    // From the type the operation runs in back to the target's type.
    CastPlan store;
}

package CompoundConversion compoundConversion(
    imported!"dmd.expression".BinAssignExp expression,
) {
    import snakebite.backends.arithmetic: arithmeticKind;
    import snakebite.backends.casts: classify;
    import snakebite.nativevalue: TypeFacts;

    auto targetType = compoundTarget(expression).type;
    auto operationType = expression.e1.type;
    const crossesKind =
        arithmeticKind(targetType) != arithmeticKind(operationType);
    const readsFirst = readsTargetFirst(
        arithmeticKind(operationType), crossesKind,
        typeFacts(targetType).size, typeFacts(operationType).size);
    if (!crossesKind)
        return CompoundConversion(false, readsFirst);

    auto precisionType = operationPrecision(targetType, operationType);
    return CompoundConversion(
        true,
        readsFirst,
        classify(targetType, precisionType),
        classify(operationType, precisionType),
        classify(precisionType, targetType),
    );
}

// dmd reads a promoted floating or complex target before its right operand;
// an integral target keeps the ordinary right-operand-first order. A target
// that crosses kind is always promoted. ldc reads the target after the right
// operand in every case: for `float x = 2; x += cast(double) f(&x)`, where
// `f` stores 10 in `x` and returns 1, dmd gives 3 and ldc gives 11, and
// `int += double` differs the same way. snakebite follows dmd, the host
// compiler of `bin/ut`.
package bool readsTargetFirst(
    in ArithmeticPlan.Kind operationKind, in bool crossesKind,
    in size_t targetSize, in size_t operationSize,
) {
    with (ArithmeticPlan.Kind) final switch (operationKind) {
        case floating, complex:
            return crossesKind || targetSize != operationSize;
        case integral, pointerOffset, pointerDifference, vector:
            return false;
    }
}

// The type native code runs an integral target's floating operation in. The
// operation's own type does not decide it: native widens a `float` step to
// `double` for any integral target, and runs every operation on a `ulong`
// target on the x87 stack in `real`. A `double` or `real` step keeps its
// type.
private imported!"dmd.mtype".Type operationPrecision(
    imported!"dmd.mtype".Type targetType,
    imported!"dmd.mtype".Type operationType,
) {
    import dmd.astenums: TY;
    import dmd.mtype: Type;
    import dmd.typesem: toBasetype;

    if (targetType.toBasetype.ty == TY.Tuns64)
        return Type.tfloat80;
    if (operationType.toBasetype.ty == TY.Tfloat32)
        return Type.tfloat64;
    return operationType;
}
