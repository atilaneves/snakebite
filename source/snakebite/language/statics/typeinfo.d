module snakebite.language.statics.typeinfo;


private:


import snakebite.failure.report: internalFailure;


// The suffixes of the symbols that dmd gives the data of a type: the initial
// image of a class, its vtable, its class information, the class information
// of an interface, and the type information of any other type (with the
// prefix `TypeInfo_` and the mangled name of the type before it).
private enum initSuffix = "6__initZ";
private enum vtableSuffix = "6__vtblZ";
private enum classInfoSuffix = "7__ClassZ";
private enum interfaceInfoSuffix = "11__InterfaceZ";
private enum typeInfoSuffix = initSuffix;


// DMD emits no linked metadata for guest declarations. Keep their fallback
// metadata and its identity for the backend's lifetime, while reusing real
// host metadata whenever it is available.
public struct RuntimeTypes {
    // Holds `SharedTable`s (finding 2.4): a copy would share their
    // storage with the original until one side grows.
    @disable this(this);

    import snakebite.frontend.ast: AggregateDeclaration, ClassDeclaration,
        Declaration, Dsymbol, EnumDeclaration, FuncDeclaration,
        StructDeclaration, Type;
    import object:
        TypeInfo, TypeInfo_Class, TypeInfo_Interface, TypeInfo_Struct;
    import snakebite.ffi.callplanstore: CallPlanStore;
    import snakebite.language.definition: Definition;
    import snakebite.ffi.names: Linked, Name;
    import snakebite.host.sharedtable: SharedTable;
    import snakebite.language.statics.data: NativeData;
    import snakebite.native.value: TypeFacts;

    private Definition delegate(Dsymbol) const _whereDefined;
    private Linked!TypeInfo_Class _throwableInfo;
    private Linked!(void*) delegate(FuncDeclaration, ptrdiff_t) _methodAddress;
    private Linked!TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private NativeData* _data;
    // Read without a lock by every thread that runs guest code
    // (ADR-0006); an entry is built once, under the compiler lock.
    private SharedTable!(Type, Linked!TypeInfo) _types;
    private SharedTable!(StructDeclaration, TypeInfo_Struct) _structs;
    // The name of the class information that only another object defines,
    // or null, and whether the program and another object can both define
    // it (`hasOwnCopy`): for each class, decided once.
    private static struct LinkedClass {
        Linked!TypeInfo_Class name;
        bool ownCopy;
    }
    private SharedTable!(ClassDeclaration, LinkedClass) _linkedClasses;
    // The `__init` and the `__vtbl` symbol of each native class that asked.
    private SharedTable!(ClassDeclaration, Name*) _nativeImages;
    private SharedTable!(ClassDeclaration, Name*) _nativeVtables;
    // The structs that `buildStructInfo` is filling. Read and written under
    // the compiler lock only.
    private TypeInfo_Struct[StructDeclaration] _building;

    private CallPlanStore* plans() {
        return _data.planStore;
    }

    // `whereDefined` is the owning `Program`'s own decision
    // (`Program.whereDefined`), not a copy of its root module list: a
    // guest class or struct's `TypeInfo` and a guest function's call
    // target ask the one question "where is `declaration` defined" the same
    // way.
    public this(
        Definition delegate(Dsymbol) const whereDefined,
        Linked!(void*) delegate(FuncDeclaration, ptrdiff_t) methodAddress,
        Linked!TypeInfo_Class delegate(ClassDeclaration) classInfo,
        NativeData* data,
    ) {
        _whereDefined = whereDefined;
        enum throwable = "_D" ~ Throwable.mangleof[1 .. $] ~ "7__ClassZ";
        _methodAddress = methodAddress;
        _classInfo = classInfo;
        _data = data;
        // A `TypeInfo` or a class information that another object holds is
        // the name of its symbol (`snakebite.ffi.names`): the compile reads
        // no memory there.
        _throwableInfo = Linked!TypeInfo_Class.named(
            plans.names.named(throwable));
    }

