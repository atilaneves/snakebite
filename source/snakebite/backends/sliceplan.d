module snakebite.backends.sliceplan;


private:


import dmd.typesem: toBasetype;


// The single decision both backends use for the bounds of a `SliceExp`,
// the one dmd makes in its glue layer (`e2ir.d`). The checks are unsigned
// compares. A pointer has no length, so only the order of its bounds can
// fail; an array also needs its upper bound within its length. A check
// the frontend already proved (`lowerIsLessThanUpper`, `upperIsInBounds`)
// is skipped. The failure reports the length of an array source, and `0`
// for a pointer, as compiled D does.
public struct SlicePlan {
    public bool checkOrder;
    public bool checkUpper;
    public bool reportsSourceLength;
    // dmd types a slice with compile-time bounds as `T[N]` when it converts
    // it to a static array. Its value is then the `N` elements in place, an
    // lvalue, not a length and pointer.
    public bool yieldsStaticArray;
}

public SlicePlan planSlice(imported!"dmd.expression".SliceExp expression) {
    const isPointer = expression.e1.type.toBasetype.isTypePointer !is null;

    return SlicePlan(
        !expression.lowerIsLessThanUpper,
        !isPointer && !expression.upperIsInBounds,
        !isPointer,
        expression.type.toBasetype.isTypeSArray !is null,
    );
}
