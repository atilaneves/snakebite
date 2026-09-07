module snakebite.nativelayout;


private:


import snakebite.nativevalue:
    nativeArrayLengthOffset = arrayLengthOffset,
    nativeArrayPointerOffset = arrayPointerOffset,
    nativeArrayValueSize = arrayValueSize,
    nativeDelegateContextOffset = delegateContextOffset,
    nativeDelegateFunctionOffset = delegateFunctionOffset,
    nativeDelegateValueSize = delegateValueSize,
    nativeIsIntegralSize = isIntegralSize,
    nativeLoadIntegral = loadIntegral,
    nativeStoreIntegral = storeIntegral;

public alias arrayLengthOffset = nativeArrayLengthOffset;
public alias arrayPointerOffset = nativeArrayPointerOffset;
public alias arrayValueSize = nativeArrayValueSize;
public alias delegateContextOffset = nativeDelegateContextOffset;
public alias delegateFunctionOffset = nativeDelegateFunctionOffset;
public alias delegateValueSize = nativeDelegateValueSize;

public bool isIntegralSize(in size_t size) {
    return nativeIsIntegralSize(size);
}

// Whether a backend can treat a value of `type` as native bytes with no
// hook of its own to run. A `Tvector` is refused: no backend lays out a
// SIMD register or evaluates a vector expression. An integral of a width
// `storeIntegral` cannot store or load is refused: only `bool`/`byte`...
// `long`/`ulong`-sized integrals exist in ordinary D, so this only ever
// refuses `cent`/`ucent`. Otherwise the answer is dmd's own: a postblit,
// a copy constructor, a destructor, or a captured enclosing context (a
// nested struct's own hidden `this`) is a hook the backends do not run
// themselves, and dmd answers per type, recursing through a static array
// to its element and through an enum to its base type on its own, in
// `needsCopyOrPostblit`/`needsDestruction`/`needsNested`. A struct field
// whose type needs none of these is native bytes a bytewise copy already
// carries correctly, whatever its own kind - `float`/`double`/`real`, an
// enum, a static array, a delegate, a function pointer, a class or
// interface reference, an associative array, a pointer or a dynamic
// array. This says nothing about a `union` or a guest-written `opAssign`,
// neither of which any dmd function here is about; callers still refuse
// those at the aggregate's own declaration.
public bool isNativeBytes(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tvector;
    import dmd.typesem:
        isIntegral, needsCopyOrPostblit, needsDestruction, needsNested, size;

    if (type.ty == Tvector)
        return false;

    if (type.isIntegral && !isIntegralSize(type.size))
        return false;

    return !type.needsCopyOrPostblit
        && !type.needsDestruction
        && !type.needsNested;
}

// Keep the DMD-facing module's historical error behavior while the actual
// byte operations live in the DMD-free native-value module. Backend code
// that already validated its widths can call that module directly.
public void storeIntegral(void* place, in ulong value, in size_t size) {
    import std.conv: text;

    if (!isIntegralSize(size))
        throw new Exception(
            text("no native layout for an integral of ", size, " byte(s)"),
        );
    nativeStoreIntegral(place, value, size);
}

// Reads `size` bytes at `place`, laid out as compiled D lays them out, and
// widens them to 64 bits: sign-extended if `signed`, zero-extended
// otherwise. The result is a `long` either way - for an unsigned width the
// caller reinterprets it as `ulong`, the same 64 bits, since D has no
// integral type wider than either.
//
// The counterpart to `storeIntegral`: an interpreter comparing two
// integral operands needs the bytes-to-value direction as well as the one
// `storeIntegral` already covers.
public long loadIntegral(in void* place, in size_t size, in bool signed) {
    import std.conv: text;

    if (!isIntegralSize(size))
        throw new Exception(
            text("no native layout for an integral of ", size, " byte(s)"),
        );
    return nativeLoadIntegral(place, size, signed);
}

// What a caller on a hot execution path repeatedly asks a dmd `Type`
// for - its size, its alignment, whether it is integral, and if so
// whether it is signed - decided once and kept, instead of re-entering
// dmd's semantic-analysis machinery (`Type.size`, `TypeBasic.alignsize`,
// `isIntegral`, `isUnsigned`) on every visit of the same node. Shared
// between backends (not owned by the interpreter package) because any
// tree-walking or bytecode backend asks a dmd `Type` the same four
// questions to lay a value out in native memory.
public struct TypeFacts {
    import dmd.mtype: Type;

