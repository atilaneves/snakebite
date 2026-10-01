module snakebite.frontend.dmd.linking;


private:


// What the linker does for the root modules of a program: a declaration with
// no definition of its own, a function without a body or a variable marked
// `extern`, is the one definition of the same symbol in another root module.
// An `extern int fromD(int);` prototype in a C file and the `extern(C)` D
// definition of `fromD` are one function, and so are `extern int x;` in one
// C file and `int x = 3;` in another.
//
// The key is the mangled name, because that is what the linker compares: it
// holds for `pragma(mangle)`, for a C++ namespace and for a declaration in a
// module that is not a root. An entity with internal linkage (a C `static`)
// is never a definition for another translation unit.
public struct LinkMap {
    import dmd.declaration: VarDeclaration;
    import dmd.dmodule: Module;
    import dmd.dsymbol: Dsymbol;
    import dmd.func: FuncDeclaration;

    private FuncDeclaration[string] _functions;
    private VarDeclaration[string] _variables;

    public this(Module[] modules) {
        import snakebite.frontend.dmd.mangle: mangledNameOf;
        import snakebite.nativelayout: nativeSymbolName;

        foreach (module_; modules)
            forEachModuleScopeSymbol(module_.members, (symbol) {
                if (auto function_ = symbol.isFuncDeclaration) {
                    if (isExternalDefinition(function_)
                            && canLinkByName(function_))
                        _functions.require(
                            function_.mangledNameOf.idup, function_);
                } else if (auto variable = symbol.isVarDeclaration) {
                    if (isExternalDefinition(variable)
                            && canLinkByName(variable))
                        _variables.require(
                            variable.nativeSymbolName, variable);
                }
            });
    }

    // `declaration` when it has a body, no definition is known for it, or
    // it cannot be linked by name.
    public FuncDeclaration definitionOf(
        FuncDeclaration declaration,
    ) const {
        import snakebite.frontend.dmd.mangle: mangledNameOf;

        if (declaration.fbody !is null || !canLinkByName(declaration)
                || declaration.isCsymbol && declaration.isStatic)
            return declaration;

        if (auto definition = declaration.mangledNameOf in _functions)
            return cast(FuncDeclaration) *definition;

        return declaration;
    }

    // `declaration` when it is not `extern` or no definition is known.
    public VarDeclaration definitionOf(
        VarDeclaration declaration,
    ) const {
        import dmd.astenums: STC;
        import snakebite.nativelayout: nativeSymbolName;

        if (!(declaration.storage_class & STC.extern_)
                || !canLinkByName(declaration)
                || declaration.isCsymbol && declaration.isStatic)
            return declaration;

        if (auto definition = declaration.nativeSymbolName in _variables)
            return cast(VarDeclaration) *definition;

        return declaration;
    }
}

// A symbol of D linkage and without `pragma(mangle)` has the name of its own
// module in its mangled name, so it cannot be the same symbol as one in
// another module. This keeps the mangling of every function of a large
// project out of the start of a run.
private bool canLinkByName(
    imported!"dmd.declaration".Declaration declaration,
) {
    import dmd.astenums: LINK;

    return declaration.resolvedLinkage != LINK.d
        || declaration.mangleOverride.length != 0;
}

private bool isExternalDefinition(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody !is null
        && !(function_.isCsymbol && function_.isStatic);
}

private bool isExternalDefinition(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: STC;

    return variable.isDataseg
        && !(variable.storage_class & STC.extern_)
        && !(variable.isCsymbol && variable.isStatic);
}

// The symbols that a module declares at its own scope, as a linker sees
// them: through conditional and attribute declarations and through the
// scope of a C++ namespace.
private void forEachModuleScopeSymbol(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    scope void delegate(imported!"dmd.dsymbol".Dsymbol) action,
) {
    import dmd.dsymbolsem: include;

    if (symbols is null)
        return;

    foreach (member; *symbols) {
        if (auto function_ = member.isFuncDeclaration) {
            if (function_.isFuncLiteralDeclaration is null
                    && function_.isUnitTestDeclaration is null
                    && function_.isStaticCtorDeclaration is null
                    && function_.isStaticDtorDeclaration is null)
                action(function_);
        } else if (auto attributes = member.isAttribDeclaration)
            forEachModuleScopeSymbol(include(attributes, null), action);
        else if (auto namespace = member.isNspace)
            forEachModuleScopeSymbol(namespace.members, action);
        else
            action(member);
    }
}
