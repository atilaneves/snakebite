module snakebite.frontend.dmd.functions;

private:

// The module-level function called `name`, or null if there is none.
public imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    return findFunction(module_.members, name);
}

// The member function of `struct_` called `name`, or null if there is none.
public imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.dstruct".StructDeclaration struct_,
    in string name,
) {
    return findFunction(struct_.members, name);
}

// The module-level struct called `name`, or null if there is none.
public imported!"dmd.dstruct".StructDeclaration findStruct(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    if (module_.members is null)
        return null;

    foreach (member; *module_.members) {
        auto struct_ = member.isStructDeclaration;
        if (struct_ !is null && struct_.ident.toString == name)
            return struct_;
    }

    return null;
}

// Attribute declarations (`static:`, `private:`, ...) wrap the symbols they
// apply to, so the search descends into them.
private imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    in string name,
) {
    if (symbols is null)
        return null;

    foreach (member; *symbols) {
        auto function_ = member.isFuncDeclaration;
        if (function_ !is null && function_.ident.toString == name)
            return function_;

        if (auto attributes = member.isAttribDeclaration)
            if (auto found = findFunction(attributes.decl, name))
                return found;
    }

    return null;
}
