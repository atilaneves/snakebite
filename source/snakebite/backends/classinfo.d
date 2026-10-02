module snakebite.backends.classinfo;


private:


import dmd.aggregate: AggregateDeclaration;
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
    public immutable(void)* delegate(AggregateDeclaration declaration) rtInfo;
    public void delegate(ClassDeclaration declaration, TypeInfo_Class info)
        registerGenerated;
}

// The `TypeInfo_Class` built for each guest class. Every thread that
// runs guest code reads a complete entry without a lock (`find`,
// ADR-0006). An entry under construction is visible only through `in`,
// to the one thread that builds it while it holds the compiler lock:
// `classRuntimeInfo` registers a class before its vtable and fields are
// filled, so a class that reaches itself again through a base or an
// interface finds the same object. `build` runs one construction and
// publishes everything it registered once the outermost construction
// on this thread is complete.
public struct ClassRuntimeCache {
    // Holds a `SharedTable` (finding 2.4): a copy would share its
    // storage with the original until one side grows.
    @disable this(this);

    import snakebite.sharedtable: SharedTable;

    private SharedTable!(ClassDeclaration, TypeInfo_Class) _published;
    // Guarded by the compiler lock (`build`).
    private TypeInfo_Class[ClassDeclaration] _pending;
    private size_t _depth;

    // A complete entry, or null.
    public TypeInfo_Class* find(ClassDeclaration declaration) {
        return declaration in _published;
    }

    // Runs `make` under the compiler lock and returns its result.
    //
    // Not a lock of this cache's own: `make` takes the compiler lock
    // (a callback entry, `CallbackBridge.entryOf`; a method's semantic),
    // and `RuntimeTypes.get` calls `build` with the compiler lock held.
    // A second lock would be taken in both orders, and two threads, one
    // in each, would wait for each other forever. The compiler lock is
    // recursive: `classRuntimeInfo` reaches `build` again, on the same
    // thread, for a base class or an interface.
    public TypeInfo_Class build(
        scope TypeInfo_Class delegate() make,
    ) {
        import snakebite.frontend.compiler: withCompilerLock;

        TypeInfo_Class info;
        withCompilerLock({
            ++_depth;
            scope(exit) --_depth;
            // A partial entry `make` registered (`classRuntimeInfo`
            // registers before it resolves methods and fields, so a
            // class that reaches itself finds it) must not survive a
            // throw out of the outermost construction: a later `in`
            // would then hand back an object whose vtable and fields
            // were never filled in (finding 2.6).
            scope (failure)
                if (_depth == 1)
                    _pending = null;
            info = make();
            if (_depth == 1)
                publish;
        });
        return info;
    }

    public TypeInfo_Class* opBinaryRight(string op: "in")(
        ClassDeclaration declaration,
    ) {
        if (auto pending = declaration in _pending)
            return pending;
        return find(declaration);
    }

    public void opIndexAssign(
        TypeInfo_Class info, ClassDeclaration declaration,
    ) {
        _pending[declaration] = info;
    }

    private void publish() {
        foreach (declaration, info; _pending)
            _published.insert(declaration, info);
        _pending = null;
    }
}

