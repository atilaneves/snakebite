module snakebite.backends.casts;


private:


import snakebite.nativelayout: TypeFacts;


// What a `CastExp` reaching `visitUnloweredCast` actually asks a backend
// to do, once dmd's own semantic pass has already proved the source and
// destination types compatible. Both the bytecode compiler and the
// interpreter used to re-derive this from the same `(sourceType.ty,
// destType.ty)` if-chain; `classify` decides it once, and each backend
// keeps only the primitive that executes the chosen kind.
public enum Kind {
    // Bit-identical representations: a plain move of `destFacts.size`
    // bytes. Covers class<->class upcasts, class<->pointer, AA<->AA,
    // pointer<->pointer, equal-width float<->float, equal-width
    // integral<->integral and equal-element-width array<->array.
    copy,
    // class->class where dmd's semantic pass left the cast unlowered
    // (`expressionsem.lowerCastExp`): only when the destination is a base
    // of the source - an upcast, or a cast to an interface the source
    // implements - so the reference is kept as it is. A cast needing a
    // runtime check never reaches a backend this way: dmd lowers it to
    // `_d_cast`, which `LoweringVisitor.visit(CastExp)` dispatches before
    // `visitUnloweredCast` is ever reached.
    classReference,
    integralToFloat,
    floatToIntegral,
    floatWidth,
    sarrayToSlice,
    sarrayToPointer,
    sliceToPointer,
    pointerToArray,
    pointerToIntegral,
    // Dynamic array to dynamic array with a different element width:
    // the byte length stays the same, so the element count scales by
    // the ratio of the two element sizes.
    reinterpretSlice,
    narrow,
    widenSigned,
    widenUnsigned,
    toBool,
    // No kind above applies; `reason` names the source and destination
    // types for the backend's own rejection.
    unsupported,
}

public struct CastPlan {
    public Kind kind;
    public TypeFacts sourceFacts;
    public TypeFacts destFacts;
    // Element count, only meaningful for `sarrayToSlice`.
    public size_t staticLength;
}

// The single decision both backends' cast adapters read: `sourceType` and
// `destType` are `CastExp.e1.type` and `CastExp.type`, both already typed
// by dmd. Callers still special-case whatever is not a type-pair decision
// on their own - `cast(void) e`'s effect-only meaning, and `null`'s own
// destination-clearing write - before reaching here.
public CastPlan classify(
    imported!"dmd.mtype".Type sourceType, imported!"dmd.mtype".Type destType,
) {
    import dmd.astenums: Tbool, Taarray, Tclass, Tpointer, Tsarray;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf;
    import snakebite.nativelayout: isIntegralSize;

    const sourceFacts = TypeFacts.of(sourceType);
    const destFacts = TypeFacts.of(destType);

    if (sourceType.ty == Tclass && destType.ty == Tclass)
        return CastPlan(Kind.classReference, sourceFacts, destFacts);

    if (sourceType.ty == Taarray && destType.ty == Taarray)
        return CastPlan(Kind.copy, sourceFacts, destFacts);

    if ((sourceType.ty == Tclass && destType.ty == Tpointer)
            || (sourceType.ty == Tpointer && destType.ty == Tclass))
        return CastPlan(Kind.copy, sourceFacts, destFacts);

    if (isFloatingType(destType)) {
        if (isFloatingType(sourceType))
            return CastPlan(
                sourceFacts.size == destFacts.size
                    ? Kind.copy : Kind.floatWidth,
                sourceFacts, destFacts,
            );

        if (sourceFacts.isIntegral && isIntegralSize(sourceFacts.size))
            return CastPlan(Kind.integralToFloat, sourceFacts, destFacts);

        return CastPlan(Kind.unsupported, sourceFacts, destFacts);
    }

    if (isFloatingType(sourceType)) {
        if (destFacts.isIntegral && isIntegralSize(destFacts.size))
            return CastPlan(Kind.floatToIntegral, sourceFacts, destFacts);

        return CastPlan(Kind.unsupported, sourceFacts, destFacts);
    }

    if (sourceType.ty == Tpointer && destType.ty == Tpointer)
        return CastPlan(Kind.copy, sourceFacts, destFacts);

    if (sourceType.ty == Tpointer && destFacts.isDynamicArray)
        return CastPlan(Kind.pointerToArray, sourceFacts, destFacts);

    // An explicit pointer-to-integral cast preserves the native address
    // bits; `bool` has truth-conversion semantics instead, so it stays
    // out of this byte-preserving kind.
    if (sourceType.ty == Tpointer && destFacts.isIntegral
            && destType.ty != Tbool)
        return CastPlan(Kind.pointerToIntegral, sourceFacts, destFacts);

    if (sourceType.ty == Tsarray && destFacts.isDynamicArray
            && destType.nextOf !is null
            && sourceType.nextOf.equals(destType.nextOf)) {
        auto plan = CastPlan(Kind.sarrayToSlice, sourceFacts, destFacts);
        plan.staticLength =
            cast(size_t) sourceType.isTypeSArray.dim.toInteger;
        return plan;
    }

    // `xs.ptr`: dmd's own semantic pass for `Id.ptr` on a static array
    // casts straight to a pointer to its element type.
    if (sourceType.ty == Tsarray && destType.ty == Tpointer
            && destType.nextOf !is null
            && sourceType.nextOf.equals(destType.nextOf))
        return CastPlan(Kind.sarrayToPointer, sourceFacts, destFacts);

    // `arr.ptr`: the same lowering, over a dynamic array.
    if (sourceFacts.isDynamicArray && destType.ty == Tpointer
            && destType.nextOf !is null
            && sourceType.nextOf.equals(destType.nextOf))
        return CastPlan(Kind.sliceToPointer, sourceFacts, destFacts);

    if (sourceFacts.isDynamicArray && destFacts.isDynamicArray)
        return CastPlan(
            sourceFacts.elementSize == destFacts.elementSize
                ? Kind.copy : Kind.reinterpretSlice,
            sourceFacts, destFacts,
        );

    if (!sourceFacts.isIntegral || !isIntegralSize(sourceFacts.size)
            || !destFacts.isIntegral)
        return CastPlan(Kind.unsupported, sourceFacts, destFacts);

    // dmd classifies `bool` as `integral | unsigned`, so this has to be
    // checked before the general integral resize below: `cast(bool) x`
    // means `x != 0`, not "keep the low byte".
    if (destType.ty == Tbool)
        return CastPlan(Kind.toBool, sourceFacts, destFacts);

    if (destFacts.size == sourceFacts.size)
        return CastPlan(Kind.copy, sourceFacts, destFacts);

    if (destFacts.size < sourceFacts.size)
        return CastPlan(Kind.narrow, sourceFacts, destFacts);

    return CastPlan(
        sourceFacts.isUnsigned ? Kind.widenUnsigned : Kind.widenSigned,
        sourceFacts, destFacts,
    );
}

// Whether `type` is `float`/`double`/`real` - `TypeFacts` has no notion of
// its own for this, unlike `isIntegral`/`isDynamicArray`, which drive
// checks all over both backends.
private bool isFloatingType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tfloat32, Tfloat64, Tfloat80;

    return type.ty == Tfloat32 || type.ty == Tfloat64 || type.ty == Tfloat80;
}