    public Linked!(const(void)[]) initializer(
        AggregateDeclaration declaration,
    ) {
        // A class variable defaults to null; its instance initializer
        // instead includes the header and the default field values.
        if (auto classDeclaration = declaration.isClassDeclaration)
            return classInitializer(classDeclaration);
        // One image per struct, shared with `typeid(S).initializer`.
        return Linked!(const(void)[]).held(
            structInfo(declaration.isStructDeclaration).m_init);
    }

    // The initial image of an object of `declaration`. The object that holds
    // the class information of a class holds its image too: for a native
    // class it is the name of its `__init` symbol, with the size from the
    // declaration. A word of the program that refers to it is made ready to
    // run like any other; code that reads the bytes as it runs asks
    // `CallPlanStore.ready` for them.
    private Linked!(const(void)[]) classInitializer(
        ClassDeclaration declaration,
    ) {
        if (!isNativeClass(declaration))
            return Linked!(const(void)[]).held(
                _classInfo(declaration).held.m_init);
        return Linked!(const(void)[]).named(nativeClassSymbol(
            _nativeImages, declaration, initSuffix), declaration.structsize);
    }

    // The class information of `declaration`: native, or built by the
    // program.
    public Linked!TypeInfo_Class classInfo(ClassDeclaration declaration) {
        return _classInfo(declaration);
    }

    // Whether another object holds the class information of `declaration`,
    // and with it its vtable and its initial image.
    public bool isNativeClass(ClassDeclaration declaration) {
        return !linkedClassInfo(declaration).isNull;
    }

    // The name of the vtable of the native class `declaration`.
    public Linked!(const(void)*) nativeVtable(ClassDeclaration declaration) {
        return Linked!(const(void)*).named(nativeClassSymbol(
            _nativeVtables, declaration, vtableSuffix));
    }

    // The name of the datum `suffix` of the native class `declaration`, made
    // once for each class and kept in `table`.
    private Name* nativeClassSymbol(
        ref SharedTable!(ClassDeclaration, Name*) table,
        ClassDeclaration declaration, in string suffix,
    ) {
        import snakebite.frontend.compiler: withCompilerLock;

        if (auto found = declaration in table)
            return *found;

        Name* name;
        withCompilerLock({
            name = *table.insert(declaration, plans.names.named(
                classSymbol(declaration, suffix), 0, declaration.toString));
        });
        return name;
    }

    // What the `m_RTInfo` of `declaration` holds: a flag below a page, or
    // the type information that dmd makes for it.
    public Linked!(immutable(void)*) rtInfo(AggregateDeclaration declaration) {
        alias Info = Linked!(immutable(void)*);

        import snakebite.frontend.ast: OutBuffer;
        import snakebite.frontend.compiler: inFrontend;

        bool hasPointerData() {
            if (auto classDeclaration = declaration.isClassDeclaration) {
                for (auto parent = classDeclaration; parent !is null;
                        parent = parent.baseClass)
                    foreach (field; parent.fields)
                        if (inFrontend!"hasPointers"(field))
                            return true;
                return false;
            }
            return inFrontend!"hasPointers"(declaration.type);
        }

        // The type information that dmd makes for a type is a variable of a
        // template instance, which the program and another object can both
        // define: its name, with the program's own copy.
        Info resolve(Declaration symbol, ptrdiff_t offset) {
            auto variable = symbol.isVarDeclaration;
            if (variable is null)
                return Info.init;
            return Info.named(plans.names.further(
                _data.storageNameWithOwnCopy(variable), offset));
        }

        Info flag(in size_t value) {
            return Info.held(cast(immutable(void)*) value);
        }

        auto expression = declaration.getRTInfo;
        if (expression is null)
            return flag(hasPointerData ? 1 : 0);
        if (auto symbol = expression.isSymOffExp) {
            auto info = resolve(symbol.var, cast(ptrdiff_t) symbol.offset);
            if (!info.isNull)
                return info;
        }
        if (auto address = expression.isAddrExp) {
            if (auto variable = address.e1.isVarExp) {
                auto info = resolve(variable.var, 0);
                if (!info.isNull)
                    return info;
            }
            if (auto symbol = address.e1.isSymOffExp) {
                auto info = resolve(symbol.var, cast(ptrdiff_t) symbol.offset);
                if (!info.isNull)
                    return info;
            }
        }
        if (auto integer = expression.isIntegerExp)
            return flag(integer.getInteger);
        if (expression.isNullExp)
            return Info.init;
        return flag(hasPointerData ? 1 : 0);
    }

