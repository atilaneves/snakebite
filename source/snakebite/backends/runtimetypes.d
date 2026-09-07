module snakebite.backends.runtimetypes;


private:


// DMD emits no linked metadata for guest declarations. Keep their fallback
// metadata and its identity for the backend's lifetime, while reusing real
// host metadata whenever it is available.
public struct RuntimeTypes {
    import dmd.dclass: ClassDeclaration;
    import dmd.dmodule: Module;
    import dmd.dstruct: StructDeclaration;
    import dmd.dsymbol: Dsymbol;
    import dmd.mtype: Type;
    import snakebite.backends.backend: Program;
    import object: TypeInfo, TypeInfo_Class, TypeInfo_Struct;

    private const(Module)[] _rootModules;
    private void* delegate(const(char)[]) _resolve;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private TypeInfo[Type] _types;
    private TypeInfo_Struct[StructDeclaration] _structs;

    public this(
        in Program program,
        void* delegate(const(char)[]) resolve,
        TypeInfo_Class delegate(ClassDeclaration) classInfo,
    ) {
        _rootModules = program.rootModules;
        _resolve = resolve;
        _classInfo = classInfo;
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
        import dmd.typesem: nextOf;
        import object: TypeInfo_Array;

        auto classType = type.isTypeClass;
        auto structType = type.isTypeStruct;
        const rootOwned = classType !is null && isRootOwned(classType.sym)
            || structType !is null && isRootOwned(structType.sym);
        if (!rootOwned) {
            auto info = linkedInfo(type);
            if (info !is null)
                return info;
        }

        if (classType !is null)
            return classInfo(type, classType.sym);

        if (structType !is null)
            return structInfo(structType.sym);

        if (type.ty == Tarray) {
            auto element = get(type.nextOf);
            if (element is null)
                return null;
            auto info = new TypeInfo_Array;
            info.value = element;
            return info;
        }

        switch (type.ty) {
            case Tbool: return typeid(bool);
            case Tchar: return typeid(char);
            case Twchar: return typeid(wchar);
            case Tdchar: return typeid(dchar);
            case Tint8: return typeid(byte);
            case Tint16: return typeid(short);
            case Tint32: return typeid(int);
            case Tint64: return typeid(long);
            case Tuns8: return typeid(ubyte);
            case Tuns16: return typeid(ushort);
            case Tuns32: return typeid(uint);
            case Tuns64: return typeid(ulong);
            case Tfloat32: return typeid(float);
            case Tfloat64: return typeid(double);
            case Tfloat80: return typeid(real);
            default: return null;
        }
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

    private TypeInfo classInfo(Type type, ClassDeclaration declaration) {
        import dmd.astenums: MODFlags;
        import dmd.root.string: toDString;
        import object: TypeInfo_Const, TypeInfo_Shared;

        TypeInfo_Class base;
        if (!isRootOwned(declaration))
            base = cast(TypeInfo_Class) TypeInfo_Class.find(
                declaration.toPrettyChars.toDString);
        if (base is null)
            base = _classInfo(declaration);
        if (type.mod == 0)
            return base;

        auto wrapper = (type.mod & MODFlags.shared_) != 0
            ? new TypeInfo_Shared : new TypeInfo_Const;
        wrapper.base = base;
        return wrapper;
    }

    private TypeInfo_Struct structInfo(StructDeclaration declaration) {
        if (auto cached = declaration in _structs)
            return *cached;

        auto info = new TypeInfo_Struct;
        info.m_init = new byte[](declaration.structsize);
        info.m_align = declaration.alignsize;
        if (declaration.hasPointerField)
            info.m_flags = TypeInfo_Struct.StructFlags.hasPointers;
        _structs[declaration] = info;
        return info;
    }
}
