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

// Calls through values carry their context in the value, not in a class
// receiver expression. A constructor delegation can name `this` or
// `super` without a DotVarExp.
public imported!"dmd.expression".Expression classReceiverOf(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration callee,
) {
    import dmd.astenums: Tclass;
    import dmd.typesem: toBasetype;

    const aggregate = callee.isThis;
    if (aggregate is null || aggregate.isClassDeclaration is null)
        return null;

    auto dot = call.e1.isDotVarExp;
    auto receiver = dot is null ? call.e1 : dot.e1;
    return receiver.type.toBasetype.ty == Tclass ? receiver : null;
}

// dmd checks the receiver at the vtable read, after argument evaluation.
public bool readsVtable(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration callee,
) {
    return classReceiverOf(call, callee) !is null
        && usesVtable(callee, call.directcall);
}