    // `_types` caches by `Type` identity, not only for a struct, class or
    // enum's own `TypeInfo` - `build`'s `TypeTuple`, array and qualified
    // (`const`/`shared`/...) branches below are covered by this same
    // cache too, since they only ever run once per `Type` before their
    // result lands in `_types` here. This matters for an `extern(D)`
    // untyped variadic call site's own hidden `_arguments` (issue #334
    // step 6): dmd's frontend builds one `TypeTuple` `Type` per call
    // site, reused - the same object, not merely an equal one - on every
    // execution of that site's `TypeidExp`, so `get` allocates a fresh
    // `TypeInfo_Tuple` (and, for a `string` element, a fresh qualified
    // wrapper) only the first time a given call site's `_arguments` is
    // ever evaluated, never again after (verified: `core.memory.GC.
    // allocatedInCurrentThread` is flat across 100 repeat calls of the
    // same `extern(D)` untyped variadic call site, both an all-`int`
    // tuple and a `string`-element one).
    public Linked!TypeInfo get(Type type) {
        if (auto cached = type in _types)
            return *cached;

        import snakebite.frontend.compiler: inFrontend, withCompilerLock;

        Linked!TypeInfo info;
        withCompilerLock({
            // The frontend's argument classifier can return unmerged types.
            // TypeInfo identity follows genTypeInfo's canonical type.
            type = inFrontend!"merge2"(type);
            if (auto cached = type in _types)
                info = *cached;
            else
                info = *_types.insert(type, build(type));
        });
        return info;
    }

    // The class information of `Throwable`, which druntime defines, as the
    // name of its symbol.
    public Linked!TypeInfo_Class throwableInfo() {
        return _throwableInfo;
    }

    // The `TypeInfo_Class` a `catch` clause matches by. A clause matches on
    // the class alone, so `const`, `immutable`, `shared` and `inout`
    // spellings of the class name stand for the same class, whereas `get`
    // answers a qualified type with a qualifier wrapper around it.
    public Linked!TypeInfo_Class unqualifiedClassInfo(Type declared) {
        import snakebite.frontend.typefacts: baseType;

        auto classType = baseType(declared).isTypeClass;
        if (classType is null)
            internalFailure("a class type has a class type once its qualifiers go");
        if (classType.sym.isInterfaceDeclaration !is null)
            internalFailure("the runtime type of a class is a `TypeInfo_Class`");

        return _classInfo(classType.sym);
    }

    private Linked!TypeInfo build(Type type) {
        import snakebite.frontend.ast: toDString;
        import snakebite.frontend.compiler: inFrontend;

        // dmd emits no type information that druntime defines
        // (`builtinTypeInfo`): only druntime defines it.
        if (inFrontend!"builtinTypeInfo"(type))
            return druntimeTypeInfo(type.deco.toDString);
        auto own = ownInfo(type);
        if (isRootOwned(type) || own.name !is null || type.vtinfo is null)
            return own;
        // dmd emits this type information in each object that needs it, so
        // the program and another object can both define it: its name, with
        // the program's own copy.
        const start = cast(const(void)*) own.held;
        return Linked!TypeInfo.named(_data.namedWithOwnCopy(
            type.vtinfo.ident.toString,
            string.init,
            start,
        ));
    }

