module snakebite.language.statics.classinfo;


private:


import snakebite.frontend.ast: AggregateDeclaration, ClassDeclaration,
    Expression, FuncDeclaration;
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
    // Whether another object holds the class information, the vtable and
    // the initial image of a class (`RuntimeTypes.isNativeClass`).
    public bool delegate(ClassDeclaration declaration) isNativeClass;
    // The address of the vtable of a native class.
    public const(void)* delegate(ClassDeclaration declaration) nativeVtable;
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
    import snakebite.frontend.typefacts: baseType;

    return 2
        + (object.type.baseType.isTypeClass.sym
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
        TypeInfo_Class info;
        run({ info = make(); });
        return info;
    }

    // Runs `work`, which can build class information (an initial image
    // does), as `build` runs `make`.
    public void run(scope void delegate() work) {
        import snakebite.frontend.compiler: withCompilerLock;

        withCompilerLock({
            ++_depth;
            scope(exit) --_depth;
            // A partial entry `work` registered (`classRuntimeInfo`
            // registers before it resolves methods and fields, so a
            // class that reaches itself finds it) must not survive a
            // throw out of the outermost construction: a later `in`
            // would then hand back an object whose vtable and fields
            // were never filled in (finding 2.6).
            scope (failure)
                if (_depth == 1)
                    _pending = null;
            work();
            if (_depth == 1)
                publish;
        });
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
    imported!"snakebite.frontend.ast".ClassDeclaration declaration,
    ref ClassRuntimeCache cache,
    Hooks hooks,
) {
    import snakebite.frontend.ast: blake3, hasPointers, isAbstract, STC,
        toDString;
    import snakebite.frontend.dmd.functions: prettyNameOf;

    if (auto cached = declaration in cache)
        return *cached;
    if (auto linked = hooks.linkedClassInfo(declaration)) {
        cache[declaration] = linked;
        return linked;
    }

    auto data = hooks.data;
    auto info = data.newObject!TypeInfo_Class(declaration);

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
    // that implement it, not in its own `TypeInfo_Class`. The vtable has the
    // slots of the bases, so each slot comes from the declaration.
    const length = isInterface ? 0 : declaration.vtbl.length;
    if (length != 0)
        data.storeSlice(&info.vtbl, data.reserve(
            TypeFacts(length * (void*).sizeof, (void*).alignof),
            declaration), (void*).sizeof);
    // An `extern(C++)` class has no classinfo slot: its first virtual
    // method is at index 0.
    const firstMethod = declaration.vtblOffset;
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
            import snakebite.frontend.ast: isAbstract;

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
    }

    // An opaque class has no size, so its initialiser has no slots.
    if (!isInterface && info.m_init.length != 0)
        writeImage(declaration, cast(ubyte*) info.m_init.ptr,
            info.vtbl.ptr, cache, hooks);
    return info;
}

// Writes at `place` the initial image of an object of the class
// `declaration`, of `declaration.structsize` bytes. A class of the program
// has it in its class information. For a native class it comes from the
// declarations, as for a class of the program with a native base: nothing
// reads the memory of a native class.
public void initialImage(
    ClassDeclaration declaration, void* place,
    ref ClassRuntimeCache cache, Hooks hooks,
) {
    if (!hooks.isNativeClass(declaration))
        return hooks.data.copyBytes(place,
            classRuntimeInfo(declaration, cache, hooks).m_init);

    import core.stdc.string: memset;

    memset(place, 0, declaration.structsize);
    writeImage(declaration, cast(ubyte*) place,
        hooks.nativeVtable(declaration), cache, hooks);
}

// The words of the image of `declaration` at `place`, with the vtable
// `vtable`. When `declaration` and its base are classes of the program, the
// part of the bases is a copy of the image of the base. Otherwise each field
// comes from the declarations, and an interface slot of a native class names
// the table of that class (`Target.Kind.interfaceTable`): nothing reads the
// image or the tables of a native class here. A table is made here for the
// interfaces of a class of the program, and for an interface of a base of
// which a class below that base replaces a method.
private void writeImage(
    ClassDeclaration declaration, ubyte* place, in void* vtable,
    ref ClassRuntimeCache cache, Hooks hooks,
) {
    import snakebite.native.address: Target;

    auto data = hooks.data;
    auto base = declaration.baseClass;
    const isNative = hooks.isNativeClass(declaration);
    const copiesBase = base !is null && !isNative
        && !hooks.isNativeClass(base);
    if (copiesBase)
        data.copyBytes(place, classRuntimeInfo(base, cache, hooks).m_init);
    data.storeReference(place, vtable);

    for (auto parent = declaration; parent !is null;
            parent = parent.baseClass) {
        const own = parent is declaration && !isNative;
        if (parent is declaration || !copiesBase)
            data.fillFields(parent, place);
        auto parentInfo = classRuntimeInfo(parent, cache, hooks);
        const parentIsNative = hooks.isNativeClass(parent);
        foreach (i; 0 .. parent.vtblInterfaces.length) {
            auto interface_ = (*parent.vtblInterfaces)[i];
            auto slot = place + interface_.offset;
            if (!own && !replaces(declaration, parent, interface_, copiesBase)) {
                if (!copiesBase)
                    data.storeInterface(slot, Target.Kind.interfaceTable,
                        parentInfo, i);
                continue;
            }
            auto table = _interfaceVtable(declaration, interface_, hooks);
            if (table.length != 0 && interface_.sym.vtblOffset) {
                if (parentIsNative)
                    data.storeInterface(&table[0],
                        Target.Kind.interfaceRecord, parentInfo, i);
                else
                    data.storeReference(&table[0],
                        &parentInfo.interfaces[i]);
            }
            if (own)
                data.storeSlice(&parentInfo.interfaces[i].vtbl, table,
                    (void*).sizeof);
            data.storeReference(slot, table.ptr);
        }
    }
}

// Whether a class from `declaration` down to the class below `parent`
// replaces a method of the interface `interface_` of `parent`, so that the
// object has a table that `parent` does not have. When the image of the base
// is a copy, only `declaration` is asked: the copy holds the tables of the
// bases.
private bool replaces(
    ClassDeclaration declaration, ClassDeclaration parent,
    imported!"snakebite.frontend.ast".BaseClass* interface_,
    in bool copiesBase,
) {
    import snakebite.frontend.ast: fillVtbl;

    for (auto below = declaration; below !is parent;
            below = below.baseClass) {
        if (interface_.fillVtbl(below, null, 0))
            return true;
        if (copiesBase)
            return false;
    }
    return false;
}

private void*[] _interfaceVtable(
    imported!"snakebite.frontend.ast".ClassDeclaration declaration,
    imported!"snakebite.frontend.ast".BaseClass* base,
    Hooks hooks,
) {
    import snakebite.frontend.ast: fillVtbl, FuncDeclarations;

    FuncDeclarations methods;
    base.fillVtbl(declaration, &methods, 0);
    if (methods.length == 0)
        return null;
    auto data = hooks.data;
    auto table = cast(void*[]) data.reserve(
        TypeFacts(methods.length * (void*).sizeof, (void*).alignof),
        declaration).bytes;
    // The first word of the table is the `Interface` record: the caller
    // writes it.
    foreach (i; base.sym.vtblOffset .. methods.length) {
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