    public size_t size;
    public uint alignment;
    public bool isIntegral;
    public bool isUnsigned;
    // Whether `type` is a dynamic array (`T[]`) - the native `{length,
    // pointer}` pair, always `arrayValueSize` bytes regardless of `T`. A
    // caller that only moves a value between slots (`opCopy`/`opConstant`,
    // parameter passing, a return) needs nothing more than this and `size`
    // to do so correctly; only a caller that indexes into the array needs
    // `elementSize` as well.
    public bool isDynamicArray;
    // The element type's own size, meaningful only when `isDynamicArray` is
    // `true` - what indexing has to multiply an index by to find an
    // element's byte offset from the array's own pointer word.
    public size_t elementSize;

    // The facts for `type`, read from dmd exactly once by the caller
    // that builds this.
    public static TypeFacts of(Type type) {
        import dmd.astenums: Tarray;
        import dmd.typesem: alignsize, isIntegral, isUnsigned, nextOf, size;

        if (type.ty == Tarray)
            return TypeFacts(
                arrayValueSize, size_t.alignof, false, false, true,
                type.nextOf.size,
            );

        return TypeFacts(
            type.size,
            type.alignsize,
            type.isIntegral,
            type.isUnsigned,
        );
    }
}

// Rounds `offset` up to the next multiple of `alignment`, by way of dmd's
// default field-alignment rule (`aggregate.alignmember`, the same one it
// uses to lay out a struct's fields), rather than reimplementing it: no
// generic round-up-to-alignment helper exists anywhere else in the dmd
// frontend sources. Parameter frame offsets are ordinarily assigned far
// downstream of this, in dmd's machine-code backend, which this project
// does not use - laying out frames here is unavoidable, not a case of
// redoing work dmd already did for us at this stage.
public size_t alignUp(in size_t offset, in uint alignment) {
    import dmd.aggregate: alignmember;

    return alignmember(defaultAlignment, alignment, cast(uint) offset);
}

// `alignmember` takes a `structalign_t` for cases with an explicit
// `align(N)`; there is none here, so `defaultAlignment` is always the
// type's own natural alignment - and it is built once at module load,
// not on every call, since this runs on every parameter offset and every
// frame stack push.
private imported!"dmd.astenums".structalign_t defaultAlignment;