    // Whether `type` is a struct, an enum or a class that only the root
    // modules define. dmd emits the type information of such a type in the
    // object of the module that declares it.
    private bool isRootOwned(Type type) const {
        Dsymbol declaration;
        if (auto classType = type.isTypeClass)
            declaration = classType.sym;
        else if (auto structType = type.isTypeStruct)
            declaration = structType.sym;
        else if (auto enumType = type.isTypeEnum)
            declaration = enumType.sym;
        if (declaration is null)
            return false;
        final switch (_whereDefined(declaration)) with (Definition) {
            case rootOwned:
                return true;
            case rootOrElsewhere:
            case definedElsewhere:
                return false;
        }
    }

    // The type information of `type` that the program builds, or for a class
    // the one that `_classInfo` decides.
    private Linked!TypeInfo ownInfo(Type type) {
        import snakebite.frontend.ast: nextOf, Taarray, Tarray, Tbool, Tchar,
            Tclass, Tcomplex32, Tcomplex64, Tcomplex80, Tdchar, Tdelegate,
            Tenum, Terror, Tfloat32, Tfloat64, Tfloat80, Tfunction, Tident,
            Timaginary32, Timaginary64, Timaginary80, Tinstance, Tint128,
            Tint16, Tint32, Tint64, Tint8, Tmixin, Tnone, Tnoreturn, Tnull,
            toDString, Tpointer, Treference, Treturn, Tsarray, Tslice, Tstruct,
            Ttag, Ttraits, Ttuple, Ttypeof, Tuns128, Tuns16, Tuns32, Tuns64,
            Tuns8, Tvector, Tvoid, Twchar;
        import snakebite.frontend.compiler: inFrontend;
        import object: TypeInfo_Array, TypeInfo_AssociativeArray,
            TypeInfo_Const, TypeInfo_Delegate, TypeInfo_Enum,
            TypeInfo_Function, TypeInfo_Inout,
            TypeInfo_Invariant, TypeInfo_Pointer, TypeInfo_Shared,
            TypeInfo_StaticArray, TypeInfo_Tuple, TypeInfo_Vector;

        auto classType = type.isTypeClass;
        auto structType = type.isTypeStruct;
        if (type.mod != 0) {
            auto baseType = type.isShared
                ? inFrontend!"unSharedOf"(type)
                : inFrontend!"mutableOf"(type);
            return qualified(type, get(baseType));
        }

        TypeInfo info;
        if (classType !is null) {
            auto classInfo = _classInfo(classType.sym);
            if (classType.sym.isInterfaceDeclaration is null)
                return Linked!TypeInfo.from(classInfo);
            auto interfaceInfo =
                _data.newObject!TypeInfo_Interface(classType.sym);
            _data.storeReference(cast(void*) &interfaceInfo.info, classInfo);
            info = interfaceInfo;
        }
        else if (structType !is null)
            info = structInfo(structType.sym);
        else if (auto enumType = type.isTypeEnum)
            info = enumInfo(enumType.sym);
        else if (auto functionType = type.isTypeFunction) {
            auto functionInfo = _data.newObject!TypeInfo_Function;
            reference(&functionInfo.next, get(functionType.next));
            _data.storeString(&functionInfo.deco, type.deco.toDString);
            info = functionInfo;
        }
        else if (auto delegateType = type.isTypeDelegate) {
            auto delegateInfo = _data.newObject!TypeInfo_Delegate;
            reference(&delegateInfo.next, get(delegateType.next.nextOf));
            _data.storeString(&delegateInfo.deco, type.deco.toDString);
            info = delegateInfo;
        }
        else if (auto pointer = type.isTypePointer) {
            auto pointerInfo = _data.newObject!TypeInfo_Pointer;
            reference(&pointerInfo.m_next, get(pointer.next));
            info = pointerInfo;
        }
        else if (auto staticArray = type.isTypeSArray) {
            auto staticArrayInfo = _data.newObject!TypeInfo_StaticArray;
            reference(&staticArrayInfo.value, get(staticArray.next));
            staticArrayInfo.len = staticArray.dim.isIntegerExp.getInteger;
            info = staticArrayInfo;
        }
        else if (auto associativeArray = type.isTypeAArray) {
            auto associativeArrayInfo =
                _data.newObject!TypeInfo_AssociativeArray;
            reference(&associativeArrayInfo.key, get(associativeArray.index));
            reference(&associativeArrayInfo.value, get(associativeArray.next));
            info = associativeArrayInfo;
        }
        else if (auto vector = type.isTypeVector) {
            auto vectorInfo = _data.newObject!TypeInfo_Vector;
            reference(&vectorInfo.base, get(vector.basetype));
            info = vectorInfo;
        }
        else if (auto tuple = type.isTypeTuple) {
            auto tupleInfo = _data.newObject!TypeInfo_Tuple;
            const count = tuple.arguments.length;
            if (count != 0) {
                auto elements = _data.reserve(
                    TypeFacts(count * (void*).sizeof, (void*).alignof));
                _data.storeSlice(&tupleInfo.elements, elements, (void*).sizeof);
                foreach (index, argument; *tuple.arguments)
                    reference(&tupleInfo.elements[index],
                        get(argument.type));
            }
            info = tupleInfo;
        }

        if (info is null && type.ty == Tarray) {
            auto arrayInfo = _data.newObject!TypeInfo_Array;
            reference(&arrayInfo.value, get(type.nextOf));
            info = arrayInfo;
        }

        if (info is null) {
            final switch (type.ty) {
                // druntime has none: dmd puts a `TypeInfo` object in each
                // object that needs it (`builtinTypeInfo`), and the program
                // makes its own.
                case Tnoreturn: info = _data.newObject!TypeInfo; break;

                // Semantic rejects `cent`/`ucent`; no other kind here outlives it.
                case Tint128, Tuns128, Treference, Tident, Tnone, Terror,
                    Tinstance, Ttypeof, Tslice, Treturn, Ttraits, Tmixin,
                    Ttag:
                    internalFailure();

                case Tclass, Tstruct, Tenum, Tfunction, Tdelegate,
                    Tpointer, Tsarray, Taarray, Tvector, Ttuple, Tarray:
                    internalFailure();

                // `build` gives these to druntime (`builtinTypeInfo`).
                case Tvoid, Tbool, Tchar, Twchar, Tdchar, Tint8, Tint16,
                    Tint32, Tint64, Tuns8, Tuns16, Tuns32, Tuns64, Tfloat32,
                    Tfloat64, Tfloat80, Timaginary32, Timaginary64,
                    Timaginary80, Tcomplex32, Tcomplex64, Tcomplex80, Tnull:
                    internalFailure();
            }
        }
        return Linked!TypeInfo.held(info);
    }

