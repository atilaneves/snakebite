module snakebite.frontend.hostlayout;


// The host's compiled druntime and Phobos own the layout of the classes
// they provide. The frontend builds the AST of those classes from source,
// and a host built by another compiler can lay a class out differently
// (`core.thread.Fiber` has more fields under LDC). A guest class derived
// from such a class starts its own fields where the AST says the base
// ends, so the AST size of every host-provided class must be the host's.
//
// dmd computes a class size lazily, in `determineSize`, and copies the
// base class size into each derived class. So this runs after `importAll`
// has loaded every module-level import and before the first root module
// semantic, the only point where no guest class can have a size yet.
// With `correct` false it only verifies: for a module an `importAll`
// could not reach, which loads while a root module is analysed.
public void reconcileHostClassLayouts(
    imported!"dmd.dmodule".Module[] rootModules,
    in bool correct,
) {
    import dmd.dmodule: Module;
    import dmd.dsymbol: PASS;
    import dmd.dsymbolsem: dsymbolSemantic;

    bool[Module] roots;
    foreach (module_; rootModules)
        roots[module_] = true;

    // `amodules` can grow while a class is analysed.
    for (size_t i = 0; i < Module.amodules.length; ++i) {
        auto module_ = Module.amodules[i];
        if (module_ in roots || module_.members is null)
            continue;
        // A class only resolves its base and its field types once the
        // scope of its module has been through semantic.
        if (correct && module_.semanticRun == PASS.initial
                && module_._scope !is null)
            module_.dsymbolSemantic(null);
        reconcileMembers(module_.members, correct);
    }
}


private:


import dmd.arraytypes: Dsymbols;
import dmd.dclass: ClassDeclaration;


TypeInfo_Class[string] hostClasses;

TypeInfo_Class[string] loadHostClasses() {
    if (hostClasses.length == 0)
        foreach (module_; ModuleInfo)
            foreach (info; module_.localClasses)
                if (info.name.length)
                    hostClasses[info.name] = info;
    return hostClasses;
}

void reconcileMembers(Dsymbols* members, in bool correct) {
    import dmd.dsymbolsem: include;

    foreach (member; *members) {
        if (auto attributes = member.isAttribDeclaration) {
            if (auto included = include(attributes, null))
                reconcileMembers(included, correct);
        } else if (auto declaration = member.isClassDeclaration) {
            reconcileClass(declaration, correct);
            if (declaration.members !is null)
                reconcileMembers(declaration.members, correct);
        }
    }
}

void reconcileClass(ClassDeclaration declaration, in bool correct) {
    import dmd.astenums: Sizeok;
    import dmd.aggregate: ClassKind;
    import dmd.dsymbolsem: determineSize, dsymbolSemantic;
    import dmd.errors: error;
    import std.conv: to;

    if (declaration.isInterfaceDeclaration !is null
            || declaration.classKind != ClassKind.d
            || declaration.members is null || declaration.errors)
        return;
    const name = declaration.toPrettyChars.to!string;
    auto found = name in loadHostClasses;
    if (found is null)
        return;
    const host = *found;
    const hostSize = host.initializer.length;

    if (!correct) {
        if (declaration.sizeok == Sizeok.done
                && declaration.structsize != hostSize)
            error(declaration.loc,
                "class `%s` has size %llu in the analysed source but "
                ~ "%llu in the host that provides it, and a class derived "
                ~ "from it is already laid out",
                declaration.toPrettyChars,
                cast(ulong) declaration.structsize, cast(ulong) hostSize);
        return;
    }

    if (declaration._scope !is null)
        dsymbolSemantic(declaration, null);
    // Base first, so that a derived host class sees the corrected base.
    if (declaration.baseClass !is null)
        reconcileClass(declaration.baseClass, correct);
    if (!declaration.determineSize(declaration.loc))
        return;
    declaration.structsize = cast(uint) hostSize;

    if (declaration.vtbl.length != host.vtbl.length)
        error(declaration.loc,
            "class `%s` has %llu virtual functions in the analysed source "
            ~ "but %llu in the host that provides it",
            declaration.toPrettyChars,
            cast(ulong) declaration.vtbl.length, cast(ulong) host.vtbl.length);
}
