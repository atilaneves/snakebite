module snakebite.backends.runtimetypes;


private:


import snakebite.internalfailure: internalFailure;


// DMD emits no linked metadata for guest declarations. Keep their fallback
// metadata and its identity for the backend's lifetime, while reusing real
// host metadata whenever it is available.
public struct RuntimeTypes {
    // Holds `SharedTable`s (finding 2.4): a copy would share their
    // storage with the original until one side grows.
    @disable this(this);

    import dmd.aggregate: AggregateDeclaration;
    import dmd.dclass: ClassDeclaration;
    import dmd.denum: EnumDeclaration;
    import dmd.location: Loc;
    import dmd.dstruct: StructDeclaration;
    import dmd.dsymbol: Dsymbol;
    import dmd.declaration: Declaration;
    import dmd.expression: Expression;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import object:
        TypeInfo, TypeInfo_Class, TypeInfo_Interface, TypeInfo_Struct;
    import snakebite.sharedtable: SharedTable;

    private bool delegate(Dsymbol) const _isRootOwned;
    private void* delegate(const(char)[]) _resolve;
    private void* delegate(FuncDeclaration, ptrdiff_t) _methodAddress;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private const(void)[] delegate(Type, Loc) _initialValue;
    // Read without a lock by every thread that runs guest code
    // (ADR-0006); an entry is built once, under the compiler lock.
    private SharedTable!(Type, TypeInfo) _types;
    private SharedTable!(StructDeclaration, TypeInfo_Struct) _structs;

    // `isRootOwned` is the owning `Program`'s own decision
    // (`Program.isRootOwned`), not a copy of its root module list: a
    // guest class or struct's `TypeInfo` and a guest function's call
    // target ask the one question "does this program itself declare
    // `declaration`" the same way.
    public this(
        bool delegate(Dsymbol) const isRootOwned,
        void* delegate(const(char)[]) resolve,
        void* delegate(FuncDeclaration, ptrdiff_t) methodAddress,
        TypeInfo_Class delegate(ClassDeclaration) classInfo,
        const(void)[] delegate(Type, Loc) initialValue,
    ) {
        _isRootOwned = isRootOwned;
        _resolve = resolve;
        _methodAddress = methodAddress;
        _classInfo = classInfo;
        _initialValue = initialValue;
    }

    public const(void)[] initializer(
        AggregateDeclaration declaration,
    ) {
        // A class variable defaults to null; its instance initializer
        // instead includes the header and the default field values.
        if (auto classDeclaration = declaration.isClassDeclaration)
            return _classInfo(classDeclaration).m_init;
        // One image per struct, shared with `typeid(S).initializer`.
        return structInfo(declaration.isStructDeclaration).m_init;
    }

