module snakebite.backends.declaration;


private:


// Layout and execution must see the same variables after DMD expands
// attributes, template mixins, and tuple declarations. A manifest constant
// (`enum x = ...;`) is not a runtime variable: dmd semantic already
// replaced each use with its value, so nothing reads a slot. The action runs
// during traversal so execution does not allocate a variable collection.
public void forEachRuntimeVariable(
    imported!"dmd.dsymbol".Dsymbol declaration,
    scope void delegate(imported!"dmd.declaration".VarDeclaration) action,
) {
    import dmd.dsymbolsem: apply;

    declaration.apply(&visitRuntimeVariable, &action);
}


private int visitRuntimeVariable(
    imported!"dmd.dsymbol".Dsymbol symbol,
    void* context,
) {
    import dmd.declaration: VarDeclaration;

    alias Action = void delegate(VarDeclaration);
    const action = *cast(Action*) context;
    if (auto variable = symbol.isVarDeclaration) {
        if (auto tuple = variable.aliasTuple)
            tuple.foreachVar((member) {
                if (!member.isVarDeclaration.isManifest)
                    action(member.isVarDeclaration);
            });
        else if (!variable.isManifest)
            action(variable);
    }
    return 0;
}


private bool isManifest(imported!"dmd.declaration".VarDeclaration variable) {
    import dmd.astenums: STC;

    return (variable.storage_class & STC.manifest) != 0;
}
