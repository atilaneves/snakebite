module snakebite.backends.identity;

private:

// The frontend has already established that an IdentityExp is legal.  This
// plan records the native comparison that DMD's e2ir.d emits for it.  The
// backends consume the plan; they do not classify the operand type again.
package struct IdentityPlan {
    size_t width;
    bool staticArray;
    size_t length;
    bool skipCompare;
    bool leftStorage;
    bool rightStorage;
}

package IdentityPlan identityPlan(
    imported!"dmd.expression".IdentityExp expression,
) {
    import dmd.astenums: Tfloat80, Tsarray;
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
    return IdentityPlan(width, false, 0, skipCompare, false, false);
}
