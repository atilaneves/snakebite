module snakebite.backends.arrayliteral;


private:

import snakebite.nativelayout: TypeFacts;


public struct ArrayLiteralPlan {
    import dmd.mtype: Type;

    public enum Storage { empty, temporary, lowering }
    public enum Result { slice, pointer, value }

    public Storage storage;
    public Result result;
    public Type elementType;
    public TypeFacts elementFacts;
    public size_t count;
    public size_t bytes;
}

public ArrayLiteralPlan planArrayLiteral(
    imported!"dmd.expression".ArrayLiteralExp expression,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: FileType, Tarray, Tpointer, Tsarray, Tvoid;
    import dmd.mtype: Type;
    import dmd.typesem: nextOf, toBasetype;

    auto type = expression.type.toBasetype; // DMD element types remain mutable.
    const kind = type.ty;
    assert(kind == Tarray || kind == Tpointer || kind == Tsarray);
    auto elementType = type.nextOf;
    // DMD's glue executes void[n] initializers as ubyte[n].
    if (kind == Tsarray && elementType.toBasetype.ty == Tvoid)
        elementType = Type.tuns8;

    ArrayLiteralPlan plan;
    plan.result = kind == Tarray ? ArrayLiteralPlan.Result.slice
        : kind == Tpointer ? ArrayLiteralPlan.Result.pointer
        : ArrayLiteralPlan.Result.value;
    plan.elementType = elementType;
    plan.elementFacts = TypeFacts.of(elementType);
    plan.count = expression.elements is null ? 0 : expression.elements.length;
    plan.bytes = plan.count * plan.elementFacts.size;
    // Scope-local and equality transforms can set onstack after lowering.
    plan.storage = plan.count == 0 ? ArrayLiteralPlan.Storage.empty
        : expression.onstack || kind == Tsarray
            || (function_.getModule.filetype == FileType.c && kind == Tpointer)
        ? ArrayLiteralPlan.Storage.temporary
        : ArrayLiteralPlan.Storage.lowering;
    return plan;
}
