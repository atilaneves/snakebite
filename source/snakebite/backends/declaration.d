module snakebite.backends.declaration;


private:


// Layout and execution must see the same variables after DMD expands
// attributes, template mixins, and tuple declarations.
public imported!"dmd.declaration".VarDeclaration[] runtimeVariables(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    import dmd.dsymbolsem: apply;

    RuntimeVariables result;
    declaration.apply(&collectRuntimeVariable, &result);
    return result.values;
}


private struct RuntimeVariables {
    import dmd.declaration: VarDeclaration;

    VarDeclaration[] values;
}


private int collectRuntimeVariable(
    imported!"dmd.dsymbol".Dsymbol symbol,
    void* context,
) {
    auto variables = cast(RuntimeVariables*) context;
    if (auto variable = symbol.isVarDeclaration) {
        if (auto tuple = variable.aliasTuple)
            tuple.foreachVar((member) {
                variables.values ~= member.isVarDeclaration;
            });
        else
            variables.values ~= variable;
    }
    return 0;
}
