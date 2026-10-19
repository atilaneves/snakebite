module snakebite.frontend.storage;

private:


import snakebite.internalfailure: internalFailure;


import dmd.expression:
    AssignExp, BinAssignExp, CatAssignExp, Expression, IndexExp, MemorySet,
    SymOffExp;
import dmd.astenums: Tarray, Tsarray, Tvector;
import dmd.typesem: isIntegral, toBasetype;

// DMD represents the target of a compound assignment at its promoted
// operation type. The original target type remains on the assignment node;
// use that pair to remove only this frontend-generated lvalue promotion.
public imported!"dmd.expression".Expression compoundTarget(
    imported!"dmd.expression".BinAssignExp expression,
) {
    const type = expression.type.toBasetype;
    if (sameScalar(expression.e1.type.toBasetype, type))
        return expression.e1;

    // A shift by a wider count promotes the target twice, e.g.
    // `cast(long)cast(int)b` for a `byte`.
    for (auto promotion = expression.e1.isCastExp; promotion !is null;
            promotion = promotion.e1.isCastExp)
        if (sameScalar(promotion.e1.type.toBasetype, type))
            return promotion.e1;
    return expression.e1;
}

// The assignment's own type is `const` when it initialises a `const`
// variable, while the target it promotes is not. The ordinary case is the
// first comparison alone.
private bool sameScalar(
    imported!"dmd.mtype".Type a, in imported!"dmd.mtype".Type b,
) {
    return a.equals(b) || (a.ty == b.ty && a.isTypeBasic !is null);
}

// An index without calls or side effects is only a read, and it is read
// after the array expression, calls included. Where that read is a local
// through a pointer, a `__gshared` global, `*p` or a field, dmd and LDC both
// do this. For a TLS global, which `isTrivialExp` also accepts, dmd reads the
// index first and LDC after; the order is unspecified, and this is LDC's.
// Any other index (a bounds-checked element, a call, `i++`) is evaluated
// before the array expression, also an unspecified order. An index that sees
// `$` keeps that place too. `isTrivialExp` allocates nothing, which matters
// because guest finalizers resolve indexes while the collector runs.
public bool readsIndexAfterBase(imported!"dmd.expression".IndexExp index) {
    import dmd.sideeffect: isTrivialExp;

    return index.lengthVar is null
        && isTrivialExp(index.e2)
        && !isTrivialExp(index.e1);
}

// The frontend proves the index range, including indexes made for foreach.
// DMD and LDC omit the runtime check for this fact; operand evaluation stays.
public bool needsIndexBoundsCheck(
    in imported!"dmd.expression".IndexExp index,
) @safe pure nothrow @nogc {
    return !index.indexIsInBounds;
}

// Resolves the storage named by an expression. `Result` is deliberately a
// backend type: the interpreter returns a native pointer, while the bytecode
// compiler returns a frame slot containing a native pointer. The resolver owns
// expression recursion and evaluation order; an adapter only performs the
// operation at the end of each semantic step.
public struct StorageResolver(Result, Adapter) {
    private Adapter _adapter;

    public this(Adapter adapter) {
        _adapter = adapter;
    }

