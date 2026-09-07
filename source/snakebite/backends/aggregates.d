module snakebite.backends.aggregates;


private:


// Direct field construction does not copy a value. A raw copy can require
// separate lifecycle calls in DMD's lowered expression, so callers must
// select the facts for the operation they execute.
public struct AggregateFacts {
    import dmd.mtype: Type;
    public bool nativeFields;
    public bool plainCopy;
    public bool loweredCopy;

    public static AggregateFacts of(Type type) {
        import dmd.astenums: STC;
        import snakebite.nativelayout: isNativeBytes;

        auto structType = type.isTypeStruct;
        if (structType is null)
            return AggregateFacts.init;

        auto declaration = structType.sym;
        if (declaration.isUnionDeclaration !is null)
            return AggregateFacts.init;

        const hasLifecycle = declaration.postblit !is null
            || declaration.dtor !is null;
        const hasAssignment = declaration.hasIdentityAssign
            || declaration.hasBlitAssign;
        // DMD also generates assignment for postblits and destructors.
        // Those flags alone do not imply an independent assignment hook.
        auto facts = AggregateFacts( // Updated for each nested field.
            true,
            declaration.enclosing is null && !hasLifecycle
                && !declaration.hasCopyCtor && !hasAssignment,
            !declaration.hasCopyCtor && (hasLifecycle || !hasAssignment),
        );

        foreach (field; declaration.fields) {
            if (field.isBitFieldDeclaration !is null
                    || (field.storage_class & STC.ref_))
                return AggregateFacts.init;

            if (field.type.isTypeStruct !is null) {
                const nested = of(field.type);
                facts.nativeFields = facts.nativeFields && nested.nativeFields;
                facts.plainCopy = facts.plainCopy && nested.plainCopy;
                facts.loweredCopy = facts.loweredCopy && nested.loweredCopy;
            } else if (!isNativeBytes(field.type))
                return AggregateFacts.init;
        }

        return facts;
    }
}
