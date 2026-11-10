module snakebite.frontend.typefacts;


private:


import snakebite.failure.report: internalFailure;


import snakebite.native.value:
    arrayLengthOffset, arrayPointerOffset, arrayValueSize, BitfieldAccess,
    delegateContextOffset, delegateFunctionOffset, TypeFacts;


// The facts for `type`, read from dmd exactly once by the caller
// that builds this. `resolved`/`forceResolved` force any forward
// reference `size`/`alignsize`/`toBasetype` below could still
// resolve, under the frontend lock, before this asks dmd anything -
// see their own doc for why a call that finds nothing to force
// needs no lock.
public TypeFacts typeFacts(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tarray, Tvector;
    import dmd.typesem:
        alignsize, isIntegral, isUnsigned, nextOf;
    import snakebite.frontend.compiler: forceIfNeeded;

    forceIfNeeded(() => resolved(type), () { forceResolved(type); });

    // An enum value has the representation of its base type. Keeping
    // that representation here lets every byte-storage caller use the
    // same facts for enum values with floating or string bases.
    type = representationType(type);

    if (type.ty == Tarray) {
        forceIfNeeded(
            () => resolved(type.nextOf),
            () { forceResolved(type.nextOf); },
        );
        return TypeFacts(
            arrayValueSize, size_t.alignof, false, false, true,
            representationSize(type.nextOf),
        );
    }

    // A vector is not an integral value, whatever its element type:
    // `isIntegral` answers for the element, and a vector is wider than
    // any integral.
    const scalar = type.ty != Tvector;
    return TypeFacts(
        representationSize(type),
        type.alignsize,
        scalar && type.isIntegral,
        scalar && type.isUnsigned,
    );
}

private imported!"dmd.mtype".Type representationType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.typesem: toBasetype;
    import snakebite.frontend.compiler: newInFrontend;

    // DMD can cache a new qualified base even when the enum is resolved.
    if (type.isTypeEnum !is null)
        return newInFrontend!toBasetype(type);
    return type;
}

private auto representationSize(imported!"dmd.mtype".Type type) {
    import dmd.typesem: size;
    import snakebite.frontend.compiler: newInFrontend;

    // Static-array size normalizes each nested element. An enum can
    // still allocate a qualified base after its declaration is resolved.
    auto element = type;
    while (auto arrayType = element.isTypeSArray)
        element = arrayType.next;
    if (element.isTypeEnum !is null)
        return newInFrontend!size(type);
    return type.size;
}

// `typeFacts`, for a caller that only prepares what execution may ask for
// later: a type with no size (an aggregate that is declared and never
// defined, an array too large to size) leaves `facts` alone and gives
// `false`, where `typeFacts` would give a size that no memory has. The
// execution that asks for such a type still asks `typeFacts`. Run it with
// dmd's diagnostics gagged.
public bool tryTypeFacts(imported!"dmd.mtype".Type type, out TypeFacts facts) {
    if (!hasSize(type))
        return false;

    facts = typeFacts(type);
    return facts.size != size_t.max;
}

private bool hasSize(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Sizeok, Tarray, Terror;
    import dmd.enumsem: getMemtype;
    import dmd.location: Loc;
    import dmd.typesem: nextOf;
    import snakebite.frontend.compiler: newInFrontend;

    if (type.ty == Terror)
        return false;

    if (auto enumType = type.isTypeEnum) {
        auto memtype = newInFrontend!getMemtype(enumType.sym, Loc.initial);
        return memtype !is null && hasSize(memtype);
    }

    if (auto structType = type.isTypeStruct)
        return structType.sym.members !is null
            || structType.sym.sizeok == Sizeok.done;

    if (auto arrayType = type.isTypeSArray)
        return hasSize(arrayType.next);

    if (type.ty == Tarray)
        return hasSize(type.nextOf);

    return true;
}

