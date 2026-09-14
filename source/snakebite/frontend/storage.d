module snakebite.frontend.storage;

private:


import dmd.expression: AssignExp, Expression;
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
            return assignmentResult(cast() assignment);

        if (auto construct = expression.isConstructExp)
            return assignmentResult(cast() construct);

        if (auto assignment = expression.isAssignExp)
            return assignmentResult(cast() assignment);

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
            if (index.e1.type.ty == Tarray)
                return _adapter.storageDynamicIndex(index);
            if (index.e1.type.ty == Tsarray)
                return _adapter.storageStaticIndex(index);
            if (index.e1.type.ty == Tpointer)
                return _adapter.storagePointerIndex(index);
            return _adapter.storageValue(index);
        }

        if (auto field = expression.isDotVarExp)
            return _adapter.storageField(field);

        return _adapter.storageValue(expression);
    }

    private Result assignmentResult(AssignExp assignment) {
        // Resolve the target first. This is the only evaluation of the
        // assignment's left side; the adapter receives its location and can
        // then evaluate and store the right side exactly once.
        auto target = resolve(assignment.e1);
        _adapter.storageAssignment(assignment, target);
        return target;
    }
}
