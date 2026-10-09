module snakebite.backends.casts;


private:


import snakebite.internalfailure: internalFailure;


import snakebite.nativelayout: TypeFacts;
import snakebite.nativevalue: CastKind, CastLayout;


public struct CastPlan {
    // What a `CastExp` reaching `visitUnloweredCast` actually asks a backend
    // to do, once dmd's own semantic pass has already proved the source and
    // destination types compatible. Both the bytecode compiler and the
    // interpreter used to re-derive this from the same `(sourceType.ty,
    // destType.ty)` if-chain; `classify` decides it once, and each backend
    // keeps only the primitive that executes the chosen kind. `kind` is
    // `snakebite.nativevalue.CastKind`, not an enum of its own: that
    // enum is already DMD-free, so it is the one place both this
    // (dmd-typed) classifier and `applyCast`/`applyCastAs`/the VM's own
    // per-kind ops (none of which may import dmd) name a cast's kind.
    public CastKind kind;
    public TypeFacts sourceFacts;
    public TypeFacts destFacts;
    // Element count, only meaningful for `sarrayToSlice`.
    public size_t staticLength;
    public int referenceOffset;
}

private enum TypeKind {
    dynamicArray,
    staticArray,
    associativeArray,
    pointer,
    functionPointer,
    classReference,
    structure,
    delegateValue,
    floating,
    imaginary,
    complex,
    integral,
    nullValue,
    vector,
    other,
}

// The single decision both backends' cast adapters read: `sourceType` and
// `destType` are `CastExp.e1.type` and `CastExp.type`, both already typed
// by dmd. The expression overload below owns the source-shape exception for
// `null`; callers still special-case `cast(void) e`'s effect-only meaning
// before reaching here.
public CastPlan classify(
    imported!"dmd.mtype".Type sourceType, imported!"dmd.mtype".Type destType,
) {
    import dmd.typesem: toBasetype;

    sourceType = sourceType.toBasetype;
    destType = destType.toBasetype;

    return classifyByKind(
        kindOf(sourceType), kindOf(destType), sourceType, destType,
        TypeFacts.of(sourceType), TypeFacts.of(destType),
    );
}


