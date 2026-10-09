module snakebite.backends.vectorinit;


private:

import snakebite.nativelayout: typeFacts;


import snakebite.nativelayout: TypeFacts;


// Evaluate the source once, then copy its native bytes `count` times. An
// equal-size static array is one copy; a scalar is converted by DMD to the
// lane type before VectorExp is made, and fills every lane.
package struct VectorInitPlan {
    TypeFacts sourceFacts;
    size_t count;
}

package VectorInitPlan planVectorInit(
    imported!"dmd.expression".VectorExp expression,
) {
    import dmd.astenums: Tsarray;
    import dmd.typesem: toBasetype;

    const sourceFacts = typeFacts(expression.e1.type);
    if (expression.e1.type.toBasetype.ty == Tsarray)
        return VectorInitPlan(sourceFacts, 1);

    // `dim` counts destination lanes, not source units: an array conversion
    // can have a different element width. Use native sizes for repetition,
    // as DMD's glue does, including scalar default initialization.
    return VectorInitPlan(sourceFacts,
        typeFacts(expression.type).size / sourceFacts.size);
}
