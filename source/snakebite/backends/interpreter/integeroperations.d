module snakebite.backends.interpreter.integeroperations;

private:

import snakebite.internalfailure: internalFailure;

package ulong combine(string op)(
    in long a,
    in long b,
    in imported!"snakebite.nativelayout".TypeFacts aFacts,
    in imported!"snakebite.nativelayout".TypeFacts bFacts,
) {
    static if (op == "<<" || op == ">>" || op == ">>>")
        // dmd rejects a vector shift and a shift has its own `ShiftPlan`.
        internalFailure();
    else static if (op == "/" || op == "%")
        return divided!op(a, b, sharedSignedness(aFacts, bFacts), aFacts.size);
    else
        // `+`, `-`, `*`, `&`, `|` and `^` leave the same low bits
        // whichever way the operands were widened, so no signedness
        // question arises.
        return cast(ulong) mixin("a " ~ op ~ " b");
}

// The signedness that governs an operation whose answer depends on it.
// dmd's usual arithmetic conversions bring both operands to one common
// type before the interpreter sees the node - a narrower or differently
// signed operand arrives wrapped in a `CastExp` - so the two agree.
private bool sharedSignedness(
    in imported!"snakebite.nativelayout".TypeFacts a,
    in imported!"snakebite.nativelayout".TypeFacts b,
) {
    assert(a.isUnsigned == b.isUnsigned,
        "D arithmetic conversions give both operands one signedness");

    return a.isUnsigned;
}

// D leaves a division by zero undefined. It is not checked here: the host's
// divide instruction raises SIGFPE, as it does for compiled D.
private ulong divided(string op)(
    in long a,
    in long b,
    in bool unsigned,
    in size_t width,
) {
    // A signed operand arrives sign-extended to 64 bits, which is not its
    // value as an operand of the operation's own unsigned type.
    if (unsigned) {
        const mask = width < ulong.sizeof
            ? (1UL << (8 * width)) - 1 : ulong.max;
        return mixin("(cast(ulong) a & mask) " ~ op
            ~ " (cast(ulong) b & mask)");
    }

    // The other input the host's divide instruction traps on:
    // `long.min / -1` has no representable quotient. Negation and a
    // zero remainder are the answers the instruction gives for every
    // other dividend, and the two's complement wrap `long.min` needs.
    if (b == -1) {
        static if (op == "/")
            return -cast(ulong) a;
        else
            return 0;
    }

    return cast(ulong) mixin("a " ~ op ~ " b");
}

// A count outside `[0, width)` is undefined in D; the count is masked as
// compiled D does on the host. `a` is 64 bits here, so a logical shift
// clears the extension above the plan's width first.
package ulong shifted(
    in long a,
    in long count,
    in imported!"snakebite.backends.shifts".ShiftPlan plan,
) {
    import snakebite.nativevalue: shiftCount;

    const width = plan.width * 8;
    const b = shiftCount(count, plan.width);

    with (imported!"snakebite.backends.shifts".ShiftPlan.Direction)
        final switch (plan.direction) {
            case left:
                return cast(ulong) a << b;
            case rightArithmetic:
                return cast(ulong) (a >> b);
            case rightLogical:
                const bits = width == 64
                    ? cast(ulong) a
                    : cast(ulong) a & ((1UL << width) - 1);
                return bits >> b;
        }
}
