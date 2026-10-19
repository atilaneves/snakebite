module snakebite.backends.plaincondition;


private:

import dmd.expression: Expression;
import dmd.tokens: EXP;
import snakebite.backends.identity: identityPlan;
import snakebite.nativelayout: isIntegralSize, typeFacts;
import std.typecons: Flag, No, Yes;

package bool isRealFloatType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tfloat32, Tfloat64, Tfloat80;
    import dmd.typesem: toBasetype;

    const ty = type.toBasetype.ty;
    return ty == Tfloat32 || ty == Tfloat64 || ty == Tfloat80;
}

// A condition that creates no temporary with a lifetime of its own, so
// that splitting `&&` and `||` into branches changes no destructor
// order: scalar operations on scalar variables and literals, and direct
// calls of them. Aggregates and everything else keep the value path.
package bool isPlainCondition(
    Expression expression, in Flag!"calls" calls = Yes.calls,
) {
    import dmd.astenums: STC, Tpointer, VarArg;
    import dmd.typesem: toBasetype;

    const facts = typeFacts(expression.type);
    const scalar = (facts.isIntegral && isIntegralSize(facts.size))
        || isRealFloatType(expression.type)
        || expression.type.toBasetype.ty == Tpointer;
    if (!scalar)
        return false;

    with (EXP) switch (expression.op) {
        case int64, float64, null_:
            return true;
        case variable:
            auto variable = expression.isVarExp.var.isVarDeclaration;
            return variable !is null
                && !(variable.storage_class & STC.lazy_);
        case add, min, mul, div, lessThan, lessOrEqual, greaterThan,
                greaterOrEqual, equal, notEqual, andAnd, orOr:
            auto binary = expression.isBinExp;
            return isPlainCondition(binary.e1, calls)
                && isPlainCondition(binary.e2, calls);
        case dotVariable, star, arrayLength, index:
            return isPlainPlace(expression);
        case identity, notIdentity:
            auto binary = expression.isBinExp;
            return identityPlan(binary.isIdentityExp).reference
                && isPlainCondition(binary.e1, calls)
                && isPlainCondition(binary.e2, calls);
        case cast_, negate, not:
            return isPlainCondition(expression.isUnaExp.e1, calls);
        case call:
            if (!calls)
                return false;
            auto call = expression.isCallExp;
            if (call.f is null)
                return false;
            auto tf = call.f.type.isTypeFunction;
            if (tf is null || tf.parameterList.varargs != VarArg.none
                    || tf.isRef)
                return false;
            if (call.arguments !is null)
                foreach (argument; *call.arguments)
                    if (!isPlainCondition(argument))
                        return false;
            if (auto dot = call.e1.isDotVarExp)
                return isPlainPlace(dot.e1);
            return call.e1.isVarExp !is null;
        default:
            return false;
    }
}

// A chain of fields, dereferences and `this` over variables: reading
// it creates no temporary with a lifetime of its own.
package bool isPlainPlace(Expression expression) {
    import dmd.astenums: STC;

    with (EXP) switch (expression.op) {
        case variable:
            auto variable = expression.isVarExp.var.isVarDeclaration;
            return variable !is null
                && !(variable.storage_class & STC.lazy_);
        case this_:
            return true;
        case dotVariable:
            return isPlainPlace(expression.isDotVarExp.e1);
        case star:
            return isPlainPlace(expression.isPtrExp.e1);
        case arrayLength:
            return isPlainPlace(expression.isArrayLengthExp.e1);
        case index:
            auto indexed = expression.isIndexExp;
            return isPlainPlace(indexed.e1)
                && isPlainCondition(indexed.e2, No.calls);
        default:
            return false;
    }
}