// Whether every forward reference `toBasetype`/`size`/`alignsize`
// could still resolve for `type` is already resolved - an enum's own
// base type (`EnumDeclaration.getMemtype`, reached through
// `toBasetype`), or a struct's own size
// (`AggregateDeclaration.determineSize`, reached through `size`/
// `alignsize` directly, or through `Type.baseElemOf`'s
// `toBasetype`-then-descend walk for a static array). A pointer, a
// class handle, a dynamic array's own two words, and every basic
// type answer `size`/`alignsize` from a fixed table with no dsymbol
// to force at all (`dmd.typesem.size`'s own switch), so this
// defaults to `true` for any `Type` kind not named below.
//
// Every field read here is `atomicLoad!(MemoryOrder.acq)`, not a
// plain read - `forceIfNeeded`'s own doc (`snakebite.frontend.
// compiler`) explains why an unlocked reader needs that much, and
// why the field itself must be the one dmd sets only once the data
// it guards is completely settled, not merely a field dmd's own
// single-threaded code happens to gate re-entrancy on.
private bool resolved(imported!"dmd.mtype".Type type) {
    import core.atomic: atomicLoad, MemoryOrder;
    import dmd.astenums: Sizeok;
    import dmd.dsymbol: PASS;

    // `EnumDeclaration.enumSemantic` (dmd/enumsem.d) clears `_scope`
    // (dmd's own re-entrancy gate, and the field `getMemtype` itself
    // reads) as soon as it starts, long before `memtype` is
    // reassigned to its resolved form a few lines later - `_scope
    // is null` can be true while a racing reader still sees the
    // pre-semantic, unresolved `memtype` the parser first assigned
    // (e.g. a `TypeIdentifier` for `enum E : SomeAlias`), not a real
    // answer to `size`/`alignsize`. `semanticRun` only reaches
    // `semanticdone` after that reassignment, on every path through
    // `enumSemantic` that starts with `memtype` non-null - gate on
    // that field instead. `enum { A, B, C }` (no explicit base)
    // leaves `memtype` null past `semanticdone` too (dmd fills it in
    // later still, from the first member's own value) - `memtype
    // !is null` below stays false for that case until dmd truly
    // sets it, keeping every caller on the locked path meanwhile, so
    // it is kept alongside the corrected `semanticRun` check rather
    // than dropped.
    if (auto enumType = type.isTypeEnum)
        return atomicLoad!(MemoryOrder.acq)(enumType.sym.semanticRun)
                >= PASS.semanticdone
            && atomicLoad!(MemoryOrder.acq)(enumType.sym.memtype)
                !is null
            && resolved(enumType.sym.memtype);

    // `finalizeSize` (dsymbolsem.d) sets `sizeok = Sizeok.done` as
    // its very last write, strictly after `structsize`/`alignsize`
    // are both final - unlike `EnumDeclaration._scope` above, this
    // field really is the last word.
    if (auto structType = type.isTypeStruct)
        return atomicLoad!(MemoryOrder.acq)(structType.sym.sizeok)
            == Sizeok.done;

    if (auto arrayType = type.isTypeSArray)
        return resolved(arrayType.next);

    return true;
}

// The forcing half of `resolved`: runs, under the frontend lock
// (`forceIfNeeded`'s own doc explains why only there), exactly the
// dmd call whose own idempotent gate `resolved` mirrors. Each dmd
// function re-checks that same gate itself, so calling it again for
// a branch another thread resolved first, between `resolved`'s read
// and this thread taking the lock, is itself a no-op - never a
// second write.
private void forceResolved(imported!"dmd.mtype".Type type) {
    import dmd.location: Loc;
    import snakebite.frontend.compiler: newInFrontend;

    if (auto enumType = type.isTypeEnum) {
        import dmd.enumsem: getMemtype;

        forceResolved(newInFrontend!getMemtype(enumType.sym, Loc.initial));
        return;
    }

    if (auto structType = type.isTypeStruct) {
        import dmd.dsymbolsem: size;

        newInFrontend!size(structType.sym, Loc.initial);
        return;
    }

    if (auto arrayType = type.isTypeSArray)
        forceResolved(arrayType.next);
}