    public immutable(void)* rtInfo(AggregateDeclaration declaration) {
        import dmd.common.outbuffer: OutBuffer;
        import dmd.dsymbolsem;
        import dmd.mangle: mangleToBuffer;
        import dmd.typesem: hasPointers;
        import snakebite.frontend.compiler: newInFrontend;

        bool hasPointerData() {
            if (auto classDeclaration = declaration.isClassDeclaration) {
                for (auto parent = classDeclaration; parent !is null;
                        parent = parent.baseClass)
                    foreach (field; parent.fields)
                        if (dmd.dsymbolsem.hasPointers(field))
                            return true;
                return false;
            }
            return declaration.type.hasPointers;
        }

        immutable(void)* resolve(Declaration symbol, ptrdiff_t offset) {
            OutBuffer name;
            newInFrontend!mangleToBuffer(symbol, name);
            auto address = _resolve(name[]);
            return address is null ? null
                : cast(immutable(void)*)(cast(ubyte*) address + offset);
        }

        auto expression = declaration.getRTInfo;
        if (expression is null)
            return cast(immutable(void)*)
                (hasPointerData ? 1 : 0);
        if (auto symbol = expression.isSymOffExp) {
            if (auto info = resolve(
                    symbol.var, cast(ptrdiff_t) symbol.offset))
                return info;
        }
        if (auto address = expression.isAddrExp) {
            if (auto variable = address.e1.isVarExp) {
                if (auto info = resolve(variable.var, 0))
                    return info;
            }
            if (auto symbol = address.e1.isSymOffExp) {
                if (auto info = resolve(
                        symbol.var, cast(ptrdiff_t) symbol.offset))
                    return info;
            }
        }
        if (auto integer = expression.isIntegerExp)
            return cast(immutable(void)*) integer.getInteger;
        if (expression.isNullExp)
            return null;
        return cast(immutable(void)*) (hasPointerData ? 1 : 0);
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
    public TypeInfo get(Type type) {
        if (auto cached = type in _types)
            return *cached;

        import snakebite.frontend.compiler: newInFrontend, withCompilerLock;
        import dmd.typesem: merge2;

        TypeInfo info;
        withCompilerLock({
            // The frontend's argument classifier can return unmerged types.
            // TypeInfo identity follows genTypeInfo's canonical type.
            type = newInFrontend!merge2(type);
            if (auto cached = type in _types)
                info = *cached;
            else
                info = *_types.insert(type, build(type));
        });
        return info;
    }

    // The `TypeInfo_Class` a `catch` clause matches by. A clause matches on
    // the class alone, so `const`, `immutable`, `shared` and `inout`
    // spellings of the class name stand for the same class, whereas `get`
    // answers a qualified type with a qualifier wrapper around it.
    public TypeInfo_Class unqualifiedClassInfo(Type declared) {
        import dmd.astenums: Tclass;
        import dmd.typesem: mutableOf, toBasetype, unSharedOf;

        auto type = declared.toBasetype.mutableOf.unSharedOf;
        if (type.ty != Tclass)
            internalFailure("a class type has a class type once its qualifiers go");

        auto info = cast(TypeInfo_Class) get(type);
        if (info is null)
            internalFailure("the runtime type of a class is a `TypeInfo_Class`");

        return info;
    }

    private TypeInfo build(Type type) {
        import dmd.astenums;
        import dmd.typesem: mutableOf, nextOf, unSharedOf;
        import snakebite.frontend.compiler: newInFrontend;
        import dmd.root.string: toDString;
        import object: TypeInfo_Array, TypeInfo_AssociativeArray,
            TypeInfo_Const, TypeInfo_Delegate, TypeInfo_Enum,
            TypeInfo_Function, TypeInfo_Inout,
            TypeInfo_Invariant, TypeInfo_Pointer, TypeInfo_Shared,
            TypeInfo_StaticArray, TypeInfo_Tuple, TypeInfo_Vector;

        auto classType = type.isTypeClass;
        auto structType = type.isTypeStruct;
        const rootOwned = classType !is null && isRootOwned(classType.sym)
            || structType !is null && isRootOwned(structType.sym);
        if (!rootOwned) {
            auto info = linkedInfo(type);
            if (info !is null)
                return info;
        }
        if (type.mod != 0) {
            auto baseType = type.isShared
                ? newInFrontend!unSharedOf(type)
                : newInFrontend!mutableOf(type);
            return qualified(type, get(baseType));
        }

        TypeInfo info;
        if (classType !is null) {
            auto classInfo = _classInfo(classType.sym);
            if (classType.sym.isInterfaceDeclaration !is null) {
                auto interfaceInfo = new TypeInfo_Interface;
                interfaceInfo.info = classInfo;
                info = interfaceInfo;
            } else
                info = classInfo;
        }
        else if (structType !is null)
            info = structInfo(structType.sym);
        else if (auto enumType = type.isTypeEnum)
            info = enumInfo(enumType.sym);
        else if (auto functionType = type.isTypeFunction) {
            auto functionInfo = new TypeInfo_Function;
            functionInfo.next = get(functionType.next);
            functionInfo.deco = type.deco.toDString.idup;
            info = functionInfo;
        }
        else if (auto delegateType = type.isTypeDelegate) {
            auto delegateInfo = new TypeInfo_Delegate;
            delegateInfo.next = get(delegateType.next.nextOf);
            delegateInfo.deco = type.deco.toDString.idup;
            info = delegateInfo;
        }
        else if (auto pointer = type.isTypePointer) {
            auto pointerInfo = new TypeInfo_Pointer;
            pointerInfo.m_next = get(pointer.next);
            info = pointerInfo;
        }
        else if (auto staticArray = type.isTypeSArray) {
            auto staticArrayInfo = new TypeInfo_StaticArray;
            staticArrayInfo.value = get(staticArray.next);
            staticArrayInfo.len = staticArray.dim.isIntegerExp.getInteger;
            info = staticArrayInfo;
        }
        else if (auto associativeArray = type.isTypeAArray) {
            auto associativeArrayInfo = new TypeInfo_AssociativeArray;
            associativeArrayInfo.key = get(associativeArray.index);
            associativeArrayInfo.value = get(associativeArray.next);
            info = associativeArrayInfo;
        }
        else if (auto vector = type.isTypeVector) {
            auto vectorInfo = new TypeInfo_Vector;
            vectorInfo.base = get(vector.basetype);
            info = vectorInfo;
        }
        else if (auto tuple = type.isTypeTuple) {
            auto tupleInfo = new TypeInfo_Tuple;
            foreach (argument; *tuple.arguments)
                tupleInfo.elements ~= get(argument.type);
            info = tupleInfo;
        }

        if (info is null && type.ty == Tarray) {
            auto arrayInfo = new TypeInfo_Array;
            arrayInfo.value = get(type.nextOf);
            info = arrayInfo;
        }

        if (info is null) {
            final switch (type.ty) {
                case Tvoid: info = typeid(void); break;
                case Tbool: info = typeid(bool); break;
                case Tchar: info = typeid(char); break;
                case Twchar: info = typeid(wchar); break;
                case Tdchar: info = typeid(dchar); break;
                case Tint8: info = typeid(byte); break;
                case Tint16: info = typeid(short); break;
                case Tint32: info = typeid(int); break;
                case Tint64: info = typeid(long); break;
                case Tuns8: info = typeid(ubyte); break;
                case Tuns16: info = typeid(ushort); break;
                case Tuns32: info = typeid(uint); break;
                case Tuns64: info = typeid(ulong); break;
                case Tfloat32: info = typeid(float); break;
                case Tfloat64: info = typeid(double); break;
                case Tfloat80: info = typeid(real); break;
                case Timaginary32: info = typeid(ifloat); break;
                case Timaginary64: info = typeid(idouble); break;
                case Timaginary80: info = typeid(ireal); break;
                case Tcomplex32: info = typeid(cfloat); break;
                case Tcomplex64: info = typeid(cdouble); break;
                case Tcomplex80: info = typeid(creal); break;
                case Tnull: info = typeid(typeof(null)); break;
                case Tnoreturn: info = typeid(noreturn); break;

                // Semantic rejects `cent`/`ucent`; no other kind here outlives it.
                case Tint128, Tuns128, Treference, Tident, Tnone, Terror,
                    Tinstance, Ttypeof, Tslice, Treturn, Ttraits, Tmixin,
                    Ttag:
                    internalFailure();

                case Tclass, Tstruct, Tenum, Tfunction, Tdelegate,
                    Tpointer, Tsarray, Taarray, Tvector, Ttuple, Tarray:
                    internalFailure();
            }
        }
        return info;
    }

    public bool isRootOwned(Dsymbol declaration) const {
        return _isRootOwned(declaration);
    }

    private TypeInfo linkedInfo(Type type) {
        import dmd.common.outbuffer: OutBuffer;
        import dmd.mangle: mangleToBuffer;
        import snakebite.frontend.dmd.mangle: completeMangleTargets;
        import snakebite.frontend.compiler: newInFrontend;
        import std.conv: text;

        if (type.vtinfo is null)
            return null;

        auto name = type.vtinfo.ident.toString;
        auto classType = type.isTypeClass;
        if (classType !is null && type.mod == 0
                && classType.sym.isInterfaceDeclaration is null) {
            // Codegen aliases an unqualified class's TypeInfo declaration
            // to its __Class symbol. The frontend alone leaves the alias
            // unresolved.
            // `classType.sym` can be a class declared local to a function
            // (nested inside it), whose mangled name recurses through that
            // function's own mangled signature - see `completeMangleTargets`.
            completeMangleTargets(classType.sym);
            OutBuffer mangled;
            newInFrontend!mangleToBuffer(classType.sym, mangled);
            name = text("_D", mangled[], "7__ClassZ");
        }
        return cast(TypeInfo) _resolve(name);
    }

    private TypeInfo qualified(Type type, TypeInfo base) {
        if (type.mod == 0)
            return base;
        TypeInfo_Const wrapper;
        if (type.isShared)
            wrapper = new TypeInfo_Shared;
        else if (type.isImmutable)
            wrapper = new TypeInfo_Invariant;
        else if (type.isWild)
            wrapper = new TypeInfo_Inout;
        else
            wrapper = new TypeInfo_Const;
        wrapper.base = base;
        return wrapper;
    }

    // The host's own `TypeInfo_Class` for `declaration`, if one is linked
    // into this process - `null` for a guest class (always fabricated) and
    // for a native class the host never linked. Never falls back to
    // fabrication itself, so a caller that fabricates its own metadata
    // (`classinfo.classRuntimeInfo`) can call this without looping back
    // through that same fabrication path.
    public TypeInfo_Class linkedClassInfo(ClassDeclaration declaration) {
        import dmd.root.string: toDString;

        if (isRootOwned(declaration))
            return null;

        auto linked = linkedInfo(declaration.type);
        if (auto info = cast(TypeInfo_Interface) linked)
            return info.info;
        if (auto info = cast(TypeInfo_Class) linked)
            return info;

        return cast(TypeInfo_Class) TypeInfo_Class.find(
            declaration.toPrettyChars.toDString);
    }

    private TypeInfo_Enum enumInfo(EnumDeclaration declaration) {
        import dmd.root.string: toDString;
        auto info = new TypeInfo_Enum;
        info.name = cast(string) declaration.toPrettyChars.toDString;
        info.base = get(declaration.memtype);
        info.m_init = cast(byte[]) _initialValue(
            declaration.type, declaration.loc,
        ).dup;
        return info;
    }

    // As the compiler's glue does: no bytes for an opaque struct, and a
    // null pointer with the struct length when the default is all zero.
    private byte[] structInit(StructDeclaration declaration) {
        if (declaration.members is null)
            return null;
        if (declaration.zeroInit)
            return (cast(byte*) null)[0 .. declaration.structsize];
        return cast(byte[]) _initialValue(
            declaration.type, declaration.loc,
        ).dup;
    }

    private TypeInfo_Struct structInfo(StructDeclaration declaration) {
        if (auto cached = declaration in _structs)
            return *cached;

        import dmd.root.string: toDString;
        auto info = new TypeInfo_Struct;
        _structs.insert(declaration, info);
        info.mangledName = declaration.type.deco.toDString.idup;
        info.m_init = structInit(declaration);
        info.m_align = declaration.alignsize;
        import dmd.astenums: STC;
        import dmd.semantic3: semanticTypeInfoMembers, search_toString;
        import dmd.typesem: hasPointers;
        import snakebite.frontend.compiler: newInFrontend;
        newInFrontend!semanticTypeInfoMembers(declaration);
        if (declaration.xhash !is null)
            info.xtoHash = cast(typeof(info.xtoHash))
                _methodAddress(declaration.xhash, 0);
        if (declaration.xeq !is null)
            info.xopEquals = cast(typeof(info.xopEquals))
                _methodAddress(declaration.xeq, 0);
        if (declaration.xcmp !is null)
            info.xopCmp = cast(typeof(info.xopCmp))
                _methodAddress(declaration.xcmp, 0);
        if (auto method = newInFrontend!search_toString(declaration))
            info.xtoString = cast(typeof(info.xtoString))
                _methodAddress(method, 0);
        if (declaration.tidtor !is null)
            info.xdtor = cast(typeof(info.xdtor))
                _methodAddress(declaration.tidtor, 0);
        if (declaration.postblit !is null
                && !(declaration.postblit.storage_class & STC.disable))
            info.xpostblit = cast(typeof(info.xpostblit))
                _methodAddress(declaration.postblit, 0);
        const hasPointerData = declaration.type.hasPointers;
        if (hasPointerData)
            info.m_flags = TypeInfo_Struct.StructFlags.hasPointers;
        info.m_RTInfo = rtInfo(declaration);
        import snakebite.ffi.abi: supported;
        static if (supported) {
            // DMD's TypeInfo glue uses these frontend types, not the call
            // plan's registers: one vector type can span both eightbytes.
            if (auto arg = declaration.argType(0))
                info.m_arg1 = get(arg);
            if (auto arg = declaration.argType(1))
                info.m_arg2 = get(arg);
        }
        return info;
    }
}
