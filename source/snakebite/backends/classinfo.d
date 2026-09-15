module snakebite.backends.classinfo;


private:


import dmd.dclass: ClassDeclaration;
import dmd.func: FuncDeclaration;
import object: Interface, TypeInfo_Class;


// Callable addresses and field initializers differ between backends.
// Object layout and DMD's resolved vtables do not.
public struct Hooks {
    public void* delegate(FuncDeclaration method, ptrdiff_t adjustment)
        methodAddress;
    public void delegate(ClassDeclaration declaration, ubyte* base)
        fillFieldInits;
    public TypeInfo_Class delegate(ClassDeclaration declaration)
        linkedClassInfo;
    public void delegate(ClassDeclaration declaration, TypeInfo_Class info)
        registerGenerated;
}

public alias ClassRuntimeCache = TypeInfo_Class[ClassDeclaration];

public TypeInfo_Class classRuntimeInfo(
    imported!"dmd.dclass".ClassDeclaration declaration,
    ref ClassRuntimeCache cache,
    Hooks hooks,
) {
    import dmd.root.string: toDString;

    if (auto cached = declaration in cache)
        return *cached;
    if (auto linked = hooks.linkedClassInfo(declaration)) {
        cache[declaration] = linked;
        return linked;
    }

    auto info = new TypeInfo_Class;
    info.m_flags = cast(TypeInfo_Class.ClassFlags) 0;
    info.name = cast(string) declaration.toPrettyChars.toDString;
    // Register before resolving methods: their bodies can refer to this
    // same class while its metadata is being built.
    cache[declaration] = info;
    if (hooks.registerGenerated !is null)
        hooks.registerGenerated(declaration, info);

    const isInterface = declaration.isInterfaceDeclaration !is null;
    if (!isInterface && declaration.baseClass !is null)
        info.base = classRuntimeInfo(declaration.baseClass, cache, hooks);

    const baseLength = info.base is null ? 0 : info.base.vtbl.length;
    const length = declaration.vtbl.length > baseLength
        ? declaration.vtbl.length : baseLength;
    info.vtbl = new void*[length];
    if (info.base !is null)
        info.vtbl[0 .. baseLength] = info.base.vtbl[];
    if (length)
        info.vtbl[0] = cast(void*) info;

    if (!isInterface) {
        if (declaration.dtor !is null)
            info.destructor = hooks.methodAddress(declaration.dtor, 0);
        foreach (i; 1 .. declaration.vtbl.length) {
            auto method = declaration.vtbl[i].isFuncDeclaration;
            if (method !is null)
                info.vtbl[i] = hooks.methodAddress(method, 0);
        }
        // Initializers contain GC pointers, including inherited vtables.
        info.m_init = cast(byte[]) new void[declaration.structsize];
        info.m_init[] = 0;
        if (info.base !is null)
            info.m_init[0 .. info.base.m_init.length] = info.base.m_init[];
        *cast(void**) info.m_init.ptr = info.vtbl.ptr;
        hooks.fillFieldInits(declaration, cast(ubyte*) info.m_init.ptr);
    }

    info.interfaces = new Interface[declaration.vtblInterfaces.length];
    foreach (i; 0 .. declaration.vtblInterfaces.length) {
        auto base = (*declaration.vtblInterfaces)[i];
        info.interfaces[i] = Interface(
            classRuntimeInfo(base.sym, cache, hooks), null, base.offset,
        );
        if (!isInterface) {
            auto table = _interfaceVtable(
                declaration, base, &info.interfaces[i], hooks);
            info.interfaces[i].vtbl = table;
            *cast(void**)(info.m_init.ptr + base.offset) = table.ptr;
        }
    }

    // An inherited interface keeps its object offset and its Interface
    // descriptor. A derived override gets a new table at that same offset.
    if (!isInterface)
        for (auto parent = declaration.baseClass;
                parent !is null; parent = parent.baseClass) {
            auto parentInfo = classRuntimeInfo(parent, cache, hooks);
            foreach (i; 0 .. parent.vtblInterfaces.length) {
                import dmd.dsymbolsem: fillVtbl;
                auto base = (*parent.vtblInterfaces)[i];
                if (!base.fillVtbl(declaration, null, 0))
                    continue;
                auto table = _interfaceVtable(
                    declaration, base, &parentInfo.interfaces[i], hooks);
                *cast(void**)(info.m_init.ptr + base.offset) = table.ptr;
            }
        }
    return info;
}

private void*[] _interfaceVtable(
    imported!"dmd.dclass".ClassDeclaration declaration,
    imported!"dmd.dclass".BaseClass* base,
    Interface* descriptor, Hooks hooks,
) {
    import dmd.arraytypes: FuncDeclarations;
    import dmd.dsymbolsem: fillVtbl;

    FuncDeclarations methods;
    base.fillVtbl(declaration, &methods, 0);
    auto table = new void*[methods.length];
    const first = base.sym.vtblOffset;
    if (first)
        table[0] = descriptor;
    foreach (i; first .. methods.length) {
        auto method = methods[i];
        if (method is null)
            continue;
        const adjustment = -cast(ptrdiff_t) base.offset
            + (method.interfaceVirtual is null
                ? 0 : method.interfaceVirtual.offset);
        table[i] = hooks.methodAddress(method, adjustment);
    }
    return table;
}
