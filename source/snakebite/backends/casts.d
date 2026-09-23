module snakebite.backends.casts;


private:


import snakebite.nativelayout: TypeFacts;


public struct CastPlan {
    // What a `CastExp` reaching `visitUnloweredCast` actually asks a backend
    // to do, once dmd's own semantic pass has already proved the source and
    // destination types compatible. Both the bytecode compiler and the
    // interpreter used to re-derive this from the same `(sourceType.ty,
    // destType.ty)` if-chain; `classify` decides it once, and each backend
    // keeps only the primitive that executes the chosen kind.
    public enum Kind {
        // Bit-identical representations: a plain move of `destFacts.size`
        // bytes. Covers class<->class upcasts, class<->pointer, AA<->AA,
        // AA<->pointer, pointer<->pointer, equal-width float<->float,
        // equal-width integral<->integral, delegate<->delegate and
        // equal-element-width array<->array.
        copy,
        // DMD leaves proven upcasts unlowered so code generation can apply
        // the native reference adjustment. Null stays null.
        classReference,
        integralToFloat,
        floatToIntegral,
        floatToBool,
        floatWidth,
        // `complex`/`imaginary` share `floatToBool`/`floatWidth` above
        // wherever their own native layout lines up with a plain
        // `float`/`double`/`real`'s: an imaginary value is one such
        // value on its own, so an imaginary-to-imaginary width change or
        // an imaginary-to-`bool` truth test is the identical byte
        // operation, just fed the imaginary operand's own offset and
        // size. Only the shapes with no such twin get a kind of their
        // own, below.
        complexToBool,
        complexToReal,
        complexToImaginary,
        complexToIntegral,
        complexWidth,
        realToComplex,
        integralToComplex,
        imaginaryToComplex,
        sarrayToSlice,
        sarrayToPointer,
        sliceToPointer,
        pointerToArray,
        pointerToIntegral,
        // `cast(void*) someDelegate`: dmd keeps only the context word
        // (deprecated in favour of `.ptr`, still accepted). The reverse
        // direction, and a delegate to `bool`/an integral, are dmd
        // frontend errors, so this is one-directional.
        delegateToPointer,
        // Dynamic array to dynamic array with a different element width:
        // the byte length stays the same, so the element count scales by
        // the ratio of the two element sizes.
        reinterpretSlice,
        narrow,
        widenSigned,
        widenUnsigned,
        toBool,
        zero,
        // No kind above applies; `reason` names the source and destination
        // types for the backend's own rejection.
        unsupported,
    }

    public Kind kind;
    public TypeFacts sourceFacts;
    public TypeFacts destFacts;
    // Element count, only meaningful for `sarrayToSlice`.
    public size_t staticLength;
    public int referenceOffset;
}

