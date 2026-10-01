module snakebite.frontend.storage;

private:


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

        if (auto varExp = expression.isVarExp)
            return _adapter.storageVariable(varExp);

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
            // Static-array code generation evaluates the rightmost index
            // before recursing into the outer array expression. Keep that
            // language-defined order in the shared resolver; all other
            // index kinds evaluate the base before the index.
            case Tsarray: {
                auto length = _adapter.storageStaticIndexLength(index);
                auto indexValue = _adapter.storageIndexValue(index, length);
                _adapter.storageIndexBounds(index, indexValue, length);
                auto base = resolve(index.e1);
                return _adapter.storageStaticIndex(
                    index, base, indexValue);
            }

            // A normal dynamic-array index evaluates its index before the
            // array expression. `$` needs the descriptor captured first,
            // so that special form keeps the extra early step.
            case Tarray: {
                Result base;
                size_t capturedLength;
                if (index.lengthVar !is null) {
                    base = resolve(index.e1);
                    capturedLength = _adapter.storageDynamicIndexLength(
                        index, base);
                }
                auto indexValue = _adapter.storageIndexValue(
                    index, capturedLength);
                if (index.lengthVar is null)
                    base = resolve(index.e1);
                auto length = _adapter.storageDynamicIndexLength(index, base);
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
                assert(0, text("`", index.toString, "` indexes a `",
                    indexBase.toString, "`: dmd lowers associative array ",
                    "indexing to a call, indexes a vector through a cast to ",
                    "a static array and an aggregate through `opIndex`"));
        }
    }

    private Result assignmentResult(
        AssignExp expression, Expression targetExpression,
    ) {
        if (expression.memset == MemorySet.referenceInit)
            return _adapter.storageReferenceInit(expression);

        // Resolve the target first. This is the only evaluation of the
        // assignment's left side; the adapter receives its location and can
        // then evaluate and store the right side exactly once.
        auto target = resolve(targetExpression);
        // dmd marks `a[] = v` with `blockAssign` exactly when it cast `v`
        // to the element type. Every other slice assignment has an array
        // on the right side, whose elements are copied.
        if (expression.e1.isSliceExp is null)
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
