module snakebite.backends.interpreter.preparedfacts;

private:

import dmd.declaration: VarDeclaration;
import dmd.expression: CallExp, StructLiteralExp, StringExp;
import dmd.func: FuncDeclaration;
import dmd.mtype: Type;
import dmd.astenums: Tfunction, Ttuple, Terror;
import dmd.typesem: toBasetype, baseElemOf;
import dmd.location: Loc;
import snakebite.backends.runtimetypes: RuntimeTypes;
import snakebite.backends.aggregateinit: AggregateInitPlan, planStructLiteral;
import snakebite.backends.dualcontext: ContextSource, calleeContextSourceOf;
import snakebite.frontend.compiler: gagged;
import snakebite.nativelayout:
    NativeData, TypeFacts, typeFacts, tryTypeFacts, bitfieldAccess;
import snakebite.nativevalue: BitfieldAccess;
import snakebite.sharedtable: SharedTable;

// Facts have one program owner. Preparation and ordinary execution use the
// same builders, so a prepared callback reads the same immutable entries.
package struct PreparedFacts {
    private SharedTable!(Type, TypeFacts) _types;
    private SharedTable!(VarDeclaration, BitfieldAccess) _bitfields;
    private SharedTable!(StructLiteralExp, AggregateInitPlan) _literals;
    private struct ContextKey {
        const(void)* site;
        const(void)* callee;
    }
    private SharedTable!(ContextKey, ContextSource) _contexts;

    private NativeData* _nativeData;
    private RuntimeTypes* _runtimeTypes;

    package this(NativeData* nativeData, RuntimeTypes* runtimeTypes) {
        _nativeData = nativeData;
        _runtimeTypes = runtimeTypes;
    }

    package TypeFacts typeOf(Type type) {
        if (auto found = type in _types)
            return *found;
        return *_types.insert(type, typeFacts(type));
    }

    package void prepareType(Type type) {
        attempt({
            prepareValue(type);
            if (type !is null) {
                auto base = type.toBasetype;
                if (base !is type)
                    prepareValue(base);
            }
        });
    }

    private void prepareValue(Type type) {
        if (type is null || type in _types)
            return;
        const kind = type.toBasetype.ty;
        if (kind == Tfunction || kind == Ttuple || kind == Terror)
            return;
        TypeFacts facts;
        if (tryTypeFacts(type, facts))
            _types.insert(type, facts);
    }

    package void prepareBitfield(VarDeclaration field) {
        attempt({ bitfieldOf(field); });
    }

    package void prepareZeroInitialized(Type type) {
        attempt({
            auto element = type.baseElemOf.toBasetype;
            if (element.isTypeStruct !is null)
                prepareDefault(element);
        });
    }

    // Cold nodes that never execute must not force large default storage.
    private enum preparedBytesLimit = 64 * 1024;

    private void prepareDefault(Type type) {
        TypeFacts facts;
        if (tryTypeFacts(type, facts) && facts.size <= preparedBytesLimit)
            _nativeData.initialValue(type, Loc.initial);
    }

    package void prepareStorage(VarDeclaration variable) {
        TypeFacts facts;
        if (!tryTypeFacts(variable.type, facts)
                || facts.size > preparedBytesLimit)
            return;
        if (variable.isThreadlocal)
            _nativeData.tlsDescriptorOf(variable);
        else
            _nativeData.storageOf(variable);
    }

    package void prepareLiteral(StructLiteralExp expression) {
        attempt({
            structLiteralOf(expression);
            if (expression.useStaticInit)
                prepareDefault(expression.type);
        });
    }

    package void prepareString(StringExp expression) {
        attempt({ _nativeData.stringData(expression); });
    }

    package void prepareTypeInfo(Type type) {
        attempt({ _runtimeTypes.get(type); });
    }

    // Failed eager analysis must stay for the execution that needs the node.
    private static void attempt(scope void delegate() action) {
        try
            gagged(action);
        catch (Exception) {
        }
    }

    package const(BitfieldAccess)* bitfieldOf(VarDeclaration field) {
        if (auto found = field in _bitfields)
            return found;
        return _bitfields.insert(field, bitfieldAccess(field));
    }

    package AggregateInitPlan* structLiteralOf(StructLiteralExp expression) {
        if (auto found = expression in _literals)
            return found;
        return _literals.insert(expression, planStructLiteral(expression));
    }

    package const(ContextSource)* contextOf(
        CallExp site, FuncDeclaration caller, FuncDeclaration callee,
    ) {
        const key = ContextKey(cast(const(void)*) site, cast(const(void)*) callee);
        if (auto found = key in _contexts)
            return found;
        // Inherited contracts can need a base frame even if its body never
        // runs. Callback preparation must build that context before entry.
        return _contexts.insert(key, calleeContextSourceOf(caller, callee));
    }
}