shared static this() {
    defaultAlignment.setDefault;
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

// These literals require neither execution nor a fresh runtime allocation.
public bool isStoredLiteral(imported!"dmd.expression".Expression value) {
    if (auto variable = value.isVarExp) {
        auto symbol = variable.var.isSymbolDeclaration;
        auto declaration = symbol is null
            ? null : symbol.dsym.isStructDeclaration;
        return declaration !is null && !declaration.isNested();
    }
    if (auto literal = value.isStructLiteralExp) {
        if (literal.sd.isNested())
            return false;
        foreach (element; *literal.elements)
            if (element !is null && !isStoredLiteral(element))
                return false;
        return true;
    }
    if (auto literal = value.isArrayLiteralExp) {
        if (literal.type.isTypeSArray is null)
            return false;
        foreach (i; 0 .. literal.elements.length)
            if (!isStoredLiteral(literal[i]))
                return false;
        return true;
    }
    return value.isIntegerExp !is null || value.isRealExp !is null
        || value.isStringExp !is null || value.isNullExp !is null;
}

// Owns constant storage and its referenced data for the backend's lifetime.
public struct NativeData {
    import dmd.aggregate: AggregateDeclaration;
    import dmd.declaration: Declaration, VarDeclaration;
    import dmd.expression: Expression;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    private SymbolAddress _symbolAddress;
    private void[][] _blocks;
    private void[] _available;
    private void[][VarDeclaration] _statics;
    private const(void)[][Type] _defaults;

    public this(SymbolAddress symbolAddress) {
        _symbolAddress = symbolAddress;
    }

    public void write(
        Type type,
        in TypeFacts facts,
        Expression expression,
        void* place,
    ) {
        storeValue(type, facts, expression, place, &addressOf);
    }

    public const(void)[] initialValue(
        Type type,
        in Loc loc,
    ) {
        if (auto found = type in _defaults)
            return *found;

        const bytes = value(type, initialExpression(type, loc));
        _defaults[type] = bytes;
        return bytes;
    }

    public const(void)[] value(
        Type type,
        Expression expression,
    ) {
        const facts = TypeFacts.of(type);
        auto bytes = reserve(facts);
        write(type, facts, expression, bytes.ptr);
        return bytes;
    }

    private void[] reserve(in TypeFacts facts) {
        // Slots cannot move: constants can hold addresses of other slots.
        const needed = facts.size + facts.alignment - 1;
        if (_available.length < needed) {
            import std.algorithm: max;

            _available = new void[max(4096, needed)];
            _blocks ~= _available;
        }
        const start = -cast(size_t) _available.ptr & (facts.alignment - 1);
        auto bytes = _available[start .. start + facts.size];
        _available = _available[start + facts.size .. $];
        return bytes;
    }

    public void[] storageOf(VarDeclaration variable) {
        import core.stdc.string: memcpy;
        import dmd.astenums: STC;
        import dmd.expressionsem: getConstInitializer;

        if (auto found = variable in _statics)
            return *found;

        const facts = TypeFacts.of(variable.type);
        if (variable.storage_class & STC.extern_) {
            // const would also make the referenced storage read-only here.
            auto address = _symbolAddress(variable);
            assert(address !is null);
            return address[0 .. facts.size];
        }
        auto bytes = reserve(facts);
        // A static initializer can refer to its own storage.
        _statics[variable] = bytes;
        scope (failure) _statics.remove(variable);
        if (variable._init is null) {
            const initial = initialValue(variable.type, variable.loc);
            memcpy(bytes.ptr, initial.ptr, bytes.length);
        } else if (variable._init.isVoidInitializer is null) {
            auto initializer = variable._init.isExpInitializer;
            auto expression = initializer is null
                ? variable.getConstInitializer
                : initializerValueOf(initializer);
            write(variable.type, facts, expression, bytes.ptr);
        }
        return bytes;
    }

    private void* addressOf(Declaration symbol) {
        if (auto variable = symbol.isVarDeclaration)
            return storageOf(variable).ptr;
        return _symbolAddress(symbol);
    }

    public void fillFields(
        AggregateDeclaration declaration,
        ubyte* place,
    ) {
        import dmd.expressionsem: getConstInitializer;

        foreach (field; declaration.fields) {
            if (field._init !is null && field._init.isVoidInitializer)
                continue;

            const bytes = field._init is null
                ? initialValue(field.type, field.loc)
                : value(field.type, field.getConstInitializer(false));
            import core.stdc.string: memcpy;

            memcpy(place + field.offset, bytes.ptr, bytes.length);
        }
    }
}

private alias SymbolAddress =
    void* delegate(imported!"dmd.declaration".Declaration);

public string nativeSymbolName(imported!"dmd.declaration".Declaration symbol) {
    import dmd.common.outbuffer: OutBuffer;
    import dmd.mangle: mangleToBuffer;

    OutBuffer name;
    mangleToBuffer(symbol, name);
    return name[].idup;
}

private imported!"dmd.expression".Expression initialExpression(
    imported!"dmd.mtype".Type type,
    in imported!"dmd.location".Loc loc,
) {
    import dmd.typesem: defaultInitLiteral;

    return type.defaultInitLiteral(loc);
}

public void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, TypeFacts.of(type), value, place, null);
}

private void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
    scope SymbolAddress symbolAddress,
) {
    storeValue(type, TypeFacts.of(type), value, place, symbolAddress);
}

public void storeValue(
    imported!"dmd.mtype".Type type,
    in TypeFacts facts,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, facts, value, place, null);
}