    // The type information that druntime defines for the type whose mangled
    // name is `mangled`, as the name of its symbol, which dmd gives it
    // (`TypeInfoDeclaration`).
    private Linked!TypeInfo druntimeTypeInfo(in char[] mangled) {
        const symbol = typeInfoSymbol(mangled);
        return Linked!TypeInfo.named(plans.names.named(symbol));
    }

    // The symbol of the type information of the type with the mangled name
    // `mangled`, as dmd names it (`TypeInfoDeclaration`).
    private static string typeInfoSymbol(in char[] mangled) @safe pure nothrow {
        import std.conv: text;

        enum prefix = "TypeInfo_";
        return text(
            "_D",
            prefix.length + mangled.length,
            prefix,
            mangled,
            typeInfoSuffix,
        );
    }

    // The symbol of the class information of `declaration`.
    private static string classInfoSymbol(ClassDeclaration declaration) {
        const suffix = declaration.isInterfaceDeclaration is null
            ? classInfoSuffix
            : interfaceInfoSuffix;
        return classSymbol(declaration, suffix);
    }

    // The symbol of the datum `suffix` of the class `declaration`, as the
    // code generator of dmd names it.
    private static string classSymbol(
        ClassDeclaration declaration, in string suffix,
    ) {
        import snakebite.frontend.ast: OutBuffer;
        import snakebite.frontend.dmd.mangle: completeMangleTargets;
        import snakebite.frontend.compiler: inFrontend;
        import std.conv: text;

        // `declaration` can be a class declared local to a function (nested
        // inside it), whose mangled name recurses through that function's
        // own mangled signature - see `completeMangleTargets`.
        completeMangleTargets(declaration);
        OutBuffer mangled;
        inFrontend!"mangleToBuffer"(declaration, mangled);
        return text("_D", mangled[], suffix);
    }

