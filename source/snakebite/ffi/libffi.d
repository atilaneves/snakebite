module snakebite.ffi.libffi;


import snakebite.ffi.abi: maxArguments;
import snakebite.ffi.symbol: Resolver;


private:


enum FFI_TYPE_STRUCT = 13;

struct ffi_type {
    size_t size;
    ushort alignment;
    ushort type;
    ffi_type** elements;
}

struct ffi_cif {
    uint abi;
    uint nargs;
    ffi_type** arg_types;
    ffi_type* rtype;
    uint bytes;
    uint flags;
}

extern(C) extern __gshared ffi_type ffi_type_void;
extern(C) extern __gshared ffi_type ffi_type_uint8;
extern(C) extern __gshared ffi_type ffi_type_sint8;
extern(C) extern __gshared ffi_type ffi_type_uint16;
extern(C) extern __gshared ffi_type ffi_type_sint16;
extern(C) extern __gshared ffi_type ffi_type_uint32;
extern(C) extern __gshared ffi_type ffi_type_sint32;
extern(C) extern __gshared ffi_type ffi_type_uint64;
extern(C) extern __gshared ffi_type ffi_type_sint64;
extern(C) extern __gshared ffi_type ffi_type_float;
extern(C) extern __gshared ffi_type ffi_type_double;
extern(C) extern __gshared ffi_type ffi_type_longdouble;
extern(C) extern __gshared ffi_type ffi_type_pointer;
extern(C) extern __gshared ffi_type ffi_type_complex_float;
extern(C) extern __gshared ffi_type ffi_type_complex_double;

extern(C) int ffi_prep_cif(
    ffi_cif* cif,
    uint abi,
    uint argumentCount,
    ffi_type* returnType,
    ffi_type** argumentTypes,
);

extern(C) uint ffi_get_default_abi();

extern(C) void ffi_call(
    ffi_cif* cif,
    void function() function_,
    void* returnPlace,
    void** arguments,
);

private alias NativeFunction = extern(C) void function();


// A libffi call prepared from one D declaration. The arena owns every
// descriptor made for an aggregate, and therefore outlives the cif that
// points into those descriptors.
public struct LibffiPlan {
    private ffi_cif _cif;
    private TypeArena _arena;
    private Resolver _resolver;
    private void* _address;
    private string _name;
    private size_t _returnSize;
    private bool _resolved;

    public this(imported!"dmd.func".FuncDeclaration function_) {
        this(function_, false);
    }

    // `deferResolution` keeps symbol lookup out of preparation. The first
    // call still resolves through the same cache, so later calls measure
    // only ffi_call.
    public this(
        imported!"dmd.func".FuncDeclaration function_,
        in bool deferResolution,
    ) {
        import dmd.astenums: LINK, STC, Tvoid, VarArg;
        import std.conv: text;
        import std.string: fromStringz;
        import dmd.mangle: mangleExact;

        auto functionType = function_.type.isTypeFunction;
        if (functionType is null)
            throw new Exception(text(
                "libffi cannot call `", function_.toString,
                "`: it is not a function",
            ));

        if (function_.resolvedLinkage != LINK.c)
            throw new Exception(text(
                "libffi cannot call `", function_.toString,
                "`: only extern(C) is supported",
            ));

        if (functionType.parameterList.varargs != VarArg.none)
            throw new Exception(text(
                "libffi cannot call the variadic function `",
                function_.toString, "`",
            ));

        _arena = new TypeArena;
        const parameterCount = functionType.parameterList.length;
        if (parameterCount > maxArguments)
            throw new Exception(text(
                "libffi cannot call `", function_.toString, "`: it takes ",
                parameterCount, " arguments, but only ", maxArguments,
                " argument slots are available",
            ));
        auto argumentTypes = new ffi_type*[parameterCount];
        foreach (i; 0 .. parameterCount) {
            const parameter = functionType.parameterList[i];
            if ((parameter.storageClass & STC.ref_) != 0)
                argumentTypes[i] = _arena.pointer;
            else
                argumentTypes[i] = _arena.of(
                    cast(imported!"dmd.mtype".Type) parameter.type,
                );
        }

        auto returnType = _arena.of(functionType.nextOf);
        import dmd.typesem: size;
        _returnSize = size(functionType.nextOf);
        const status = ffi_prep_cif(&_cif, ffi_get_default_abi(),
            cast(uint) parameterCount, returnType,
            parameterCount == 0 ? null : argumentTypes.ptr);
        if (status != 0)
            throw new Exception(text(
                "libffi could not prepare `", function_.toString,
                "` (status ", status, ", abi ", ffi_get_default_abi(),
                ")",
            ));

        auto name = mangleExact(function_);
        _name = name.fromStringz.idup;
        _resolver = Resolver.init;
        if (!deferResolution)
            resolve(function_);
    }

