module snakebite.frontend.dmd.dispatch;


private:


// dmd's glue uses the same rule for a member call and a method delegate.
// A final override has a vtable slot, but its own declaration binds
// statically (e2ir.d's call and DelegateExp paths).
public bool usesVtable(
    imported!"dmd.func".FuncDeclaration function_,
    in bool directcall,
) {
    import dmd.funcsem: isVirtual;

    return !directcall && function_.isVirtual && !function_.isFinalFunc;
}

public struct CallReceiver {
    import dmd.expression: Expression;

    public enum Kind {
        enclosing,
        classValue,
        aggregateAddress,
        implicitThis,
    }

    public Kind kind;
    public Expression expression;
}

// A direct call gets its context from the receiver or the static chain.
// Calls through values use the context carried by the value instead.
public CallReceiver receiverOf(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration callee,
) {
    import dmd.astenums: Tclass;
    import dmd.typesem: toBasetype;

    if (callee.isThis is null)
        return CallReceiver.init;

    auto dot = call.e1.isDotVarExp;
    auto receiver = dot is null ? call.e1 : dot.e1;
    if (receiver.type.toBasetype.ty == Tclass)
        return CallReceiver(CallReceiver.Kind.classValue, receiver);
    if (dot !is null || receiver.isThisExp !is null
            || receiver.isSuperExp !is null)
        return CallReceiver(CallReceiver.Kind.aggregateAddress, receiver);
    return CallReceiver(CallReceiver.Kind.implicitThis, null);
}

public imported!"dmd.expression".Expression classReceiverOf(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration callee,
) {
    // DMD expressions must stay mutable for backend evaluation.
    auto receiver = receiverOf(call, callee);
    return receiver.kind == CallReceiver.Kind.classValue
        ? receiver.expression : null;
}

// dmd checks the receiver at the vtable read, after argument evaluation.
public bool readsVtable(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration callee,
) {
    return classReceiverOf(call, callee) !is null
        && usesVtable(callee, call.directcall);
}
