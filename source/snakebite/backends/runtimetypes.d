module snakebite.backends.runtimetypes;


private:


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
        return _initialValue(declaration.type, declaration.loc);
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

        import snakebite.frontend.compiler: withCompilerLock;

        TypeInfo info;
        withCompilerLock({
            if (auto cached = type in _types)
                info = *cached;
            else
                info = *_types.insert(type, build(type));
        });
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
                    assert(0);

                case Tclass, Tstruct, Tenum, Tfunction, Tdelegate,
                    Tpointer, Tsarray, Taarray, Tvector, Ttuple, Tarray:
                    assert(0);
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

    private TypeInfo_Struct structInfo(StructDeclaration declaration) {
        if (auto cached = declaration in _structs)
            return *cached;

        import dmd.root.string: toDString;
        auto info = new TypeInfo_Struct;
        _structs.insert(declaration, info);
        info.mangledName = declaration.type.deco.toDString.idup;
        info.m_init = cast(byte[]) _initialValue(
            declaration.type, declaration.loc,
        ).dup;
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
        setSysVArgTypes(info, declaration.type);
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
        case 5: .. case 8: return typeid(long);
        default: assert(false);
    }
}