// Which native bytes of a value of `type` decide whether it is true
// as a condition (`if`, `assert`, `!`, `&&`, `||`, `?:`) - dmd's own
// `toBoolean` (`dmd.expressionsem`) leaves such a condition's type
// unchanged for every case here, so the real test is the one native
// codegen makes of the value's bytes, not any `bool` conversion:
//
// * A floating value is true when nonzero, compared as a float, at
//   `size` bytes from the value's own start.
// * A dynamic array is true when either of its two words (`ptr`,
//   `length`) is nonzero: a zero-length slice over real storage is
//   true, and so is a null pointer with a nonzero length (dmd
//   compiles both so; `ldc2` tests the pointer alone).
// * A delegate is true when either of its two words (`ptr`,
//   `funcptr`) is nonzero.
// * A pointer, a class reference, an associative array's one
//   pointer-sized handle, and every integral (`bool`, `char`, an
//   enum with an integral base, ...) are already exactly one native
//   word: `offset` alone, `size` bytes, decides it.
//
// One rule shared by every backend that compiles or interprets a
// condition, so neither special-cases an associative array or a
// delegate on its own.
public TypeFacts.Truth truthFacts(imported!"dmd.mtype".Type type) {
    alias Truth = TypeFacts.Truth;
    import dmd.astenums: TY;
    import dmd.typesem: size;
    import std.conv: text;

    type = representationType(type);
    final switch (type.ty) with (TY) {
        // An imaginary value is one `float`/`double`/`real`-shaped
        // component on its own - the same nonzero test a real one
        // gets, just at its own (imaginary) type's size.
        case Tfloat32, Tfloat64, Tfloat80,
            Timaginary32, Timaginary64, Timaginary80:
            return Truth(true, 0, type.size);

        // A complex value is true when either of its two
        // `float`/`double`/`real`-shaped components (`re`, `im`,
        // each exactly half `type.size` - `nativevalue.
        // loadComplexRe`/`loadComplexIm`'s own layout) is nonzero.
        case Tcomplex32, Tcomplex64, Tcomplex80: {
            const half = type.size / 2;
            return Truth(true, 0, half, half);
        }

        case Tarray:
            return Truth(
                false, arrayPointerOffset, size_t.sizeof,
                arrayLengthOffset,
            );

        case Tdelegate:
            return Truth(
                false, delegateContextOffset, size_t.sizeof,
                delegateFunctionOffset,
            );

        // `typeof(null)` has only ever the one value - always zero
        // bits, so `if (x)` on it is always false - but that is
        // still the same one-word nonzero test a pointer's own
        // `Truth` already is.
        case Tpointer, Tclass, Taarray, Tnull,
            Tbool, Tchar, Twchar, Tdchar, Tint8, Tuns8, Tint16,
            Tuns16, Tint32, Tuns32, Tint64, Tuns64:
            return Truth(false, 0, type.size);

        // Evaluating the condition never finishes, so no byte of
        // it is ever tested.
        case Tnoreturn:
            return Truth(false, 0, 0);

        case Tstruct, Tsarray, Tvector, Tint128, Tuns128, Tenum,
            Tvoid, Tfunction, Treference, Tident, Tnone, Terror,
            Tinstance, Ttypeof, Ttuple, Tslice, Treturn, Ttraits,
            Tmixin, Ttag:
            internalFailure(text("`", type.toString, "` cannot be a ",
                "condition: semantic rejects it, and `toBasetype` ",
                "leaves no enum"));
    }
}

// Inspecting an initializer's value must not itself run construction.
public imported!"dmd.expression".Expression initializerValueOf(
    imported!"dmd.init".ExpInitializer initializer,
) {
    auto value = initializer.exp;
    if (auto construct = value.isConstructExp)
        return construct.e2;
    if (auto blit = value.isBlitExp)
        return blit.e2;
    return value;
}

// Whether `variable` has one copy for each thread. dmd's glue layer gives a
// compiler-made `static` (`STC.temp`, such as the gate of a template
// instance's module destructor) one copy for the whole process, though
// `isThreadlocal` is true for it: `glue/tocsym.d` makes that exception.
public bool isThreadLocalStorage(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: STC;

    return variable.isThreadlocal && !(variable.storage_class & STC.temp);
}

// Whether a declaration's initializer runs as an effect on `variable`'s
// storage, with no value of its own to store. Two shapes:
//
// - `T[n] v = source;` (a static array constructed from a slice or a
//   scalar, never an array literal) is rewritten by dmd to `v[] = source`,
//   a `ConstructExp`/`BlitExp` whose `e1` is a `SliceExp` of `v`, not `v`
//   itself. Its own value is the slice `e1` evaluates to, which is not
//   `v`'s elements.
// - `T[n] v = source;` where `T` has a postblit, a copy constructor or a
//   destructor carries a lowering to `_d_arrayctor(cast(T[]) v, ...)` or
//   `_d_arraysetctor`. The call constructs the elements in `v` and
//   returns a slice or nothing, not `v`'s value.
//
// Either way the initializer must run through the normal expression path,
// not have `initializerValueOf`'s `e2` evaluated into `v`'s slot.
public bool initializerRunsForEffect(
    imported!"dmd.init".ExpInitializer initializer,
    imported!"dmd.declaration".VarDeclaration variable,
) {
    auto value = initializer.exp;
    auto e1 = value.isConstructExp ? value.isConstructExp.e1
        : value.isBlitExp ? value.isBlitExp.e1 : null;
    if (e1 is null)
        return false;

    if (value.isConstructExp !is null && value.isConstructExp.lowering !is null)
        return true;

    auto target = e1.isVarExp;
    return target is null || target.var !is variable;
}