public TypeInfo_Class classRuntimeInfo(
    imported!"dmd.dclass".ClassDeclaration declaration,
    ref ClassRuntimeCache cache,
    Hooks hooks,
) {
    import dmd.root.string: toDString;
    import dmd.common.blake3: blake3;

    if (auto cached = declaration in cache)
        return *cached;
    if (auto linked = hooks.linkedClassInfo(declaration)) {
        cache[declaration] = linked;
        return linked;
    }

    auto info = new TypeInfo_Class;
    import dmd.astenums: STC;
    import dmd.dsymbolsem: hasPointers, isAbstract;

    const isInterface = declaration.isInterfaceDeclaration !is null;
    // Same flags as `glue/toobj.d`: a class and an interface differ.
    with (TypeInfo_Class.ClassFlags) {
        info.m_flags = cast(TypeInfo_Class.ClassFlags)(
            hasOffTi | hasTypeInfo | hasNameSig);
        if (declaration.isCOMclass)
            info.m_flags |= isCOMclass;
        if (!isInterface) {
            info.m_flags |= hasGetMembers;
            if (declaration.isCPPclass)
                info.m_flags |= isCPPclass;
            if (declaration.ctor !is null)
                info.m_flags |= hasCtor;
            if (declaration.isAbstract)
                info.m_flags |= isAbstract;
        }
    }
    info.name = cast(string) declaration.toPrettyChars.toDString;
    info.nameSig = *cast(uint[4]*) blake3(
        cast(const(ubyte)[]) info.name,
    )[0 .. 16].ptr;
    if (!isInterface) {
        for (auto parent = declaration; parent !is null;
                parent = parent.baseClass)
            ++info.depth;
        bool hasPointerData;
        for (auto parent = declaration; parent !is null;
                parent = parent.baseClass)
            foreach (field; parent.fields)
                hasPointerData |= hasPointers(field);
        if (!hasPointerData)
            info.m_flags |= TypeInfo_Class.ClassFlags.noPointers;
    }
    info.m_RTInfo = hooks.rtInfo(declaration);
    for (auto parent = declaration; parent !is null;
            parent = parent.baseClass)
        if (parent.dtor !is null) {
            info.m_flags |= TypeInfo_Class.ClassFlags.hasDtor;
            break;
        }
    // Compiling a method can read this class's initializer recursively.
    // Reserve its final storage before publishing the incomplete metadata.
    if (declaration.isInterfaceDeclaration is null) {
        info.m_init = cast(byte[]) new void[declaration.structsize];
        info.m_init[] = 0;
    }
    // Register before resolving methods: their bodies can refer to this
    // same class while its metadata is being built.
    cache[declaration] = info;
    if (hooks.registerGenerated !is null)
        hooks.registerGenerated(declaration, info);

    if (!isInterface && declaration.baseClass !is null)
        info.base = classRuntimeInfo(declaration.baseClass, cache, hooks);

    // An interface's methods live in the `Interface` tables of the classes
    // that implement it, not in its own `TypeInfo_Class`.
    const baseLength = info.base is null ? 0 : info.base.vtbl.length;
    const length = isInterface ? 0
        : declaration.vtbl.length > baseLength
            ? declaration.vtbl.length : baseLength;
    info.vtbl = new void*[length];
    if (info.base !is null)
        info.vtbl[0 .. baseLength] = info.base.vtbl[];
    // An `extern(C++)` class has no classinfo slot: its first virtual
    // method is at index 0.
    const firstMethod = declaration.vtblOffset;
    if (firstMethod && !isInterface)
        info.vtbl[0] = cast(void*) info;

    if (!isInterface) {
        if (declaration.defaultCtor !is null
                && !(declaration.defaultCtor.storage_class & STC.disable))
            info.defaultConstructor = cast(void function(Object))
                hooks.methodAddress(declaration.defaultCtor, 0);
        if (declaration.tidtor !is null)
            info.destructor = hooks.methodAddress(declaration.tidtor, 0);
        // Real compiled D (`glue/toobj.d`'s `ClassInfoToDt`) sets this
        // class's own `classInvariant` slot to `cd.inv`'s own compiled
        // address directly - the merged invariant `funcsem.addInvariant`
        // already builds for this class alone, called with `this` the
        // same way any other member function is. `_d_invariant`
        // (`rt.invariant_`) is what walks `.base` to reach every other
        // class in the hierarchy's own slot in turn; this only fills the
        // one level `declaration` itself owns.
        if (declaration.inv !is null)
            info.classInvariant = cast(void function(Object))
                hooks.methodAddress(declaration.inv, 0);
        foreach (i; firstMethod .. declaration.vtbl.length) {
            auto method = declaration.vtbl[i].isFuncDeclaration;
            import dmd.dsymbolsem: isAbstract;

            // DMD leaves bodyless slots empty in an abstract class,
            // even when the method itself has no abstract attribute.
            if (method !is null && method.fbody is null
                    && declaration.isAbstract) {
                info.vtbl[i] = null;
                continue;
            }
            if (method !is null)
                info.vtbl[i] = hooks.methodAddress(method, 0);
        }
        // An opaque class has no size, so its initialiser has no slots.
        if (info.m_init.length != 0) {
            if (info.base !is null)
                info.m_init[0 .. info.base.m_init.length] =
                    info.base.m_init[];
            *cast(void**) info.m_init.ptr = info.vtbl.ptr;
            hooks.fillFieldInits(declaration, cast(ubyte*) info.m_init.ptr);
        }
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
