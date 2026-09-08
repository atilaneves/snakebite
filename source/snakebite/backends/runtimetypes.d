module snakebite.backends.runtimetypes;


private:


// DMD emits no linked metadata for guest declarations. Keep their fallback
// metadata and its identity for the backend's lifetime, while reusing real
// host metadata whenever it is available.
public struct RuntimeTypes {
    import dmd.dclass: ClassDeclaration;
    import dmd.dmodule: Module;
    import dmd.denum: EnumDeclaration;
    import dmd.location: Loc;
    import dmd.dstruct: StructDeclaration;
    import dmd.dsymbol: Dsymbol;
    import dmd.mtype: Type;
    import snakebite.backends.backend: Program;
    import object: TypeInfo, TypeInfo_Class, TypeInfo_Struct;

    private const(Module)[] _rootModules;
    private void* delegate(const(char)[]) _resolve;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private const(void)[] delegate(Type, Loc) _initialValue;
    private TypeInfo[Type] _types;
    private TypeInfo_Struct[StructDeclaration] _structs;

    public this(
        in Program program,
        void* delegate(const(char)[]) resolve,
        TypeInfo_Class delegate(ClassDeclaration) classInfo,
        const(void)[] delegate(Type, Loc) initialValue,
    ) {
        _rootModules = program.rootModules;
        _resolve = resolve;
        _classInfo = classInfo;
        _initialValue = initialValue;
    }

    public TypeInfo get(Type type) {
        if (auto cached = type in _types)
            return *cached;

        auto info = build(type);
        if (info !is null)
            _types[type] = info;
        return info;
    }

    private TypeInfo build(Type type) {
        import dmd.astenums;
        import dmd.typesem: mutableOf, nextOf, unSharedOf;
        import object: TypeInfo_Array, TypeInfo_AssociativeArray,
            TypeInfo_Const, TypeInfo_Enum, TypeInfo_Inout,
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
                ? type.unSharedOf
                : type.mutableOf;
            return qualified(type, get(baseType));
        }

        TypeInfo info;
        if (classType !is null)
            info = classInfo(classType.sym);
        else if (structType !is null)
            info = structInfo(structType.sym);
        else if (auto enumType = type.isTypeEnum)
            info = enumInfo(enumType.sym);
        else if (auto pointer = type.isTypePointer) {
            auto next = get(pointer.next);
            if (next is null)
                return null;
            auto pointerInfo = new TypeInfo_Pointer;
            pointerInfo.m_next = next;
            info = pointerInfo;
        }
        else if (auto staticArray = type.isTypeSArray) {
            auto element = get(staticArray.next);
            if (element is null)
                return null;
            auto staticArrayInfo = new TypeInfo_StaticArray;
            staticArrayInfo.value = element;
            staticArrayInfo.len = staticArray.dim.isIntegerExp.getInteger;
            info = staticArrayInfo;
        }
        else if (auto associativeArray = type.isTypeAArray) {
            auto key = get(associativeArray.index);
            auto value = get(associativeArray.next);
            if (key is null || value is null)
                return null;
            auto associativeArrayInfo = new TypeInfo_AssociativeArray;
            associativeArrayInfo.key = key;
            associativeArrayInfo.value = value;
            info = associativeArrayInfo;
        }
        else if (auto vector = type.isTypeVector) {
            auto base = get(vector.basetype);
            if (base is null)
                return null;
            auto vectorInfo = new TypeInfo_Vector;
            vectorInfo.base = base;
            info = vectorInfo;
        }
        else if (auto tuple = type.isTypeTuple) {
            auto tupleInfo = new TypeInfo_Tuple;
            foreach (argument; *tuple.arguments)
                tupleInfo.elements ~= get(argument.type);
            info = tupleInfo;
        }

        if (info is null && type.ty == Tarray) {
            auto element = get(type.nextOf);
            if (element is null)
                return null;
            auto arrayInfo = new TypeInfo_Array;
            arrayInfo.value = element;
            info = arrayInfo;
        }

        if (info is null) {
            switch (type.ty) {
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
                default: return null;
            }
        }
        return info;
    }

    public bool isRootOwned(Dsymbol declaration) const {
        const module_ = declaration.getModule;
        foreach (rootModule; _rootModules)
            if (module_ is rootModule)
                return true;
        return false;
    }

    private TypeInfo linkedInfo(Type type) {
        import dmd.common.outbuffer: OutBuffer;
        import dmd.mangle: mangleToBuffer;
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
            OutBuffer mangled;
            mangleToBuffer(classType.sym, mangled);
            name = text("_D", mangled[], "7__ClassZ");
        }
        return cast(TypeInfo) _resolve(name);
    }

    private TypeInfo classInfo(ClassDeclaration declaration) {
        import dmd.root.string: toDString;

        auto base = linkedClassInfo(declaration);
        if (base is null)
            base = _classInfo(declaration);
        return base;
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
    // (`Bytecode.classRuntimeInfo`) can call this without looping back
    // through that same fabrication path.
    public TypeInfo_Class linkedClassInfo(ClassDeclaration declaration) {
        import dmd.root.string: toDString;

        if (isRootOwned(declaration))
            return null;

        if (auto info = cast(TypeInfo_Class) linkedInfo(declaration.type))
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

    private TypeInfo_Struct structInfo(StructDeclaration declaration) {
        if (auto cached = declaration in _structs)
            return *cached;

        import dmd.common.outbuffer: OutBuffer;
        import dmd.mangle: mangleToBuffer;
        auto info = new TypeInfo_Struct;
        OutBuffer mangled;
        mangleToBuffer(declaration, mangled);
        info.mangledName = mangled[].idup;
        info.m_init = cast(byte[]) _initialValue(
            declaration.type, declaration.loc,
        ).dup;
        info.m_align = declaration.alignsize;
        if (declaration.hasPointerField)
            info.m_flags = TypeInfo_Struct.StructFlags.hasPointers;
        _structs[declaration] = info;
        return info;
    }
}