private void storeValue(
    imported!"dmd.mtype".Type type,
    in TypeFacts facts,
    imported!"dmd.expression".Expression value,
    void* place,
    scope SymbolAddress symbolAddress,
) {
    import core.stdc.string: memcpy, memset;
    import dmd.astenums: Tarray, Tfloat32, Tfloat64, Tfloat80, Tsarray;
    import dmd.expressionsem: toInteger, toReal;
    import dmd.typesem: mutableOf, nextOf, size, toBasetype;
    import std.conv: text;

    if (value.isNullExp) {
        memset(place, 0, facts.size);
        return;
    }

    if (facts.isIntegral) {
        storeIntegral(place, value.toInteger, facts.size);
        return;
    }

    type = type.toBasetype;
    auto bytes = cast(ubyte*) place;

    if (auto variable = value.isVarExp) {
        if (auto symbol = variable.var.isSymbolDeclaration) {
            storeValue(type, facts, initialExpression(symbol.dsym.type,
                value.loc), place, symbolAddress);
            return;
        }
    }

    if (auto vector = value.isVectorExp) {
        storeValue(type.isTypeVector.basetype, vector.e1, place, symbolAddress);
        return;
    }

    if (auto array = type.isTypeSArray) {
        auto sourceElement = value.type.toBasetype.nextOf;
        const wholeArray = sourceElement !is null
            && sourceElement.mutableOf.equals(array.next.mutableOf);
        if (!wholeArray || value.isStringExp is null) {
            const elementSize = array.next.size;
            auto literal = wholeArray ? value.isArrayLiteralExp : null;
            foreach (i; 0 .. cast(size_t) array.dim.toInteger)
                storeValue(array.next, literal is null ? value : literal[i],
                    bytes + i * elementSize, symbolAddress);
            return;
        }
    }

    if (auto symbol = value.isSymOffExp) {
        assert(symbolAddress !is null);
        *cast(void**) place =
            cast(ubyte*) symbolAddress(symbol.var) + symbol.offset;
        return;
    }

    if (auto literal = value.isFuncExp) {
        assert(symbolAddress !is null);
        *cast(void**) place = symbolAddress(literal.fd);
        return;
    }

    if (auto literal = value.isStringExp) {
        const elementSize = type.nextOf.size;
        assert(literal.sz == elementSize);
        if (type.ty == Tsarray) {
            assert(literal.len * elementSize == facts.size);
            memcpy(place, literal.peekData.ptr, facts.size);
        } else {
            assert(type.ty == Tarray);
            storeIntegral(bytes + arrayLengthOffset, literal.len, size_t.sizeof);
            *cast(const(void)**) (bytes + arrayPointerOffset) =
                literal.peekData.ptr;
        }
        return;
    }

    if (auto literal = value.isArrayLiteralExp) {
        assert(type.ty == Tarray);
        const elementSize = type.nextOf.size;
        auto data = new void[literal.elements.length * elementSize];
        foreach (i; 0 .. literal.elements.length)
            storeValue(type.nextOf, literal[i],
                cast(ubyte*) data.ptr + i * elementSize, symbolAddress);
        storeIntegral(bytes + arrayLengthOffset, literal.elements.length,
            size_t.sizeof);
        *cast(void**) (bytes + arrayPointerOffset) = data.ptr;
        return;
    }

    if (type.isTypeStruct !is null && value.isIntegerExp) {
        // DMD encodes a zero-initialized struct as an IntegerExp. Resolve
        // that encoding here, not from the destination's byte count.
        assert(value.toInteger == 0);
        storeValue(type, facts, initialExpression(type, value.loc), place,
            symbolAddress);
        return;
    }

    if (auto literal = value.isStructLiteralExp) {
        memset(place, 0, facts.size);
        foreach (i, element; *literal.elements) {
            if (element is null)
                continue;
            auto field = literal.sd.fields[i];
            if (auto bitfield = field.isBitFieldDeclaration) {
                const fieldBytes = field.type.size;
                auto bits = loadIntegral(bytes + field.offset, fieldBytes, false);
                const mask = ulong.max >> (64 - bitfield.fieldWidth);
                const shift = bitfield.bitOffset;
                bits = (bits & ~(mask << shift))
                    | ((element.toInteger & mask) << shift);
                storeIntegral(bytes + field.offset, bits, fieldBytes);
            } else
                storeValue(field.type, element, bytes + field.offset,
                    symbolAddress);
        }
        return;
    }

    if (type.ty == Tfloat32) {
        *cast(float*) place = cast(float) value.toReal;
        return;
    }

    if (type.ty == Tfloat64) {
        *cast(double*) place = cast(double) value.toReal;
        return;
    }

    if (type.ty == Tfloat80) {
        *cast(real*) place = value.toReal;
        return;
    }

    throw new Exception(
        text("no native layout for a value of type `", type.toString, "`"),
    );
}
