module snakebite.language.layout.variables;


private:


// Layout and execution must see the same variables after DMD expands
// attributes, template mixins, and tuple declarations. A manifest constant
// (`enum x = ...;`) is not a runtime variable: dmd semantic already
// replaced each use with its value, so nothing reads a slot. The action runs
// during traversal so execution does not allocate a variable collection.
public void forEachRuntimeVariable(
    imported!"snakebite.frontend.ast".Dsymbol declaration,
    scope void delegate(imported!"snakebite.frontend.ast".VarDeclaration) action,
) {
    import snakebite.frontend.ast: apply;

    declaration.apply(&visitRuntimeVariable, &action);
}


private int visitRuntimeVariable(
    imported!"snakebite.frontend.ast".Dsymbol symbol,
    void* context,
) {
    import snakebite.frontend.ast: VarDeclaration;

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


private bool isManifest(imported!"snakebite.frontend.ast".VarDeclaration variable) {
    import snakebite.frontend.ast: STC;

    return (variable.storage_class & STC.manifest) != 0;
}