    public Result resolve(Expression expression) {
        if (auto thisExp = expression.isThisExp)
            return _adapter.storageThis(thisExp);

        if (auto superExp = expression.isSuperExp)
            return _adapter.storageSuper(superExp);

        if (auto varExp = expression.isVarExp) {
            // An initializer symbol has no storage to name.
            if (varExp.var.isVarDeclaration is null)
                return _adapter.storageValue(varExp);
            return _adapter.storageVariable(varExp);
        }

        // `obj.Base` names the same object as `obj`.
        if (auto dotType = expression.isDotTypeExp)
            return resolve(dotType.e1);

        if (auto cast_ = expression.isCastExp) {
            if (isIntegral(cast_.e1.type) && isIntegral(expression.type))
                return resolve(cast_.e1);
            // dmd represents `v[i]` on a vector `v` by indexing a cast of
            // `v` to its element static array type; the cast shares `v`'s
            // storage, so index into `v` directly.
            if (cast_.e1.type.toBasetype.ty == Tvector
                    && expression.type.toBasetype.ty == Tsarray)
                return resolve(cast_.e1);
        }

        // `v.array[i]` indexes the same storage through the `.array`
        // property instead of a cast.
        if (auto vectorArray = expression.isVectorArrayExp)
            return resolve(vectorArray.e1);

        if (auto ptrExp = expression.isPtrExp)
            return _adapter.storagePointer(ptrExp);

        if (auto context = expression.isDelegatePtrExp) {
            import snakebite.nativelayout: delegateContextOffset;
            return _adapter.storageDelegateWord(
                resolve(context.e1), delegateContextOffset);
        }

        if (auto functionPointer = expression.isDelegateFuncptrExp) {
            import snakebite.nativelayout: delegateFunctionOffset;
            return _adapter.storageDelegateWord(
                resolve(functionPointer.e1), delegateFunctionOffset);
        }

        if (auto cond = expression.isCondExp) {
            return _adapter.storageConditional(
                cond,
                (Expression taken) => resolve(taken),
            );
        }

        if (auto comma = expression.isCommaExp) {
            _adapter.storageEffect(comma.e1);
            return resolve(comma.e2);
        }

        if (auto literal = expression.isStructLiteralExp)
            return _adapter.storageStructLiteral(literal);

        if (auto slice = expression.isSliceExp)
            return _adapter.storageSlice(slice);

        if (auto construct = expression.isConstructExp) {
            if (construct.memset == MemorySet.referenceInit)
                return assignmentResult(cast(AssignExp) construct,
                    construct.e1);
            if (construct.lowering !is null)
                return _adapter.storageLowered(construct);
        }

        if (auto lowered = expression.isLoweredAssignExp)
            return _adapter.storageLowered(lowered);

        if (auto assignment = expression.isBlitExp)
            return assignmentResult(
                cast(AssignExp) assignment, assignment.e1);

        if (auto construct = expression.isConstructExp)
            return assignmentResult(cast(AssignExp) construct, construct.e1);

        if (auto assignment = expression.isCatAssignExp)
            return assignmentResult(cast(BinAssignExp) assignment);

        if (auto assignment = expression.isBinAssignExp)
            return assignmentResult(cast(BinAssignExp) assignment);

        if (auto assignment = expression.isAssignExp)
            return assignmentResult(cast(AssignExp) assignment, assignment.e1);

        if (auto call = expression.isCallExp) {
            import snakebite.frontend.dmd.functions: typeFunctionOf;
            auto functionType = typeFunctionOf(call);
            if (functionType !is null && functionType.isRef)
                return _adapter.storageReferenceCall(call);

            return _adapter.storageValueCall(call);
        }

        if (auto length = expression.isArrayLengthExp) {
            if (length.e1.type.toBasetype.ty != Tarray)
                return _adapter.storageValue(length);
            auto base = resolve(length.e1);
            return _adapter.storageArrayLength(length, base);
        }

        if (auto index = expression.isIndexExp)
            return resolveIndex(index);

        if (auto field = expression.isDotVarExp)
            return _adapter.storageField(field);

        return _adapter.storageValue(expression);
    }

    private Result resolveIndex(IndexExp index) {
        import dmd.astenums: TY;
        import std.conv: text;

        // An enum has its base type's layout: `enum E : int[3]` indexes
        // like `int[3]`.
        auto indexBase = index.e1.type.toBasetype;
        final switch (indexBase.ty) with (TY) {
            // A trivial index is read after the base, as dmd and LDC both
            // do. For any other index the compilers disagree, so the order
            // is unspecified; the shared resolver evaluates that index
            // before the base.
            case Tsarray: {
                const baseFirst = readsIndexAfterBase(index);
                Result base;
                if (baseFirst)
                    base = resolve(index.e1);
                auto length = _adapter.storageStaticIndexLength(index);
                auto indexValue = _adapter.storageIndexValue(index, length);
                if (needsIndexBoundsCheck(index))
                    _adapter.storageIndexBounds(index, indexValue, length);
                if (!baseFirst)
                    base = resolve(index.e1);
                return _adapter.storageStaticIndex(
                    index, base, indexValue);
            }

            // A trivial index is read after the base, as dmd and LDC both
            // do. Any other index is evaluated before the base, an
            // unspecified order that is kept. `$` needs the descriptor
            // captured first, so that special form keeps the extra early
            // step.
            case Tarray: {
                const baseFirst = index.lengthVar !is null
                    || readsIndexAfterBase(index);
                Result base;
                size_t capturedLength;
                if (baseFirst) {
                    base = resolve(index.e1);
                    if (index.lengthVar !is null)
                        capturedLength = _adapter.storageDynamicIndexLength(
                            index, base);
                }
                auto indexValue = _adapter.storageIndexValue(
                    index, capturedLength);
                if (!baseFirst)
                    base = resolve(index.e1);
                auto length = _adapter.storageDynamicIndexLength(index, base);
                if (needsIndexBoundsCheck(index))
                    _adapter.storageIndexBounds(index, indexValue, length);
                return _adapter.storageDynamicIndex(
                    index, base, indexValue);
            }

            case Tpointer: {
                auto base = resolve(index.e1);
                auto pointer = _adapter.storagePointerIndexBase(index, base);
                auto indexValue = _adapter.storagePointerIndexValue(index);
                return _adapter.storagePointerIndex(
                    index, pointer, indexValue);
            }

            case Taarray, Treference, Tfunction, Tident, Tclass, Tstruct,
                Tenum, Tdelegate, Tnone, Tvoid, Tint8, Tuns8, Tint16,
                Tuns16, Tint32, Tuns32, Tint64, Tuns64, Tfloat32, Tfloat64,
                Tfloat80, Timaginary32, Timaginary64, Timaginary80,
                Tcomplex32, Tcomplex64, Tcomplex80, Tbool, Tchar, Twchar,
                Tdchar, Terror, Tinstance, Ttypeof, Ttuple, Tslice, Treturn,
                Tnull, Tvector, Tint128, Tuns128, Ttraits, Tmixin,
                Tnoreturn, Ttag:
                internalFailure(text("`", index.toString, "` indexes a `",
                    indexBase.toString, "`: dmd lowers associative array ",
                    "indexing to a call, indexes a vector through a cast to ",
                    "a static array and an aggregate through `opIndex`"));
        }
    }

