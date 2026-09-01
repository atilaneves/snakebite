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


// DMD declarations are mutable graph objects, so their call facts are read
// once while a function's frame layout is prepared. Calls then cross this
// seam using only the native-layout facts kept here.
public struct CallAdapter {
    private bool _referenceResult;
    private size_t _resultSize;

    public struct Argument {
        private bool _reference;

        public static Argument of(
            imported!"dmd.mtype".Parameter parameter,
        ) {
            import dmd.astenums: STC;

            return Argument(
                (parameter.storageClass & STC.ref_) != 0,
            );
        }

        // A ref parameter needs the guest lvalue's address; other parameters
        // need its value. The caller supplies both guest operations so the
        // distinction stays inside this package.
        pragma(inline, true) public void store(
            void* place,
            scope void* delegate() address,
            scope void delegate(void*) evaluate,
        ) const {
            if (_reference)
                storeReference(place, address());
            else
                evaluate(place);
        }
    }

    public static CallAdapter of(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import snakebite.nativelayout: TypeFacts;

        // dmd's function-type accessors are mutable, even for a read-only
        // declaration query.
        auto type = function_.type.isTypeFunction;
        assert(type !is null);

        CallAdapter adapter;
        adapter._referenceResult = type.isRef;

        if (adapter._referenceResult) {
            auto returnType = type.nextOf;
            assert(returnType !is null);
            adapter._resultSize = TypeFacts.of(returnType).size;
        }

        return adapter;
    }

    // A host backend promises a value-sized return place, so it cannot accept
    // a reference result as its direct return value.
    public void rejectHostReferenceReturn(
        imported!"dmd.func".FuncDeclaration function_,
    ) const {
        import snakebite.exception: SnakebiteException;
        import std.conv: text;

        if (_referenceResult)
            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "` from the host: it returns by `ref`"),
            );
    }

    // A ref return exposes a guest lvalue, while a value return exposes bytes.
    // The caller supplies both guest operations so the distinction stays
    // inside this package.
    pragma(inline, true) public void returnFromCall(
        void* place,
        scope void* delegate() address,
        scope void delegate() evaluate,
    ) const {
        if (_referenceResult) {
            storeReference(place, address());
            return;
        }

        evaluate();
    }

    // A reference result must remain an lvalue while its current value also
    // reaches an ordinary expression's return place.
    pragma(inline, true) public CallResult invoke(
        void* returnPlace,
        scope const(void*)[] arguments,
        scope CallInvoker invoke,
    ) const {
        if (!_referenceResult) {
            invoke(returnPlace, arguments);
            return CallResult.init;
        }

        align(size_t.sizeof) ubyte[size_t.sizeof] addressPlace = void;
        invoke(addressPlace.ptr, arguments);

        // D makes a `const` local return as `const(CallResult)`, which does
        // not match this method's return type.
        auto result = CallResult(
            referenceAt(addressPlace.ptr),
            _resultSize,
        );
        result.copyValue(returnPlace);
        return result;
    }
}


// Keep the pointer-sized guest representation of a reference in one place,
// so interpreted and native calls use the same FFI seam.
pragma(inline, true) private void storeReference(
    void* place,
    void* address,
) {
    import snakebite.nativelayout: storeIntegral;

    storeIntegral(place, cast(size_t) address, size_t.sizeof);
}


private void* referenceAt(const(void)* place) {
    import snakebite.nativelayout: loadIntegral;

    return cast(void*) loadIntegral(place, size_t.sizeof, false);
}
