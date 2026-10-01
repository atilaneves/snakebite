module snakebite.backends.shifts;

private:

import snakebite.nativelayout: TypeFacts;

// How a shift (`<<`, `>>`, `>>>` and the compound forms) runs. dmd gives the left
// operand the common type of both promoted operands, which can be wider
// than the target (`int <<= long`) or differ from it in signedness
// (`int >>= uint`), so the width, the count mask and the kind of right
// shift come from that operation type, not from the target's own.
package struct ShiftPlan {
    enum Direction {
        left,
        rightArithmetic,
        rightLogical,
    }

    Direction direction;
    // Bytes the shift runs at; the count is masked to `width * 8` bits as
    // the CPU does.
    size_t width;
    // Whether the target widens to `width` by sign extension.
    bool signExtend;
}

// The operands of a plain shift are already promoted, so the left
// operand's own type is the operation type.
package ShiftPlan shiftPlan(imported!"dmd.expression".BinExp expression) {
    const facts = TypeFacts.of(expression.e1.type);
    const direction = expression.isShlExp
        ? ShiftPlan.Direction.left
        : expression.isUshrExp || facts.isUnsigned
            ? ShiftPlan.Direction.rightLogical
            : ShiftPlan.Direction.rightArithmetic;

    return ShiftPlan(direction, facts.size, !facts.isUnsigned);
}

package ShiftPlan shiftPlan(
    imported!"dmd.expression".BinAssignExp expression,
) {
    import snakebite.frontend.storage: compoundTarget;

    const targetFacts = TypeFacts.of(compoundTarget(expression).type);
    const width = TypeFacts.of(expression.e1.type).size;
    const direction = directionOf(expression);

    // On x86-64 a shift whose operation type is `int`-wide runs at the
    // width of a narrower target, so `>>>=` sees its unsigned bit pattern.
    const narrowLogical = direction == ShiftPlan.Direction.rightLogical
        && targetFacts.size < width && width == int.sizeof;

    return ShiftPlan(direction, width,
        !targetFacts.isUnsigned && !narrowLogical);
}

// `>>=` is arithmetic by the signedness of the type under the promotion
// cast, which is how dmd's code generator picks its instruction.
private ShiftPlan.Direction directionOf(
    imported!"dmd.expression".BinAssignExp expression,
) {
    with (ShiftPlan.Direction) {
        if (expression.isShlAssignExp)
            return left;
        if (expression.isUshrAssignExp)
            return rightLogical;

        auto shifted = expression.e1;
        if (auto promotion = shifted.isCastExp)
            shifted = promotion.e1;
        return TypeFacts.of(shifted.type).isUnsigned
            ? rightLogical : rightArithmetic;
    }
}
