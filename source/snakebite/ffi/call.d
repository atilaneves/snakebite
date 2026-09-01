module snakebite.ffi.call;


private:


import core.stdc.string: memcpy;


// A ref result must stay available as an address for lvalue use while its
// value bytes are copied into the caller's result place.
public struct CallResult {
    private void* _address;
    private size_t _size;

    public void* address() const {
        if (_address is null)
            throw new Exception("ffi call result is not a reference");

        return cast(void*) _address;
    }

    public void copyValue(void* destination) const {
        if (_address !is null && destination !is null)
            memcpy(destination, _address, _size);
    }
}


public alias CallInvoker = void delegate(
    scope void*,
    scope const(void*)[],
);


// A host backend promises a value-sized return place, so it cannot accept a
// reference result as its direct return value.
public void rejectHostReferenceReturn(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import snakebite.exception: SnakebiteException;
    import std.conv: text;

    const type = function_.type.isTypeFunction;
    assert(type !is null);

    if (type.isRef)
        throw new SnakebiteException(
            text("interpreter cannot call `", function_.toString,
                "` from the host: it returns by `ref`"),
        );
}


// Keep the pointer-sized guest representation of a reference in one place,
// so interpreted and native calls use the same FFI boundary.
public void storeReference(void* place, void* address) {
    import snakebite.nativelayout: storeIntegral;

    storeIntegral(place, cast(size_t) address, size_t.sizeof);
}


// A ref parameter needs the guest lvalue's address; other parameters need its
// value. The caller supplies both guest operations, and this package applies
// the declaration's FFI convention.
public void storeArgument(
    imported!"dmd.func".FuncDeclaration function_,
    size_t index,
    void* place,
    scope void* delegate() address,
    scope void delegate(void*) evaluate,
) {
    import dmd.astenums: STC;

    // dmd's parameter-list accessors are mutable, even for a read-only
    // declaration query.
    auto type = function_.type.isTypeFunction;
    assert(type !is null);
    assert(index < type.parameterList.length);

    if (type.parameterList[index].storageClass & STC.ref_)
        storeReference(place, address());
    else
        evaluate(place);
}


// A ref return exposes a guest lvalue, while a value return exposes bytes.
// The caller supplies both guest operations so this package can apply the
// declaration's FFI convention.
public void returnFromCall(
    imported!"dmd.func".FuncDeclaration function_,
    void* place,
    scope void* delegate() address,
    scope void delegate() evaluate,
) {
    const type = function_.type.isTypeFunction;
    assert(type !is null);

    if (type.isRef) {
        storeReference(place, address());
        return;
    }

    evaluate();
}


// Copy a call result through the FFI boundary. The underlying type supplies
// the copy width, so callers cannot make the adapter read outside the result.
public CallResult invokeCall(
    imported!"dmd.func".FuncDeclaration function_,
    void* returnPlace,
    scope const(void*)[] arguments,
    scope CallInvoker invoke,
) {
    // dmd's function-type accessors are mutable, even for a read-only
    // declaration query.
    auto type = function_.type.isTypeFunction;
    assert(type !is null);

    import snakebite.nativelayout: TypeFacts;
    auto returnType = type.nextOf;
    assert(returnType !is null);

    if (!type.isRef) {
        invoke(returnPlace, arguments);
        return CallResult.init;
    }

    align(size_t.sizeof) ubyte[size_t.sizeof] addressPlace = void;
    invoke(addressPlace.ptr, arguments);

    // Keep this local mutable because D makes a `const` local return as
    // `const(CallResult)`, which does not match the function's return type.
    auto result = CallResult(
        referenceAt(addressPlace.ptr),
        TypeFacts.of(returnType).size,
    );
    result.copyValue(returnPlace);
    return result;
}


private void* referenceAt(const(void)* place) {
    import snakebite.nativelayout: loadIntegral;

    return cast(void*) loadIntegral(place, size_t.sizeof, false);
}
