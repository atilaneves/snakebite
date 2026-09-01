module snakebite.ffi.libffi_callback;


import snakebite.ffi.callback: CallbackSignature, CallbackTarget;


private:


struct FfiType {
    size_t size;
    ushort alignment;
    ushort type;
    FfiType** elements;
}


struct FfiCif {
    uint abi;
    uint nargs;
    FfiType** argTypes;
    FfiType* returnType;
    uint bytes;
    uint flags;
}


extern(C) extern __gshared FfiType ffi_type_sint32;
extern(C) extern __gshared FfiType ffi_type_double;


extern(C) uint ffi_get_default_abi();
extern(C) size_t ffi_get_closure_size();
private alias ClosureHandler = extern(C) void function(
    FfiCif*,
    void*,
    void**,
    void*,
);
extern(C) int ffi_prep_cif(
    FfiCif*,
    uint,
    uint,
    FfiType*,
    FfiType**,
);
extern(C) void* ffi_closure_alloc(size_t, void**);
extern(C) void ffi_closure_free(void*);
extern(C) int ffi_prep_closure_loc(
    void*,
    FfiCif*,
    ClosureHandler,
    void*,
    void*,
);


private struct State {
    FfiCif cif;
    FfiType*[1] argumentTypes;
    void* closureMemory;
    void* code;
    CallbackTarget target;
    CallbackSignature signature;
}


private extern(C) void dispatch(
    FfiCif*,
    void* returnPlace,
    void** arguments,
    void* stateAddress,
) {
    auto state = cast(State*) stateAddress;
    state.target.handler(
        state.target.context,
        returnPlace,
        arguments,
        1,
    );
}


// A libffi closure prototype for the same callback target and enumerated
// shapes used by the fixed-pool contender. The closure owns executable
// memory per callback; this is the cost and portability point being raced.
public struct LibffiCallback {
    private State* _state;

    @disable this(this);

    public this(
        CallbackTarget target,
        CallbackSignature signature = CallbackSignature.intToInt,
    ) {
        _state = new State;
        _state.target = target;
        _state.signature = signature;

        FfiType* type;
        final switch (signature) with (CallbackSignature) {
            case intToInt:
                type = &ffi_type_sint32;
                break;
            case doubleToDouble:
                type = &ffi_type_double;
                break;
        }
        _state.argumentTypes[0] = type;

        const cifStatus = ffi_prep_cif(
            &_state.cif,
            ffi_get_default_abi(),
            1,
            type,
            _state.argumentTypes.ptr,
        );
        if (cifStatus != 0)
            throw new Exception("libffi could not prepare callback cif");

        _state.closureMemory = ffi_closure_alloc(
            ffi_get_closure_size(),
            &_state.code,
        );
        if (_state.closureMemory is null || _state.code is null)
            throw new Exception("libffi could not allocate callback closure");

        const closureStatus = ffi_prep_closure_loc(
            _state.closureMemory,
            &_state.cif,
            &dispatch,
            cast(void*) _state,
            _state.code,
        );
        if (closureStatus != 0) {
            ffi_closure_free(_state.closureMemory);
            _state.closureMemory = null;
            throw new Exception("libffi could not prepare callback closure");
        }
    }

    public ~this() {
        if (_state is null)
            return;

        if (_state.closureMemory !is null)
            ffi_closure_free(_state.closureMemory);
        _state = null;
    }

    public void* functionPointer() const {
        assert(_state !is null);
        return cast(void*) _state.code;
    }
}
