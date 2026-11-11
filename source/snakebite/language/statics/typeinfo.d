module snakebite.language.statics.typeinfo;


private:


import snakebite.failure.report: internalFailure;


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
    import snakebite.host.sharedtable: SharedTable;
    import snakebite.language.statics.data: NativeData;
    import snakebite.native.value: TypeFacts;

    private bool delegate(Dsymbol) const _isRootOwned;
    private void* delegate(const(char)[]) _resolve;
    private void* delegate(FuncDeclaration, ptrdiff_t) _methodAddress;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private NativeData* _data;
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
        NativeData* data,
    ) {
        _isRootOwned = isRootOwned;
        _resolve = resolve;
        _methodAddress = methodAddress;
        _classInfo = classInfo;
        _data = data;
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
                auto interfaceInfo =
                    _data.newObject!TypeInfo_Interface(classType.sym);
                _data.storeReference(cast(void*) &interfaceInfo.info,
                    cast(void*) classInfo);
                info = interfaceInfo;
            } else
                info = classInfo;
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
            wrapper = _data.newObject!TypeInfo_Shared;
        else if (type.isImmutable)
            wrapper = _data.newObject!TypeInfo_Invariant;
        else if (type.isWild)
            wrapper = _data.newObject!TypeInfo_Inout;
        else
            wrapper = _data.newObject!TypeInfo_Const;
        reference(&wrapper.base, base);
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
        import snakebite.frontend.dmd.functions: prettyNameOf;

        if (isRootOwned(declaration))
            return null;

        auto linked = linkedInfo(declaration.type);
        if (auto info = cast(TypeInfo_Interface) linked)
            return info.info;
        if (auto info = cast(TypeInfo_Class) linked)
            return info;

        return cast(TypeInfo_Class) TypeInfo_Class.find(
            prettyNameOf(declaration).toDString);
    }

    private TypeInfo_Enum enumInfo(EnumDeclaration declaration) {
        import dmd.root.string: toDString;
        import snakebite.frontend.dmd.functions: prettyNameOf;
        auto info = _data.newObject!TypeInfo_Enum(declaration);
        _data.storeString(&info.name, prettyNameOf(declaration).toDString);
        reference(&info.base, get(declaration.memtype));
        _data.storeSlice(&info.m_init, _data.initialValue(
            declaration.type, declaration.loc).bytes);
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
    private void reference(void* place, in Object info) {
        _data.storeReference(place, cast(const(void)*) info);
    }

    // The word at `place` becomes the address of a method of the program.
    private void method(void* place, FuncDeclaration declaration) {
        _data.storeFunction(place, _methodAddress(declaration, 0));
    }

    private TypeInfo_Struct structInfo(StructDeclaration declaration) {
        if (auto cached = declaration in _structs)
            return *cached;

        import dmd.root.string: toDString;
        auto info = _data.newObject!TypeInfo_Struct(declaration);
        _structs.insert(declaration, info);
        _data.storeString(&info.mangledName, declaration.type.deco.toDString);
        storeStructInit(info, declaration);
        info.m_align = declaration.alignsize;
        import dmd.astenums: STC;
        import dmd.semantic3: semanticTypeInfoMembers, search_toString;
        import dmd.typesem: hasPointers;
        import snakebite.frontend.compiler: newInFrontend;
        newInFrontend!semanticTypeInfoMembers(declaration);
        if (declaration.xhash !is null)
            method(&info.xtoHash, declaration.xhash);
        if (declaration.xeq !is null)
            method(&info.xopEquals, declaration.xeq);
        if (declaration.xcmp !is null)
            method(&info.xopCmp, declaration.xcmp);
        if (auto toString = newInFrontend!search_toString(declaration))
            method(&info.xtoString, toString);
        if (declaration.tidtor !is null)
            method(&info.xdtor, declaration.tidtor);
        if (declaration.postblit !is null
                && !(declaration.postblit.storage_class & STC.disable))
            method(&info.xpostblit, declaration.postblit);
        // The enum's default value is `hasPointers`, its first member, so a
        // pointer-free struct must have the flags cleared explicitly.
        const hasPointerData = declaration.type.hasPointers;
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
        return info;
    }
}
