module snakebite.backends.declaration;


private:


private struct RuntimeVariables {
    imported!"dmd.declaration".VarDeclaration[] values;
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


// Return the variable represented by a declaration expression. DMD keeps
// declaration attributes as wrappers. Its semantic accessor selects the
// branch that belongs to the program being compiled. Other symbols only bind
// names or types, so they have no runtime variable.
public imported!"dmd.declaration".VarDeclaration[] runtimeVariables(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    import dmd.dsymbolsem: apply;

    RuntimeVariables result;

    apply(declaration, &collectRuntimeVariable, &result);
    return result.values;
}
