module snakebite.language.statics.classinfo;


private:


import dmd.aggregate: AggregateDeclaration;
import dmd.dclass: ClassDeclaration;
import dmd.expression: Expression;
import dmd.func: FuncDeclaration;
import object: Interface, TypeInfo_Class;
import snakebite.language.statics.data: NativeData;
import snakebite.native.value: TypeFacts;


// Callable addresses and field initializers differ between backends.
// Object layout and DMD's resolved vtables do not.
public struct Hooks {
    public void* delegate(FuncDeclaration method, ptrdiff_t adjustment)
        methodAddress;
    public TypeInfo_Class delegate(ClassDeclaration declaration)
        linkedClassInfo;
    public immutable(void)* delegate(AggregateDeclaration declaration) rtInfo;
    public void delegate(ClassDeclaration declaration, TypeInfo_Class info)
        registerGenerated;
    // The type data are data of the program: this reserves them and writes
    // each address in them.
    public NativeData* data;
}

// How many pointers `typeid(object)` follows from the object reference
// to its class information: the reference to the vtable, the vtable to
// the information. The vtable of an object of an interface type has the
// interface's own information in between.
public size_t typeidLoadCount(Expression object) {
    import dmd.typesem: toBasetype;

    return 2
        + (object.type.toBasetype.isTypeClass.sym
            .isInterfaceDeclaration !is null);
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

    import snakebite.host.sharedtable: SharedTable;

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
    import snakebite.frontend.dmd.functions: prettyNameOf;

    if (auto cached = declaration in cache)
        return *cached;
    if (auto linked = hooks.linkedClassInfo(declaration)) {
        cache[declaration] = linked;
        return linked;
    }

    auto data = hooks.data;
    auto info = data.newObject!TypeInfo_Class(declaration);
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
    data.storeString(&info.name, prettyNameOf(declaration).toDString);
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
    data.storeReference(&info.m_RTInfo, hooks.rtInfo(declaration));
    for (auto parent = declaration; parent !is null;
            parent = parent.baseClass)
        if (parent.dtor !is null) {
            info.m_flags |= TypeInfo_Class.ClassFlags.hasDtor;
            break;
        }
    // Compiling a method can read this class's initializer recursively.
    // Reserve its final storage before publishing the incomplete metadata.
    if (declaration.isInterfaceDeclaration is null && declaration.structsize != 0) {
        const alignment = declaration.alignsize == 0
            ? 1 : declaration.alignsize;
        data.storeSlice(&info.m_init, data.reserve(
            TypeFacts(declaration.structsize, alignment), declaration));
    }
    // Register before resolving methods: their bodies can refer to this
    // same class while its metadata is being built.
    cache[declaration] = info;
    if (hooks.registerGenerated !is null)
        hooks.registerGenerated(declaration, info);

    if (!isInterface && declaration.baseClass !is null)
        data.storeReference(cast(void*) &info.base,
            cast(void*) classRuntimeInfo(declaration.baseClass, cache, hooks));

    // An interface's methods live in the `Interface` tables of the classes
    // that implement it, not in its own `TypeInfo_Class`.
    const baseLength = info.base is null ? 0 : info.base.vtbl.length;
    const length = isInterface ? 0
        : declaration.vtbl.length > baseLength
            ? declaration.vtbl.length : baseLength;
    if (length != 0)
        data.storeSlice(&info.vtbl, data.reserve(
            TypeFacts(length * (void*).sizeof, (void*).alignof),
            declaration), (void*).sizeof);
    // An `extern(C++)` class has no classinfo slot: its first virtual
    // method is at index 0.
    const firstMethod = declaration.vtblOffset;
    foreach (i; firstMethod .. baseLength)
        data.storeFunction(&info.vtbl[i], info.base.vtbl[i]);
    if (firstMethod && !isInterface)
        data.storeReference(&info.vtbl[0], cast(void*) info);

    if (!isInterface) {
        if (declaration.defaultCtor !is null
                && !(declaration.defaultCtor.storage_class & STC.disable))
            data.storeFunction(&info.defaultConstructor,
                hooks.methodAddress(declaration.defaultCtor, 0));
        if (declaration.tidtor !is null)
            data.storeFunction(&info.destructor,
                hooks.methodAddress(declaration.tidtor, 0));
        // Real compiled D (`glue/toobj.d`'s `ClassInfoToDt`) sets this
        // class's own `classInvariant` slot to `cd.inv`'s own compiled
        // address directly - the merged invariant `funcsem.addInvariant`
        // already builds for this class alone, called with `this` the
        // same way any other member function is. `_d_invariant`
        // (`rt.invariant_`) is what walks `.base` to reach every other
        // class in the hierarchy's own slot in turn; this only fills the
        // one level `declaration` itself owns.
        if (declaration.inv !is null)
            data.storeFunction(&info.classInvariant,
                hooks.methodAddress(declaration.inv, 0));
        foreach (i; firstMethod .. declaration.vtbl.length) {
            auto method = declaration.vtbl[i].isFuncDeclaration;
            import dmd.dsymbolsem: isAbstract;

            // DMD leaves bodyless slots empty in an abstract class,
            // even when the method itself has no abstract attribute.
            if (method !is null && method.fbody is null
                    && declaration.isAbstract) {
                data.storeFunction(&info.vtbl[i], null);
                continue;
            }
            if (method !is null)
                data.storeFunction(&info.vtbl[i],
                    hooks.methodAddress(method, 0));
        }
        // An opaque class has no size, so its initialiser has no slots.
        if (info.m_init.length != 0) {
            if (info.base !is null) {
                data.copyClassImage(info.m_init.ptr, info.base);
                // The fields of a base of the host take their values from the
                // declarations, as the fields of this class do.
                if (data.isHostClass(info.base))
                    for (auto parent = declaration.baseClass;
                            parent !is null; parent = parent.baseClass)
                        data.fillFields(parent, cast(ubyte*) info.m_init.ptr);
            }
            data.storeReference(info.m_init.ptr, info.vtbl.ptr);
            data.fillFields(declaration, cast(ubyte*) info.m_init.ptr);
        }
    }

    const interfaceCount = declaration.vtblInterfaces.length;
    if (interfaceCount != 0)
        data.storeSlice(&info.interfaces, data.reserve(
            TypeFacts(interfaceCount * Interface.sizeof, (void*).alignof),
            declaration), Interface.sizeof);
    foreach (i; 0 .. interfaceCount) {
        auto base = (*declaration.vtblInterfaces)[i];
        data.storeReference(cast(void*) &info.interfaces[i].classinfo,
            cast(void*) classRuntimeInfo(base.sym, cache, hooks));
        info.interfaces[i].offset = base.offset;
        if (!isInterface) {
            auto table = _interfaceVtable(
                declaration, base, &info.interfaces[i], hooks);
            data.storeSlice(&info.interfaces[i].vtbl, table, (void*).sizeof);
            data.storeReference(info.m_init.ptr + base.offset, table.ptr);
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
                data.storeReference(info.m_init.ptr + base.offset, table.ptr);
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
    if (methods.length == 0)
        return null;
    auto data = hooks.data;
    auto table = cast(void*[]) data.reserve(
        TypeFacts(methods.length * (void*).sizeof, (void*).alignof),
        declaration).bytes;
    const first = base.sym.vtblOffset;
    if (first)
        data.storeReference(&table[0], descriptor);
    foreach (i; first .. methods.length) {
        auto method = methods[i];
        if (method is null)
            continue;
        const adjustment = -cast(ptrdiff_t) base.offset
            + (method.interfaceVirtual is null
                ? 0 : method.interfaceVirtual.offset);
        data.storeFunction(&table[i], hooks.methodAddress(method, adjustment));
    }
    return table;
}
