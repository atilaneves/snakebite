module snakebite.backends.compoundassign;

private:

import snakebite.backends.casts: CastPlan;

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
    // From the target's type to the operation's type.
    CastPlan load;
    // From the operation's type back to the target's type.
    CastPlan store;
}

package CompoundConversion compoundConversion(
    imported!"dmd.expression".BinAssignExp expression,
) {
    import snakebite.backends.arithmetic: arithmeticKind;
    import snakebite.backends.casts: classify;
    import snakebite.frontend.storage: compoundTarget;

    auto targetType = compoundTarget(expression).type;
    auto operationType = expression.e1.type;

    return CompoundConversion(
        arithmeticKind(targetType) != arithmeticKind(operationType),
        classify(targetType, operationType),
        classify(operationType, targetType),
    );
}