    // `arguments` point to values in native layout. libffi reads those
    // values directly, so no guest-to-C marshalling occurs here.
    public void call(
        void* returnPlace,
        scope const(void*)[] arguments,
    ) {
        if (arguments.length != _cif.nargs)
            throw new Exception("libffi: wrong argument count");

        void*[16] values;
        foreach (i, argument; arguments)
            values[i] = cast(void*) argument;

        // libffi may write a machine word for a scalar result smaller than
        // that word. A local word gives it the space it requires, then only
        // the native result bytes are copied to the caller's place.
        align(16) ubyte[16] smallReturn;
        void* ffiReturn;
        if (_returnSize == 0)
            ffiReturn = null;
        else if (_returnSize <= smallReturn.length)
            ffiReturn = smallReturn.ptr;
        else {
            if (returnPlace is null)
                throw new Exception(
                    "libffi: a discarded large result needs storage",
                );
            ffiReturn = returnPlace;
        }

        if (!_resolved)
            resolve;

        ffi_call(cast(ffi_cif*) &_cif,
            cast(NativeFunction) _address,
            ffiReturn,
            arguments.length == 0 ? null : values.ptr);

        if (returnPlace !is null && ffiReturn == smallReturn.ptr) {
            import core.stdc.string: memcpy;

            memcpy(returnPlace, smallReturn.ptr, _returnSize);
        }
    }

    private void resolve(
        imported!"dmd.func".FuncDeclaration function_ = null,
    ) {
        _address = _resolver.resolve(_name);
        _resolved = true;
        if (_address is null) {
            import std.conv: text;

            throw new Exception(text(
                "libffi cannot resolve the symbol `", _name,
                "` declared by `", function_ is null ? "the function" :
                    function_.toString, "`",
            ));
        }
    }
}


private final class TypeArena {
    private ffi_type*[] _descriptors;
    private ffi_type*[][] _elementArrays;

    public ffi_type* pointer() {
        return &ffi_type_pointer;
    }

    public ffi_type* of(imported!"dmd.mtype".Type type) {
        import dmd.astenums:
            Tarray, Taarray, Tbool, Tclass, Tcomplex32, Tcomplex64,
            Tdelegate, Tfloat32, Tfloat64, Tfloat80, Tpointer, Tfunction,
            Tsarray, Tvoid;
        import dmd.typesem: size;
        import std.conv: text;

        switch (type.ty) {
            case Tvoid:
                return &ffi_type_void;
            case Tbool:
                return &ffi_type_uint8;
            case Tfloat32:
                return &ffi_type_float;
            case Tfloat64:
                return &ffi_type_double;
            case Tfloat80:
                return &ffi_type_longdouble;
            case Tcomplex32:
                return &ffi_type_complex_float;
            case Tcomplex64:
                return &ffi_type_complex_double;
            case Tpointer:
            case Tclass:
            case Taarray:
            case Tfunction:
                return &ffi_type_pointer;
            case Tdelegate:
                return structure([pointer, pointer]);
            case Tarray:
                return structure([&ffi_type_uint64, pointer]);
            case Tsarray: {
                auto array = type.isTypeSArray;
                const count = array.dim.toInteger;
                auto elements = new ffi_type*[count];
                foreach (i; 0 .. count)
                    elements[i] = of(type.nextOf);
                return structure(elements);
            }
            default:
                if (type.isIntegral) {
                    switch (type.size) {
                        case 1:
                            return type.isUnsigned
                                ? &ffi_type_uint8 : &ffi_type_sint8;
                        case 2:
                            return type.isUnsigned
                                ? &ffi_type_uint16 : &ffi_type_sint16;
                        case 4:
                            return type.isUnsigned
                                ? &ffi_type_uint32 : &ffi_type_sint32;
                        case 8:
                            return type.isUnsigned
                                ? &ffi_type_uint64 : &ffi_type_sint64;
                        default:
                            break;
                    }
                }

                if (auto aggregate = type.isTypeStruct)
                    return structureFields(aggregate.sym);

                throw new Exception(text(
                    "libffi cannot describe type `", type.toString, "`",
                ));
        }
    }

    private ffi_type* structureFields(
        imported!"dmd.dstruct".StructDeclaration aggregate,
    ) {
        import std.conv: text;

        ffi_type*[] elements;
        size_t offset;
        foreach (field; aggregate.fields) {
            if (field.type is null)
                continue;
            if (field.offset < offset)
                throw new Exception(text(
                    "libffi cannot describe overlapping fields in `",
                    aggregate.toString, "`",
                ));
            if (field.offset > offset)
                elements ~= padding(field.offset - offset);
            elements ~= of(field.type);
            import dmd.typesem: size;
            offset = field.offset + size(field.type);
        }
        if (aggregate.structsize > offset)
            elements ~= padding(aggregate.structsize - offset);
        return structure(elements);
    }

    private ffi_type* padding(in size_t bytes) {
        auto elements = new ffi_type*[bytes];
        foreach (ref element; elements)
            element = &ffi_type_uint8;
        return structure(elements);
    }

    private ffi_type* structure(scope const(ffi_type*)[] elements) {
        auto descriptor = new ffi_type;
        auto elementArray = new ffi_type*[elements.length + 1];
        foreach (i, element; elements)
            elementArray[i] = cast(ffi_type*) element;
        elementArray[$ - 1] = null;
        descriptor.type = FFI_TYPE_STRUCT;
        descriptor.elements = elementArray.ptr;
        _descriptors ~= descriptor;
        _elementArrays ~= elementArray;
        return descriptor;
    }
}