    private Linked!TypeInfo qualified(Type type, Linked!TypeInfo base) {
        if (type.mod == 0)
            return base;
        TypeInfo_Const wrapper;
        if (type.isShared)
            wrapper = _data.newObject!TypeInfo_Shared;
        else if (type.isImmutable)
            wrapper = _data.newObject!TypeInfo_Invariant;
        else if (type.isWild)
            wrapper = _data.newObject!TypeInfo_Inout;
        else
            wrapper = _data.newObject!TypeInfo_Const;
        reference(&wrapper.base, base);
        return Linked!TypeInfo.held(wrapper);
    }

    // The name of the class information of `declaration`, or null when only
    // the program defines it. Another object defines the class information
    // of a class that another object defines, and a missing symbol for it
    // is an error, as at the link of a native build. The program defines it
    // for a class of its own. The program and another object can both
    // define it for a class of a dependency template instance
    // (`hasOwnCopy`): the name has the program's own copy, which this makes
    // first (`_classInfo`), and with it the program's own vtable and initial
    // image.
    public Linked!TypeInfo_Class linkedClassInfo(
        ClassDeclaration declaration,
    ) {
        auto linked = linkedClass(declaration);
        return linked.ownCopy ? _classInfo(declaration) : linked.name;
    }

    // Whether the program and another object can both define the class
    // information of `declaration`.
    public bool hasOwnCopy(ClassDeclaration declaration) {
        return linkedClass(declaration).ownCopy;
    }

    // The name of the class information of `declaration` when only another
    // object defines it, else null: for the code that makes the program's
    // own (`classinfo.classRuntimeInfo`).
    public Linked!TypeInfo_Class classInfoName(
        ClassDeclaration declaration,
    ) {
        return linkedClass(declaration).name;
    }

    // The name of the class information of `declaration` (`hasOwnCopy`),
    // with `info`, which the program built, as its own copy, and the names
    // of its vtable and its initial image with theirs. Each name has its
    // copy from the step that makes it (`NativeData.namedWithOwnCopy`).
    public Linked!TypeInfo_Class ownClassInfo(
        ClassDeclaration declaration, TypeInfo_Class info,
    ) {
        Name* classInfoName;
        eachClassDatum(
            declaration,
            info,
            (string symbol, const(void)* start, NativeNames* table) {
                // `auto`: `const` makes the `Name*` that the table keeps
                // const.
                auto name = _data.namedWithOwnCopy(
                    symbol,
                    declaration.toString,
                    start,
                );
                if (table is null)
                    classInfoName = name;
                else if (!(declaration in *table))
                    table.insert(declaration, name);
            },
        );
        return Linked!TypeInfo_Class.named(classInfoName);
    }

    // The names of a datum of each native class: `_nativeImages` or
    // `_nativeVtables`.
    private alias NativeNames = SharedTable!(ClassDeclaration, Name*);