// These literals require neither execution nor a fresh runtime allocation.
// A literal with `useStaticInit` is a copy of the type's `.init` image
// (`glue/e2ir.d`, `toSymbol`'s `toInitializer`), whatever it holds: every
// context pointer in that image is null, also the one of a nested struct
// that is a field of another struct, so there is no frame to read.
public bool isStoredLiteral(imported!"dmd.expression".Expression value) {
    if (auto variable = value.isVarExp) {
        auto symbol = variable.var.isSymbolDeclaration;
        auto declaration = symbol is null
            ? null : symbol.dsym.isStructDeclaration;
        return declaration !is null && !declaration.isNested();
    }
    if (auto literal = value.isStructLiteralExp) {
        if (literal.useStaticInit)
            return true;
        if (literal.sd.isNested())
            return false;
        foreach (element; *literal.elements)
            if (element !is null && !isStoredLiteral(element))
                return false;
        return true;
    }
    if (auto literal = value.isArrayLiteralExp) {
        import dmd.typesem: toBasetype;

        if (literal.type.toBasetype.isTypeSArray is null)
            return false;
        foreach (i; 0 .. literal.elements.length)
            if (!isStoredLiteral(literal[i]))
                return false;
        return true;
    }
    return value.isIntegerExp !is null || value.isRealExp !is null
        || value.isStringExp !is null || value.isNullExp !is null;
}

// A `&literal` is the address of one static struct value, as in dmd's
// `e2ir.d` `visitAddr`, whether the frontend folded `new S(...)` or the
// program wrote it. The keys are the literals themselves: for every
// `StructLiteralExp` met here the literal is its own `origin`.
public bool isStaticStructAddress(imported!"dmd.expression".AddrExp value) {
    return value.e1.isStructLiteralExp !is null;
}

// The storage unit of a bit field, which both runtime backends read and
// write as the compiled D of dmd does: a unit as wide as the field's
// declared type. The bits of a field start at bit `offset * 8 + bitOffset`
// of the struct. dmd numbers `bitOffset` from `offset` across unit
// boundaries, so a `ubyte` field after a `ushort` one can have a
// `bitOffset` of 9: whole units of the declared type move into `offset`
// and what is left is the shift inside the unit.
//
// A field that follows narrower fields can be as wide as its type and start
// on a unit boundary of the struct, not of `offset` (`ubyte a : 8;
// ushort b : 16; uint c : 32;` puts `c` at offset 2 and bit offset 16).
// dmd's own glue stops there. Its layout puts the field in the unit of its
// type that is aligned from the start of the struct, so that is the unit.
// The layout starts a new field, at its own `offset`, for each bit field
// that would cross such a unit, so one of the two units always holds the
// field.
public BitfieldAccess bitfieldAccess(imported!"dmd.declaration".VarDeclaration field) {
    auto bitfield = field.isBitFieldDeclaration;
    if (bitfield is null)
        internalFailure("a bit field access needs a bit field declaration");

    const facts = typeFacts(field.type);
    const unitBits = facts.size * 8;
    const units = bitfield.bitOffset / unitBits;
    const shift = bitfield.bitOffset - units * unitBits;
    if (shift + bitfield.fieldWidth <= unitBits)
        return BitfieldAccess(
            field.offset + units * facts.size, cast(uint) facts.size,
            cast(uint) shift, bitfield.fieldWidth, !facts.isUnsigned);

    const first = field.offset * 8 + bitfield.bitOffset;
    const alignedUnit = first / unitBits * facts.size;
    const alignedShift = first - alignedUnit * 8;
    if (alignedShift + bitfield.fieldWidth > unitBits)
        internalFailure("a bit field does not fit a unit of its type");
    return BitfieldAccess(
        alignedUnit, cast(uint) facts.size, cast(uint) alignedShift,
        bitfield.fieldWidth, !facts.isUnsigned);
}

// Where a field starts in its struct: a bit field starts at its storage
// unit.
public size_t fieldOffset(imported!"dmd.declaration".VarDeclaration field) {
    return field.isBitFieldDeclaration is null
        ? field.offset : bitfieldAccess(field).offset;
}