// The single decision both backends' cast adapters read: `sourceType` and
// `destType` are `CastExp.e1.type` and `CastExp.type`, both already typed
// by dmd. The expression overload below owns the source-shape exception for
// `null`; callers still special-case `cast(void) e`'s effect-only meaning
// before reaching here.
public CastPlan classify(
    imported!"dmd.mtype".Type sourceType, imported!"dmd.mtype".Type destType,
) {
    import dmd.astenums:
        Tbool, Taarray, Tclass, Tdelegate, Tnull, Tpointer, Tsarray;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: mutableOf, nextOf, toBasetype;
    import snakebite.nativelayout: isIntegralSize;

    // An enum's own representation is its base type's - unwrapping once
    // here, rather than inside every structural (`.ty`) check below, is
    // what already lets `TypeFacts.of` (which does the same) answer for
    // an enum without a case of its own; the structural checks need the
    // same unwrapping to reach a `Tcomplex*`/`Timaginary*`/`Tstruct`/...
    // base the same way.
    sourceType = sourceType.toBasetype;
    destType = destType.toBasetype;

    const sourceFacts = TypeFacts.of(sourceType);
    const destFacts = TypeFacts.of(destType);

    if (sourceType.ty == Tnull)
        return CastPlan(CastPlan.Kind.zero, sourceFacts, destFacts);

    if (sourceType.ty == Tclass && destType.ty == Tclass) {
        auto plan = CastPlan(
            CastPlan.Kind.classReference, sourceFacts, destFacts);
        destType.isTypeClass.sym.isBaseOf(
            sourceType.isTypeClass.sym, &plan.referenceOffset);
        return plan;
    }

    if (sourceType.ty == Taarray && destType.ty == Taarray)
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    // dmd's own `dcast.d` (bugzilla 3133) reinterprets the bytes of two
    // equal-size "fat values" - a `struct`, a static array, or a
    // vector - into one another once no `aliasthis`/implicit-constructor
    // rewrite claims the cast first (`S(x)`, tried before a `Tstruct`
    // destination ever reaches this classifier): `struct S{int x;}
    // S(int)`'s own constructor intercepts `cast(S) someInt`, but
    // `cast(ubyte[S.sizeof]) someS` has no such rewrite to claim it, so
    // it is a real reinterpret by the time it gets here. One rule for
    // every combination - including a vector, itself equal-size-only
    // already - rather than a case each for `struct`-`sarray`,
    // `sarray`-`sarray`, `struct`-`struct` and vector's own former
    // special case.
    if (isFatValue(sourceType) && isFatValue(destType)
            && sourceFacts.size == destFacts.size)
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    // DMD has checked the conversion. Function attributes do not change
    // a delegate's context and function words.
    if (sourceType.ty == Tdelegate && destType.ty == Tdelegate)
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    // `cast(void*) someDelegate` (deprecated, still accepted): the
    // reverse (`cast(SomeDelegate) somePointer`) and `cast(bool)`/an
    // integral destination are dmd frontend errors, so only this one
    // direction is reached.
    if (sourceType.ty == Tdelegate && destType.ty == Tpointer)
        return CastPlan(
            CastPlan.Kind.delegateToPointer, sourceFacts, destFacts);

    if ((sourceType.ty == Tclass && destType.ty == Tpointer)
            || (sourceType.ty == Tpointer && destType.ty == Tclass))
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    // An associative array is one pointer-sized handle natively, the same
    // shape `Tclass`-`Tpointer` already gets `copy` for above.
    // `cast(bool)`/an integral destination other than a pointer are dmd
    // frontend errors for an AA, so this is only ever `Tpointer` on the
    // other side.
    if ((sourceType.ty == Taarray && destType.ty == Tpointer)
            || (sourceType.ty == Tpointer && destType.ty == Taarray))
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    // `complex`/`imaginary` are deprecated but still full members of the
    // language dmd accepts, with their own cast rules: a `complex` value
    // is a `{re, im}` pair of the matching `float`/`double`/`real`
    // width; an `imaginary` value is one such component on its own, with
    // no real axis at all. Both are checked before `isFloatingType`
    // below, which answers `false` for either - a plain `float`,
    // `double` or `real` has neither a second component nor a missing
    // real one, so the two families never collide.
    if (isComplexType(destType)) {
        if (isComplexType(sourceType))
            return CastPlan(
                sourceFacts.size == destFacts.size
                    ? CastPlan.Kind.copy : CastPlan.Kind.complexWidth,
                sourceFacts, destFacts,
            );

        if (isImaginaryType(sourceType))
            return CastPlan(
                CastPlan.Kind.imaginaryToComplex, sourceFacts, destFacts);

        if (isFloatingType(sourceType))
            return CastPlan(
                CastPlan.Kind.realToComplex, sourceFacts, destFacts);

        if (sourceFacts.isIntegral && isIntegralSize(sourceFacts.size))
            return CastPlan(
                CastPlan.Kind.integralToComplex, sourceFacts, destFacts);

        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);
    }

    if (isImaginaryType(destType)) {
        if (isImaginaryType(sourceType))
            return CastPlan(
                sourceFacts.size == destFacts.size
                    ? CastPlan.Kind.copy : CastPlan.Kind.floatWidth,
                sourceFacts, destFacts,
            );

        if (isComplexType(sourceType))
            return CastPlan(
                CastPlan.Kind.complexToImaginary, sourceFacts, destFacts);

        // Neither a real value nor an integral (`bool`/`char` included)
        // has an imaginary component to carry over: dmd's own constant
        // folding (`toImaginary`, `expressionsem.d`) answers `0` for
        // either the same way it does for a real-typed `.im` - a
        // side-effect-preserving zero fill is that same answer at run
        // time.
        if (isFloatingType(sourceType)
                || (sourceFacts.isIntegral && isIntegralSize(sourceFacts.size)))
            return CastPlan(CastPlan.Kind.zero, sourceFacts, destFacts);

        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);
    }

    if (isFloatingType(destType)) {
        if (isFloatingType(sourceType))
            return CastPlan(
                sourceFacts.size == destFacts.size
                    ? CastPlan.Kind.copy : CastPlan.Kind.floatWidth,
                sourceFacts, destFacts,
            );

        if (isComplexType(sourceType))
            return CastPlan(
                CastPlan.Kind.complexToReal, sourceFacts, destFacts);

        // The reverse of the imaginary-destination zero fill above: a
        // real value has no imaginary axis to read back either.
        if (isImaginaryType(sourceType))
            return CastPlan(CastPlan.Kind.zero, sourceFacts, destFacts);

        if (sourceFacts.isIntegral && isIntegralSize(sourceFacts.size))
            return CastPlan(
                CastPlan.Kind.integralToFloat, sourceFacts, destFacts);

        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);
    }

    if (isComplexType(sourceType)) {
        if (destType.ty == Tbool)
            return CastPlan(
                CastPlan.Kind.complexToBool, sourceFacts, destFacts);

        if (destFacts.isIntegral && isIntegralSize(destFacts.size))
            return CastPlan(
                CastPlan.Kind.complexToIntegral, sourceFacts, destFacts);

        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);
    }

    if (isImaginaryType(sourceType)) {
        // The imaginary magnitude's own nonzero test - the same bytes,
        // at the same offset, `floatToBool` already reads for a real
        // operand.
        if (destType.ty == Tbool)
            return CastPlan(
                CastPlan.Kind.floatToBool, sourceFacts, destFacts);

        // No real projection to convert, same as the imaginary
        // destination case above.
        if (destFacts.isIntegral && isIntegralSize(destFacts.size))
            return CastPlan(CastPlan.Kind.zero, sourceFacts, destFacts);

        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);
    }

    if (isFloatingType(sourceType)) {
        if (destType.ty == Tbool)
            return CastPlan(
                CastPlan.Kind.floatToBool, sourceFacts, destFacts);

        if (destFacts.isIntegral && isIntegralSize(destFacts.size))
            return CastPlan(
                CastPlan.Kind.floatToIntegral, sourceFacts, destFacts);

        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);
    }

    if (sourceType.ty == Tpointer && destType.ty == Tpointer)
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    if (sourceType.ty == Tpointer && destFacts.isDynamicArray)
        return CastPlan(CastPlan.Kind.pointerToArray, sourceFacts, destFacts);

    // `cast(bool)` on a pointer (a plain pointer or a function pointer,
    // both `Tpointer`) tests the same nonzero bytes an integral `toBool`
    // cast does. A class reference or a delegate cast to `bool` is a dmd
    // frontend error (`Error: cannot cast expression ... to bool`), so
    // this is reached only for `Tpointer` - `bool`'s truth-conversion
    // semantics have to be checked before `pointerToIntegral` below,
    // which is why it stays out of that byte-preserving kind.
    if (sourceType.ty == Tpointer && destType.ty == Tbool)
        return CastPlan(CastPlan.Kind.toBool, sourceFacts, destFacts);

    // An explicit pointer-to-integral cast preserves the native address
    // bits; `bool` has truth-conversion semantics instead, so it stays
    // out of this byte-preserving kind.
    if (sourceType.ty == Tpointer && destFacts.isIntegral
            && destType.ty != Tbool)
        return CastPlan(
            CastPlan.Kind.pointerToIntegral, sourceFacts, destFacts);

    // The reverse of `pointerToIntegral`: an explicit integral-to-pointer
    // cast (`cast(void*) someInt`, `core.stdc.stdarg.alignUp`'s own
    // `return cast(T) b;`) preserves the operand's own bits, sign- or
    // zero-extended to the pointer's width exactly as widening that same
    // operand to a wider integral would - `bool`'s 0/1 values included,
    // since dmd classifies it as an unsigned integral. `size_t` is
    // already the pointer's own width, so that particular round trip is
    // the same plain move an equal-width integral cast already uses.
    // Sharing `copy`/`widenSigned`/`widenUnsigned` here, rather than a
    // kind of its own, is the same reuse `pointerToIntegral` above gets
    // for free from the ordinary integral-to-integral kinds below - a
    // pointer's destination facts differ from an integral's only in
    // `isIntegral` itself, never in the size or signedness arithmetic
    // that picks between them.
    if (destType.ty == Tpointer && sourceFacts.isIntegral
            && isIntegralSize(sourceFacts.size))
        return CastPlan(
            destFacts.size == sourceFacts.size
                ? CastPlan.Kind.copy
                : sourceFacts.isUnsigned
                    ? CastPlan.Kind.widenUnsigned : CastPlan.Kind.widenSigned,
            sourceFacts, destFacts,
        );

    if (sourceType.ty == Tsarray && destFacts.isDynamicArray
            && destType.nextOf !is null
            && sourceType.nextOf.mutableOf.equals(destType.nextOf.mutableOf)) {
        auto plan = CastPlan(
            CastPlan.Kind.sarrayToSlice, sourceFacts, destFacts);
        plan.staticLength =
            cast(size_t) sourceType.isTypeSArray.dim.toInteger;
        return plan;
    }

    // `xs.ptr`: dmd's own semantic pass for `Id.ptr` on a static array
    // casts straight to a pointer to its element type.
    if (sourceType.ty == Tsarray && destType.ty == Tpointer
            && destType.nextOf !is null
            && sourceType.nextOf.mutableOf.equals(destType.nextOf.mutableOf))
        return CastPlan(CastPlan.Kind.sarrayToPointer, sourceFacts, destFacts);

    // Explicit array-to-pointer casts preserve the data address even when
    // the pointed-to type differs from the array's element type.
    if (sourceFacts.isDynamicArray && destType.ty == Tpointer)
        return CastPlan(CastPlan.Kind.sliceToPointer, sourceFacts, destFacts);

    if (sourceFacts.isDynamicArray && destFacts.isDynamicArray)
        return CastPlan(
            sourceFacts.elementSize == destFacts.elementSize
                ? CastPlan.Kind.copy : CastPlan.Kind.reinterpretSlice,
            sourceFacts, destFacts,
        );

    if (!sourceFacts.isIntegral || !isIntegralSize(sourceFacts.size)
            || !destFacts.isIntegral)
        return CastPlan(CastPlan.Kind.unsupported, sourceFacts, destFacts);

    // dmd classifies `bool` as `integral | unsigned`, so this has to be
    // checked before the general integral resize below: `cast(bool) x`
    // means `x != 0`, not "keep the low byte".
    if (destType.ty == Tbool)
        return CastPlan(CastPlan.Kind.toBool, sourceFacts, destFacts);

    if (destFacts.size == sourceFacts.size)
        return CastPlan(CastPlan.Kind.copy, sourceFacts, destFacts);

    if (destFacts.size < sourceFacts.size)
        return CastPlan(CastPlan.Kind.narrow, sourceFacts, destFacts);

    return CastPlan(
        sourceFacts.isUnsigned
            ? CastPlan.Kind.widenUnsigned : CastPlan.Kind.widenSigned,
        sourceFacts, destFacts,
    );
}