private CastPlan classifyByKind(
    TypeKind sourceKind,
    TypeKind destKind,
    imported!"dmd.mtype".Type sourceType,
    imported!"dmd.mtype".Type destType,
    in TypeFacts sourceFacts,
    in TypeFacts destFacts,
) {
    import dmd.astenums: Tbool;

    // Whatever the source is, a `bool` destination asks for its truth,
    // which `TypeFacts.Truth` states once for every type dmd lets
    // convert to `bool`: dmd's `toBoolean` (`expressionsem.d`) checks
    // `Type.isBoolean` on each operand of `&&` and `||`, and dmd's
    // optimizer then builds the `CastExp` to `bool` for `x && true`
    // out of that checked operand without any cast check of its own.
    if (destType.ty == Tbool)
        return CastPlan(CastKind.truth, sourceFacts, destFacts);

    final switch (sourceKind) with (TypeKind) {
    case nullValue:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case integral:
        return classifyIntegral(destKind, sourceFacts, destFacts);
    case floating:
        return classifyFloating(destKind, sourceFacts, destFacts);
    case imaginary:
        return classifyImaginary(destKind, sourceFacts, destFacts);
    case complex:
        return classifyComplex(destKind, sourceFacts, destFacts);
    case pointer, functionPointer:
        return classifyPointer(destKind, sourceFacts, destFacts);
    case classReference:
        return classifyClass(
            destKind, sourceType, destType, sourceFacts, destFacts);
    case associativeArray:
        return classifyAssociativeArray(
            destKind, sourceFacts, destFacts);
    case delegateValue:
        return classifyDelegate(destKind, sourceFacts, destFacts);
    case dynamicArray:
        return classifyDynamicArray(
            destKind, sourceFacts, destFacts);
    case staticArray:
        return classifyStaticArray(
            destKind, sourceType, destType, sourceFacts, destFacts);
    case structure, vector:
        return classifyFatValue(
            destKind, sourceFacts, destFacts);
    case other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyIntegral(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case integral:
        if (destFacts.size == sourceFacts.size)
            return CastPlan(CastKind.copy, sourceFacts, destFacts);
        if (destFacts.size < sourceFacts.size)
            return CastPlan(CastKind.narrow, sourceFacts, destFacts);
        return CastPlan(
            sourceFacts.isUnsigned
                ? CastKind.widenUnsigned : CastKind.widenSigned,
            sourceFacts, destFacts,
        );
    case floating:
        return CastPlan(CastKind.integralToFloat, sourceFacts, destFacts);
    case complex:
        return CastPlan(CastKind.integralToComplex, sourceFacts, destFacts);
    case imaginary:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case pointer, functionPointer:
        return CastPlan(
            destFacts.size == sourceFacts.size
                ? CastKind.copy
                : sourceFacts.isUnsigned
                    ? CastKind.widenUnsigned : CastKind.widenSigned,
            sourceFacts, destFacts,
        );
    case dynamicArray, staticArray, associativeArray, classReference,
        structure, delegateValue, nullValue, vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyFloating(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case integral:
        return CastPlan(CastKind.floatToIntegral, sourceFacts, destFacts);
    case floating:
        return CastPlan(
            sourceFacts.size == destFacts.size
                ? CastKind.copy : CastKind.floatWidth,
            sourceFacts, destFacts,
        );
    case imaginary:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case complex:
        return CastPlan(CastKind.realToComplex, sourceFacts, destFacts);
    case pointer, functionPointer:
        return CastPlan(CastKind.floatToPointer, sourceFacts, destFacts);
    case dynamicArray, staticArray, associativeArray, classReference,
        structure, delegateValue, nullValue, vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyImaginary(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case integral:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case floating:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case imaginary:
        return CastPlan(
            sourceFacts.size == destFacts.size
                ? CastKind.copy : CastKind.floatWidth,
            sourceFacts, destFacts,
        );
    case complex:
        return CastPlan(CastKind.imaginaryToComplex, sourceFacts, destFacts);
    case pointer, functionPointer:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case dynamicArray, staticArray, associativeArray, classReference,
        structure, delegateValue,
        nullValue, vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyComplex(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case integral:
        return CastPlan(CastKind.complexToIntegral, sourceFacts, destFacts);
    case floating:
        return CastPlan(CastKind.complexToReal, sourceFacts, destFacts);
    case imaginary:
        return CastPlan(CastKind.complexToImaginary, sourceFacts, destFacts);
    case complex:
        return CastPlan(
            sourceFacts.size == destFacts.size
                ? CastKind.copy : CastKind.complexWidth,
            sourceFacts, destFacts,
        );
    case pointer, functionPointer:
        return CastPlan(
            CastKind.complexToIntegral, sourceFacts, destFacts);
    case dynamicArray, staticArray, associativeArray, classReference,
        structure, delegateValue,
        nullValue, vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyPointer(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case integral:
        // dmd's `toElemCast` treats pointers as target-width unsigned
        // integers: a same-width cast paints the type without a value read.
        return CastPlan(
            sourceFacts.size == destFacts.size
                ? CastKind.copy : CastKind.pointerToIntegral,
            sourceFacts, destFacts,
        );
    case floating:
        return CastPlan(CastKind.pointerToFloat, sourceFacts, destFacts);
    case dynamicArray:
        return CastPlan(CastKind.pointerToArray, sourceFacts, destFacts);
    case imaginary:
        return CastPlan(CastKind.zero, sourceFacts, destFacts);
    case complex:
        return CastPlan(CastKind.integralToComplex, sourceFacts, destFacts);
    case pointer, functionPointer, classReference, associativeArray:
        return CastPlan(CastKind.copy, sourceFacts, destFacts);
    case staticArray, structure, delegateValue, nullValue, vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyClass(
    TypeKind destKind,
    imported!"dmd.mtype".Type sourceType,
    imported!"dmd.mtype".Type destType,
    in TypeFacts sourceFacts,
    in TypeFacts destFacts,
) {
    if (destKind == TypeKind.classReference) {
        auto plan = CastPlan(
            CastKind.classReference, sourceFacts, destFacts);
        destType.isTypeClass.sym.isBaseOf(
            sourceType.isTypeClass.sym, &plan.referenceOffset);
        return plan;
    }

    final switch (destKind) with (TypeKind) {
    case pointer, functionPointer, associativeArray:
        return CastPlan(CastKind.copy, sourceFacts, destFacts);
    case dynamicArray, staticArray, classReference, structure,
        delegateValue, floating, imaginary, complex, integral, nullValue,
        vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyAssociativeArray(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case pointer, functionPointer, classReference, associativeArray:
        return CastPlan(CastKind.copy, sourceFacts, destFacts);
    case dynamicArray, staticArray, structure, delegateValue, floating,
        imaginary, complex, integral, nullValue, vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyDelegate(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case delegateValue:
        return CastPlan(CastKind.copy, sourceFacts, destFacts);
    case pointer, functionPointer:
        return CastPlan(CastKind.delegateToPointer, sourceFacts, destFacts);
    case dynamicArray, staticArray, associativeArray, classReference,
        structure, floating, imaginary, complex, integral, nullValue, vector,
        other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyDynamicArray(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case dynamicArray:
        return CastPlan(
            sourceFacts.elementSize == destFacts.elementSize
                ? CastKind.copy : CastKind.reinterpretSlice,
            sourceFacts, destFacts,
        );
    case pointer, functionPointer:
        return CastPlan(CastKind.sliceToPointer, sourceFacts, destFacts);
    case staticArray, associativeArray, classReference, structure,
        delegateValue, floating, imaginary, complex, integral, nullValue,
        vector, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyStaticArray(
    TypeKind destKind,
    imported!"dmd.mtype".Type sourceType,
    imported!"dmd.mtype".Type destType,
    in TypeFacts sourceFacts,
    in TypeFacts destFacts,
) {
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf, size;

    final switch (destKind) with (TypeKind) {
    case dynamicArray: {
        const sourceElementSize = sourceType.nextOf.size;
        const destElementSize = destType.nextOf.size;
        auto plan = CastPlan(CastKind.sarrayToSlice, sourceFacts, destFacts);
        if (sourceElementSize == destElementSize) {
            plan.staticLength = cast(size_t) sourceType.isTypeSArray.dim
                .toInteger;
        } else {
            assert(destElementSize != 0
                && (sourceType.isTypeSArray.dim.toInteger
                    * sourceElementSize) % destElementSize == 0);
            plan.staticLength = cast(size_t)(
                sourceType.isTypeSArray.dim.toInteger * sourceElementSize
                    / destElementSize);
        }
        return plan;
    }
    case pointer, functionPointer:
        return CastPlan(CastKind.sarrayToPointer, sourceFacts, destFacts);
    case staticArray, structure, vector:
        if (sourceFacts.size == destFacts.size)
            return CastPlan(CastKind.copy, sourceFacts, destFacts);
        internalFailure("DMD rejects this cast type pair");
    case associativeArray, classReference, delegateValue, floating,
        imaginary, complex, integral, nullValue, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private CastPlan classifyFatValue(
    TypeKind destKind, in TypeFacts sourceFacts, in TypeFacts destFacts,
) {
    final switch (destKind) with (TypeKind) {
    case staticArray, structure, vector:
        if (sourceFacts.size == destFacts.size)
            return CastPlan(CastKind.copy, sourceFacts, destFacts);
        internalFailure("DMD rejects this cast type pair");
    case dynamicArray, associativeArray, pointer, functionPointer,
        classReference, delegateValue, floating, imaginary, complex,
        integral, nullValue, other:
        internalFailure("DMD rejects this cast type pair");
    }
}

private TypeKind kindOf(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    final switch (type.ty) with (TY) {
    case Tarray: return TypeKind.dynamicArray;
    case Tsarray: return TypeKind.staticArray;
    case Taarray: return TypeKind.associativeArray;
    case Tpointer: return TypeKind.pointer;
    case Tfunction: return TypeKind.functionPointer;
    case Tclass: return TypeKind.classReference;
    case Tstruct: return TypeKind.structure;
    case Tdelegate: return TypeKind.delegateValue;
    case Tfloat32, Tfloat64, Tfloat80: return TypeKind.floating;
    case Timaginary32, Timaginary64, Timaginary80:
        return TypeKind.imaginary;
    case Tcomplex32, Tcomplex64, Tcomplex80: return TypeKind.complex;
    case Tint8, Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tint64, Tuns64,
        Tbool, Tchar, Twchar, Tdchar, Tint128, Tuns128, Tenum:
        return TypeKind.integral;
    case Tnull: return TypeKind.nullValue;
    case Tvector: return TypeKind.vector;
    case Treference, Tident, Tnone, Tvoid, Terror, Tinstance, Ttypeof,
        Ttuple, Tslice, Treturn, Ttraits, Tmixin, Tnoreturn, Ttag:
        return TypeKind.other;
    }
}

// A null expression has no source representation to classify. Its cast
// fills the destination with zeros across its native width instead.
public CastPlan classify(
    imported!"dmd.expression".Expression expression,
    imported!"dmd.mtype".Type destType,
) {
    if (expression.isNullExp !is null)
        return CastPlan(
            CastKind.zero, TypeFacts.init, TypeFacts.of(destType));

    return classify(expression.type, destType);
}

// The DMD-free subset of `plan` that `snakebite.nativevalue.applyCast`
// needs to turn its source bytes into its destination bytes -
// `snakebite.backends.bytecode.vm` may not import DMD frontend modules,
// so it reaches `plan.sourceFacts`/`destFacts` through this value
// instead of `CastPlan` itself; `plan.kind` is already the DMD-free
// `CastKind` `applyCast` takes, so it carries straight over with no
// mapping. Only meaningful for a `plan.kind` `applyCast` accepts;
// neither backend calls this for `copy`, `classReference`, `zero`, or
// each of which needs its own control flow instead.
public CastLayout layoutOf(in CastPlan plan) @safe pure nothrow @nogc {
    return CastLayout(
        plan.kind,
        plan.sourceFacts.size,
        plan.destFacts.size,
        plan.sourceFacts.isUnsigned,
        plan.destFacts.isUnsigned,
        plan.sourceFacts.elementSize,
        plan.destFacts.elementSize,
        plan.staticLength,
    );
}
