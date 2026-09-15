module snakebite.backends.runtimetypes;


private:


// DMD emits no linked metadata for guest declarations. Keep their fallback
// metadata and its identity for the backend's lifetime, while reusing real
// host metadata whenever it is available.
public struct RuntimeTypes {
    import dmd.dclass: ClassDeclaration;
    import dmd.denum: EnumDeclaration;
    import dmd.location: Loc;
    import dmd.dstruct: StructDeclaration;
    import dmd.dsymbol: Dsymbol;
    import dmd.mtype: Type;
    import object: TypeInfo, TypeInfo_Class, TypeInfo_Interface, TypeInfo_Struct;

    private bool delegate(Dsymbol) const _isRootOwned;
    private void* delegate(const(char)[]) _resolve;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private const(void)[] delegate(Type, Loc) _initialValue;
    private TypeInfo[Type] _types;
    private TypeInfo_Struct[StructDeclaration] _structs;

    // `isRootOwned` is the owning `Program`'s own decision
    // (`Program.isRootOwned`), not a copy of its root module list: a
    // guest class or struct's `TypeInfo` and a guest function's call
    // target ask the one question "does this program itself declare
    // `declaration`" the same way.
    public this(
        bool delegate(Dsymbol) const isRootOwned,
        void* delegate(const(char)[]) resolve,
        TypeInfo_Class delegate(ClassDeclaration) classInfo,
        const(void)[] delegate(Type, Loc) initialValue,
    ) {
        _isRootOwned = isRootOwned;
        _resolve = resolve;
        _classInfo = classInfo;
        _initialValue = initialValue;
    }

    public const(void)[] initializer(
        imported!"dmd.aggregate".AggregateDeclaration declaration,
    ) {
        // A class variable defaults to null; its instance initializer
        // instead includes the header and the default field values.
        if (auto classDeclaration = declaration.isClassDeclaration)
            return _classInfo(classDeclaration).m_init;
        return _initialValue(declaration.type, declaration.loc);
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
        return _isRootOwned(declaration);
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
        setSysVArgTypes(info, declaration.type);
        _structs[declaration] = info;
        return info;
    }
}

// A guest struct's fabricated `TypeInfo_Struct` needs its own `m_arg1`/
// `m_arg2` set, the same way the real compiler's own codegen sets them
// for a host-compiled struct (`dmd.glue.todt`'s `visit(
// TypeInfoStructDeclaration)`, reading `StructDeclaration.argType`):
// druntime's own `core.vararg` TypeInfo-driven `va_arg` (`core.internal.
// vararg.sysv_x64`, the one an `extern(D)` untyped variadic callee needs
// to read a runtime-typed extra argument - issue #334 step 6) reads
// these two fields to find which SysV register-save-area eightbyte(s) a
// struct-typed argument occupies. Left unset (null, this class' own
// `.init`), that `va_arg` wrongly assumes the value was always passed in
// memory and reads whatever garbage sits at its own stale `stack_args`
// pointer instead of the real register bytes - verified: a from-scratch
// repro reading a two-`int` struct's `_arguments[0]` this way, with `
// m_arg1`/`m_arg2` left null, reads four bytes of stack garbage instead
// of the struct's own two fields; setting them from this backend's own
// SysV eightbyte classification (`snakebite.ffi.abi.ArgumentPlan`, the
// very same classification `snakebite.ffi.plan.CallPlan` already uses to
// place this same struct into a register when it is the caller) fixes
// it. A MEMORY-class struct needs neither field set: `va_arg`'s own
// "always passed in memory" path, the one it falls back to when `arg1`
// is null, is exactly right for it - reading from `stack_args`, not a
// register-save-area eightbyte, is where a MEMORY-class argument's bytes
// actually are.
//
// `structInfo` fabricates a `TypeInfo_Struct` for every guest struct
// that ever needs one - an associative array key, a plain `typeid`, a
// class field's own reflection - almost none of which ever cross the
// FFI barrier as a variadic argument. `ArgumentPlan.of` refuses a shape
// it cannot classify (an associative-array field, say - `abi.classify`'s
// own final `throw`), which is only ever a real problem for a struct
// actually passed that way; a plan built for an actual call site
// classifies it again anyway (`CallPlan.prepareCommon`'s own `foreach`)
// and raises the very same refusal, clearly, at the point that struct is
// truly being passed. So a classification failure here is swallowed,
// leaving `m_arg1`/`m_arg2` unset - "always passed in memory" is the
// wrong read for a register-class struct's own `va_arg`, but never
// wrong enough to fail fabricating this struct's `TypeInfo` for every
// other reason it exists.
private void setSysVArgTypes(
    TypeInfo_Struct info, imported!"dmd.mtype".Type type,
) {
    import snakebite.ffi.abi: ArgumentPlan, supported;

    static if (supported) {
        try {
            auto plan = ArgumentPlan.of(type);
            if (plan.memory)
                return;

            info.m_arg1 = eightbyteRepresentative(plan.registers[0]);
            if (plan.count > 1)
                info.m_arg2 = eightbyteRepresentative(plan.registers[1]);
        } catch (Exception)
            {}
    }
}

// A real host `TypeInfo` standing in for one SysV eightbyte: `core.
// internal.vararg.sysv_x64.va_arg`'s TypeInfo-driven overload reads
// `tsize` (to know how many bytes this eightbyte holds) and `flags` bit
// 1 (`inXMMregister`, to pick the SSE save area over the integer one)
// off `arg1`; off `arg2` it reads that same flags bit, and whether it is
// non-null at all, always - and, only on the path where the second
// eightbyte itself spills past the SSE register file onto the stack,
// its own `tsize` too (`sysv_x64.d`'s own `ap.stack_args +=
// arg2.tsize.alignUp`) - so any host type with the right `tsize` and the
// right SSE-ness stands in correctly, whether or not it is the guest's
// own type. `float`/`double` both set that flags bit (verified: `typeid
// (float).flags`/`typeid(double).flags` are `2` on this exact host); no
// integral type does. An odd-sized (3, 5, 6 or 7 byte) partial INTEGER
// eightbyte - only possible for the *last* eightbyte of an unaligned or
// padded struct - has no exact-size built-in type to stand in for it;
// dmd's own table for this exact case (`argtypes_sysv_x64.d`'s own
// `toArgTypes_sysv_x64`: `size > 4 ? Tint64 : size > 2 ? Tint32 : size >
// 1 ? Tint16 : Tint8`) is mirrored here rather than always widening to
// `long` - `long` over-reads a 3-byte eightbyte by 5 bytes, past
// whatever the register save area holds next, where `int` over-reads it
// by only 1, identical to what compiled D itself reads. The register
// save area always reserves a full eightbyte regardless of the
// argument's own narrower size, so the over-read itself is always safe.
private imported!"object".TypeInfo eightbyteRepresentative(
    imported!"snakebite.ffi.abi".Register register,
) {
    import snakebite.ffi.abi: Register;

    if (register.kind == Register.Kind.sse)
        return register.size == 4 ? typeid(float) : typeid(double);

    switch (register.size) {
        case 1: return typeid(byte);
        case 2: return typeid(short);
        case 3: case 4: return typeid(int);
        default: return typeid(long);
    }
}
