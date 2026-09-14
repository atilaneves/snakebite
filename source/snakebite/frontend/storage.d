module snakebite.frontend.storage;

private:


import dmd.expression:
    AssignExp, BinAssignExp, CatAssignExp, Expression, IndexExp;
import dmd.astenums: Tarray, Tpointer, Tsarray;
import dmd.typesem: isIntegral;

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
        }

        if (auto ptrExp = expression.isPtrExp)
            return _adapter.storagePointer(ptrExp);

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
            return assignmentResult(
                cast(BinAssignExp) assignment, assignment.e1);

        if (auto assignment = expression.isBinAssignExp)
            return assignmentResult(
                cast(BinAssignExp) assignment, assignment.e1);

        if (auto assignment = expression.isAssignExp)
            return assignmentResult(cast(AssignExp) assignment, assignment.e1);

        if (auto call = expression.isCallExp) {
            auto callee = call.f;
            if (callee is null) {
                auto calleeExp = call.e1.isVarExp;
                callee = calleeExp is null
                    ? null : calleeExp.var.isFuncDeclaration;
            }

            if (callee !is null && callee.isCtorDeclaration !is null)
                return _adapter.storageConstructorCall(call);

            auto functionType = callee !is null
                ? callee.type.isTypeFunction
                : call.e1.type.isTypeFunction;
            if (functionType !is null && functionType.isRef)
                return _adapter.storageReferenceCall(call);

            return _adapter.storageValueCall(call);
        }

        if (auto length = expression.isArrayLengthExp) {
            if (length.e1.type.ty != Tarray)
                return _adapter.storageValue(length);
            auto base = resolve(length.e1);
            return _adapter.storageArrayLength(length, base);
        }

        if (auto index = expression.isIndexExp) {
            // Static-array code generation evaluates the rightmost index
            // before recursing into the outer array expression. Keep that
            // language-defined order in the shared resolver; all other
            // index kinds evaluate the base before the index.
            if (index.e1.type.ty == Tsarray) {
                auto length = _adapter.storageStaticIndexLength(index);
                auto indexValue = _adapter.storageIndexValue(index, length);
                _adapter.storageIndexBounds(index, indexValue, length);
                auto base = resolve(index.e1);
                return _adapter.storageStaticIndex(
                    index, base, indexValue);
            }

            if (index.e1.type.ty == Tarray) {
                // A normal dynamic-array index evaluates its index before
                // the array expression. `$` needs the descriptor captured
                // first, so that special form keeps the extra early step.
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
            if (index.e1.type.ty == Tpointer) {
                auto base = resolve(index.e1);
                auto pointer = _adapter.storagePointerIndexBase(index, base);
                auto indexValue = _adapter.storagePointerIndexValue(index);
                return _adapter.storagePointerIndex(
                    index, pointer, indexValue);
            }
            return _adapter.storageValue(index);
        }

        if (auto field = expression.isDotVarExp)
            return _adapter.storageField(field);

        return _adapter.storageValue(expression);
    }

    private Result assignmentResult(
        AssignExp expression, Expression targetExpression,
    ) {
        // Resolve the target first. This is the only evaluation of the
        // assignment's left side; the adapter receives its location and can
        // then evaluate and store the right side exactly once.
        auto target = resolve(targetExpression);
        if (expression.e1.isSliceExp !is null)
            _adapter.storageSliceAssignment(expression, target);
        else
            _adapter.storagePlainAssignment(expression, target);
        return target;
    }

    private Result assignmentResult(
        BinAssignExp expression, Expression targetExpression,
    ) {
        // CatAssignExp is a BinAssignExp in dmd's AST. The typed overload
        // keeps that family dispatch complete without asking `isAssignExp`,
        // whose predicate only accepts the plain `EXP.assign` opcode.
        auto target = resolve(targetExpression);
        if (auto cat = expression.isCatAssignExp)
            _adapter.storageCatAssignment(cast(CatAssignExp) cat, target);
        else
            _adapter.storageCompoundAssignment(expression, target);
        return target;
    }
}