    // Calls `visit` for each datum that dmd emits with the class information
    // `info` of `declaration`, with its symbol, its start and the names of
    // that datum of native classes: the initial image and the vtable, which
    // an interface does not have, then the class information, which has no
    // such names (null).
    private void eachClassDatum(Visit)(
        ClassDeclaration declaration,
        TypeInfo_Class info,
        scope Visit visit,
    ) {
        if (info.m_init.ptr !is null)
            visit(
                classSymbol(declaration, initSuffix),
                info.m_init.ptr,
                &_nativeImages,
            );
        if (info.vtbl.ptr !is null)
            visit(
                classSymbol(declaration, vtableSuffix),
                cast(const(void)*) info.vtbl.ptr,
                &_nativeVtables,
            );
        visit(classInfoSymbol(declaration), cast(const(void)*) info, null);
    }

    // Makes the class information of `declaration`, which the object of its
    // module holds (`hasClassInfoInObject`), and, when only the root modules
    // define the class, defines the symbols of the class information, its
    // vtable and its initial image in the SBC file, so that the other SBC
    // files of the program reach them by name (ADR-0021).
    public void makeAndDefineClassInfo(ClassDeclaration declaration) {
        import std.typecons: No;

        if (_whereDefined(declaration) != Definition.rootOwned)
            return;
        eachClassDatum(
            declaration,
            _classInfo(declaration).held,
            (string symbol, const(void)* start, NativeNames* table) {
                _data.defineSymbol(symbol, start, No.weak);
            },
        );
    }

    // Makes the type information of the struct or the enum `declaration`,
    // which the object of its module holds (`hasTypeInfoInObject`), and,
    // when only the root modules define the type, defines its symbol in the
    // SBC file, so that the other SBC files of the program reach it by name
    // (ADR-0021).
    public void makeAndDefineTypeInfo(Declaration)(Declaration declaration)
    if (is(Declaration == StructDeclaration)
            || is(Declaration == EnumDeclaration)) {
        import snakebite.frontend.ast: toDString;
        import std.typecons: No;

        // `auto`: `isRootOwned` and `get` take a mutable `Type`.
        auto type = declaration.type;
        if (!isRootOwned(type))
            return;
        const info = cast(const(void)*) get(type).held;
        _data.defineSymbol(
            typeInfoSymbol(type.deco.toDString),
            info,
            No.weak,
        );
    }

    // What `linkedClassInfo` needs of `declaration`, decided once.
    private LinkedClass linkedClass(ClassDeclaration declaration) {
        import snakebite.frontend.compiler: withCompilerLock;

        if (auto found = declaration in _linkedClasses)
            return *found;

        LinkedClass linked;
        withCompilerLock({
            if (auto found = declaration in _linkedClasses)
                linked = *found;
            else
                linked = *_linkedClasses.insert(
                    declaration, findLinkedClass(declaration));
        });
        return linked;
    }

    private LinkedClass findLinkedClass(ClassDeclaration declaration) {
        final switch (_whereDefined(declaration)) with (Definition) {
            case definedElsewhere:
                // `auto`: `const` makes the `Name*` that `named` takes const.
                auto symbol = plans.names.named(
                    classInfoSymbol(declaration),
                    0,
                    declaration.toString,
                );
                return LinkedClass(Linked!TypeInfo_Class.named(symbol));
            case rootOwned:
                return LinkedClass.init;
            case rootOrElsewhere:
                return LinkedClass(Linked!TypeInfo_Class.init, true);
        }
    }

    private TypeInfo_Enum enumInfo(EnumDeclaration declaration) {
        import snakebite.frontend.dmd.functions: prettyNameOf;
        auto info = _data.newObject!TypeInfo_Enum(declaration);
        _data.storeString(&info.name, prettyNameOf(declaration));
        // As the glue of dmd: an enum that is only declared has no base type
        // (`enum E;`) and no initial value.
        if (declaration.memtype !is null)
            reference(&info.base, get(declaration.memtype));
        if (declaration.members !is null)
            _data.storeSlice(
                &info.m_init,
                _data.initialValue(declaration.type, declaration.loc).bytes,
            );
        return info;
    }