    private Result assignmentResult(
        AssignExp expression, Expression targetExpression,
    ) {
        import snakebite.backends.sliceplan: planSlice;

        if (expression.memset == MemorySet.referenceInit)
            return _adapter.storageReferenceInit(expression);

        // Resolve the target first. This is the only evaluation of the
        // assignment's left side; the adapter receives its location and can
        // then evaluate and store the right side exactly once.
        auto target = resolve(targetExpression);
        // dmd marks `a[] = v` with `blockAssign` exactly when it cast `v`
        // to the element type. Every other slice assignment has an array
        // on the right side, whose elements are copied. A slice that dmd
        // typed as a static array (`cast(T[N]) a[lo .. hi] = v`) is the
        // place of those elements, so it is assigned like any lvalue.
        if (expression.e1.isSliceExp is null
                || planSlice(expression.e1.isSliceExp).yieldsStaticArray)
            _adapter.storagePlainAssignment(expression, target);
        else if (expression.memset == MemorySet.blockAssign)
            _adapter.storageSliceFill(expression, target);
        else
            _adapter.storageSliceCopy(expression, target);
        return target;
    }

    private Result assignmentResult(BinAssignExp expression) {
        // CatAssignExp is a BinAssignExp in dmd's AST. The typed overload
        // keeps that family dispatch complete without asking `isAssignExp`,
        // whose predicate only accepts the plain `EXP.assign` opcode.
        auto target = resolve(compoundTarget(expression));
        if (auto cat = expression.isCatAssignExp)
            _adapter.storageCatAssignment(cast(CatAssignExp) cat, target);
        else
            _adapter.storageCompoundAssignment(expression, target);
        return target;
    }
}

// Resolves the native address represented by a symbol-plus-offset
// expression. The symbol's address is backend-specific, but applying dmd's
// byte offset is the same operation for every backend.
public struct SymbolAddressResolver(Result, Adapter) {
    private Adapter _adapter;

    public this(Adapter adapter) {
        _adapter = adapter;
    }

    public Result resolve(SymOffExp expression) {
        auto address = _adapter.symbolAddress(expression);
        return _adapter.addSymbolOffset(address, expression.offset);
    }
}

// The runtime object that the address of a `TypeInfo` declaration is, or
// null when `expression` is not that. dmd leaves `&declaration` as an
// `AddrExp` in places such as `Object.classinfo`. The symbol of a
// declaration is a `TypeInfo` object, so the address is that object and not
// the address of a variable slot.
public TypeInfo typeInfoAddressedBy(Types)(
    imported!"dmd.expression".AddrExp expression, ref Types types,
) {
    auto variable = expression.e1.isVarExp;
    auto declaration =
        variable is null ? null : variable.var.isTypeInfoDeclaration;
    return declaration is null ? null : typeInfoObjectOf(declaration, types);
}

// The object that the symbol of `declaration` is. `typeid(I)` of an
// interface is a `TypeInfo_Interface`, but `I.classinfo` is the symbol of
// the `TypeInfo_Class` that this one holds.
public TypeInfo typeInfoObjectOf(Types)(
    imported!"dmd.declaration".TypeInfoDeclaration declaration,
    ref Types types,
) {
    import dmd.declaration: TypeInfoClassDeclaration;

    auto info = types.get(declaration.tinfo);
    if (cast(TypeInfoClassDeclaration) declaration is null)
        return info;

    auto classType = declaration.tinfo.isTypeClass;
    if (classType is null || classType.sym.isInterfaceDeclaration is null)
        return info;

    auto interfaceInfo = cast(TypeInfo_Interface) info;
    if (interfaceInfo is null)
        internalFailure("the runtime type of an interface is a `TypeInfo_Interface`");
    return interfaceInfo.info;
}
