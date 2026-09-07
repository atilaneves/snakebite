module snakebite.druntime.constructoratomic;


private:


// DMD generates this operation to gate an instantiated shared module
// constructor. The host compiler builds this wrapper with its own druntime,
// so its inline assembly stays in compiled host code.
public extern(C) int snakebite_constructor_atomic_add_int(
    shared int* value,
    int amount,
) nothrow @trusted {
    import core.atomic: atomicOp;

    return atomicOp!"+="(*value, amount);
}


public struct NativeTarget {
    public void* address;
    public imported!"dmd.astenums".LINK linkage;
}


// The declaration is checked by resolved module and template identity, then
// by template arguments and D ABI. A matching declaration therefore cannot
// be an application function with the same unqualified name.
public NativeTarget nativeTarget(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: LINK, STC, Tint32, VarArg;
    import dmd.dtemplate: isExpression, isType;
    import dmd.root.string: toDString;
    import dmd.typesem: nextOf;

    auto instance = function_.isInstantiated;
    if (instance is null || instance.tempdecl is null)
        return NativeTarget.init;

    auto template_ = instance.tempdecl.isTemplateDeclaration;
    auto module_ = template_ is null ? null : template_.getModule;
    if (module_ is null || module_.toPrettyChars.toDString != "core.atomic"
            || template_.ident.toString != "atomicOp")
        return NativeTarget.init;

    if (instance.tiargs is null || instance.tiargs.length != 3)
        return NativeTarget.init;

    auto operation = (*instance.tiargs)[0].isExpression;
    auto operationString = operation is null ? null : operation.isStringExp;
    if (operationString is null || operationString.len != 2
            || operationString.getCodeUnit(0) != '+'
            || operationString.getCodeUnit(1) != '=')
        return NativeTarget.init;

    foreach (argument; (*instance.tiargs)[1 .. 3]) {
        auto type = argument.isType;
        if (type is null || type.ty != Tint32 || type.isShared)
            return NativeTarget.init;
    }

    auto type = function_.type.isTypeFunction;
    if (type is null || (function_.resolvedLinkage != LINK.d
            && function_.resolvedLinkage != LINK.default_)
            || type.parameterList.varargs != VarArg.none
            || type.parameterList.length != 2 || type.nextOf.ty != Tint32)
        return NativeTarget.init;

    const first = type.parameterList[0];
    const second = type.parameterList[1];
    if (first.type.ty != Tint32 || !first.type.isShared
            || first.storageClass != (STC.parameter | STC.ref_)
            || second.type.ty != Tint32 || second.type.isShared
            || second.storageClass != STC.parameter)
        return NativeTarget.init;

    return NativeTarget(&snakebite_constructor_atomic_add_int, LINK.c);
}
