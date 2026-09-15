module snakebite.backends.declaration;


private:


// Layout and execution must see the same variables after DMD expands
// attributes, template mixins, and tuple declarations. The action runs
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
                action(member.isVarDeclaration);
            });
        else
            action(variable);
    }
    return 0;
}