// A null expression has no source representation to classify. Its cast
// fills the destination with zeros across its native width instead.
public CastPlan classify(
    imported!"dmd.expression".Expression expression,
    imported!"dmd.mtype".Type destType,
) {
    if (expression.isNullExp !is null)
        return CastPlan(
            CastPlan.Kind.zero, TypeFacts.init, TypeFacts.of(destType));

    return classify(expression.type, destType);
}

// Whether `type` is `float`/`double`/`real` - `TypeFacts` has no notion of
// its own for this, unlike `isIntegral`/`isDynamicArray`, which drive
// checks all over both backends.
private bool isFloatingType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tfloat32, Tfloat64, Tfloat80;

    return type.ty == Tfloat32 || type.ty == Tfloat64 || type.ty == Tfloat80;
}

// Whether `type` is `cfloat`/`cdouble`/`creal` - deprecated, still a full
// member of the language `classify` has to answer for.
private bool isComplexType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tcomplex32, Tcomplex64, Tcomplex80;

    return type.ty == Tcomplex32 || type.ty == Tcomplex64
        || type.ty == Tcomplex80;
}

// Whether `type` is `ifloat`/`idouble`/`ireal`.
private bool isImaginaryType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Timaginary32, Timaginary64, Timaginary80;

    return type.ty == Timaginary32 || type.ty == Timaginary64
        || type.ty == Timaginary80;
}

// Whether `type` is one of the three shapes `dcast.d` calls a "fat
// value" (bugzilla 3133): a `struct`, a static array, or a vector. Two
// of equal size reinterpret each other's bytes; `TypeFacts` has no
// notion of its own for the category, the same way it has none for
// `isFloatingType` above.
private bool isFatValue(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tsarray, Tstruct, Tvector;

    return type.ty == Tstruct || type.ty == Tsarray || type.ty == Tvector;
}