    // As the compiler's glue does: no bytes for an opaque struct, and a
    // null pointer with the struct length when the default is all zero.
    private void storeStructInit(
        TypeInfo_Struct info, StructDeclaration declaration,
    ) {
        if (declaration.members is null)
            return;
        if (declaration.zeroInit)
            return _data.storeSlice(&info.m_init,
                (cast(byte*) null)[0 .. declaration.structsize]);
        _data.storeSlice(&info.m_init, _data.initialValue(
            declaration.type, declaration.loc).bytes);
    }

    // The word at `place` becomes a reference to `info`.
    private void reference(T)(void* place, Linked!T info) {
        _data.storeReference(place, info);
    }

    // The word at `place` becomes the address of a method of the program.
    private void method(void* place, FuncDeclaration declaration) {
        _data.storeFunction(place, _methodAddress(declaration, 0));
    }

    // `initializer` reaches this without the frontend lock. A thread that
    // does not hold the lock reads only `_structs`, which holds the
    // finished `TypeInfo_Struct`s: the table is safe to read while another
    // thread inserts, and an entry is inserted only once it is complete. A
    // build asks dmd about the struct (`hasPointers`, `argType`), so it
    // runs under the lock.
    private TypeInfo_Struct structInfo(StructDeclaration declaration) {
        import snakebite.frontend.compiler: withCompilerLock;

        if (auto cached = declaration in _structs)
            return *cached;

        TypeInfo_Struct info;
        withCompilerLock({
            if (auto cached = declaration in _structs)
                info = *cached;
            else if (auto building = declaration in _building)
                info = *building;
            else
                info = buildStructInfo(declaration);
        });
        return info;
    }

    // Runs under the compiler lock. The object is in `_building` while it
    // is filled, so that a request for the same struct from the build
    // itself (through `get`) gets the same object. It goes into `_structs`
    // when it is complete.
    private TypeInfo_Struct buildStructInfo(StructDeclaration declaration) {
        import snakebite.frontend.ast: STC, toDString;
        auto info = _data.newObject!TypeInfo_Struct(declaration);
        _building[declaration] = info;
        scope(exit) _building.remove(declaration);
        _data.storeString(&info.mangledName, declaration.type.deco.toDString);
        storeStructInit(info, declaration);
        info.m_align = declaration.alignsize;
        import snakebite.frontend.compiler: inFrontend;
        inFrontend!"semanticTypeInfoMembers"(declaration);
        if (declaration.xhash !is null)
            method(&info.xtoHash, declaration.xhash);
        if (declaration.xeq !is null)
            method(&info.xopEquals, declaration.xeq);
        if (declaration.xcmp !is null)
            method(&info.xopCmp, declaration.xcmp);
        if (auto toString = inFrontend!"search_toString"(declaration))
            method(&info.xtoString, toString);
        if (declaration.tidtor !is null)
            method(&info.xdtor, declaration.tidtor);
        if (declaration.postblit !is null
                && !(declaration.postblit.storage_class & STC.disable))
            method(&info.xpostblit, declaration.postblit);
        // The enum's default value is `hasPointers`, its first member, so a
        // pointer-free struct must have the flags cleared explicitly.
        const hasPointerData = inFrontend!"hasPointers"(declaration.type);
        info.m_flags = hasPointerData
            ? TypeInfo_Struct.StructFlags.hasPointers
            : cast(TypeInfo_Struct.StructFlags) 0;
        _data.storeReference(&info.m_RTInfo, rtInfo(declaration));
        import snakebite.ffi.argumentplan: supported;
        static if (supported) {
            // DMD's TypeInfo glue uses these frontend types, not the call
            // plan's registers: one vector type can span both eightbytes.
            if (auto arg = declaration.argType(0))
                reference(&info.m_arg1, get(arg));
            if (auto arg = declaration.argType(1))
                reference(&info.m_arg2, get(arg));
        }
        return *_structs.insert(declaration, info);
    }
}
