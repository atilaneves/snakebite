module snakebite.backends.druntimehooks;


private:


import snakebite.ffi.abi: Register;


// A druntime hook either backend calls directly by linker symbol, with
// no `FuncDeclaration` of its own for `snakebite.ffi.plan`'s
// `signatureOf` to walk: druntime builds the ABI shape into the symbol
// itself, so a backend states it once, the same way a real build's own
// glue layer (`e2ir.d`) hardcodes it. `PlanCache.rawPlanOf` still
// resolves and plans the call, exactly as it does for a guest
// `FuncDeclaration`; only the name and register shape come from this
// table instead of from `signatureOf`. Both backends ask for a hook by
// enum member, through `planOf`, rather than writing out its symbol and
// register list again at every call site.
public enum DruntimeHook {
    indexBounds,
    sliceBounds,
    classInvariant,
    gcMalloc,
    callFinalizer,
    arrayAppendChar,
    arrayAppendWchar,
}


// `_d_arraybounds_indexp(const(char)* file, uint line, size_t index,
// size_t length)` - one call site whether the array is dynamic or
// static, since the hook itself only ever runs on the failure path.
private immutable Register[4] _indexBoundsRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
];

// `_d_arraybounds_slicep(const(char)* file, uint line, size_t lower,
// size_t upper, size_t length)`.
private immutable Register[5] _sliceBoundsRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
];

// `_d_invariant(Object)` and `_d_callfinalizer(void*)` both take one
// pointer-sized argument and return nothing.
private immutable Register[1] _pointerOnlyRegisters = [
    Register(Register.Kind.pointer, size_t.sizeof),
];

// `gc_malloc(size_t size, uint bits, TypeInfo ti)`, returning the
// allocated block.
private immutable Register[3] _gcMallocRegisters = [
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.pointer, 8),
];
private immutable Register _gcMallocReturnRegister =
    Register(Register.Kind.pointer, 8);

// `_d_arrayappendcd(ref char[] x, dchar c)`/`_d_arrayappendwd(ref
// wchar[] x, dchar c)` both take the array by `ref` (one pointer-sized
// slot) and the `dchar` to append (4 bytes) - see
// `visitUnloweredCatDcharAssign` (interpreter and bytecode compiler)
// for why there is no `CallExp` either backend could otherwise walk for
// this call.
private immutable Register[2] _arrayAppendRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
];

// druntime's `_d_invariant` (`rt.invariant_`) has plain `extern(D)`
// linkage, so its linker symbol is its mangled name, not the bare
// identifier - the same mangled string dmd's own backend hardcodes for
// `RTLSYM.DINVARIANT` (`dmd.backend.drtlsym`), since D name mangling is
// part of the language ABI, not something either compiler is free to
// invent independently.
private immutable string _classInvariantSymbol =
    "_D2rt10invariant_12_d_invariantFC6ObjectZv";


// One hook's own linker symbol name and the ABI shape `PlanCache.
// rawPlanOf` (`snakebite.ffi.plan`) needs to resolve and plan a call to
// it. `name` alone also doubles as the symbol a "not in this process"
// failure message names, since a hook is looked up by that same string.
public struct DruntimeHookSpec {
    public string name;
    public const(Register)[] parameterRegisters;
    public Register returnRegister = Register(Register.Kind.none, 0);
}


// `hook`'s own name and register shape, the same ones `planOf` passes
// to `rawPlanOf`. Exposed on its own so a call site can still name the
// hook in a failure message without resolving it a second time.
public DruntimeHookSpec specOf(in DruntimeHook hook) @safe @nogc nothrow pure {
    final switch (hook) with (DruntimeHook) {
        case indexBounds:
            return DruntimeHookSpec(
                "_d_arraybounds_indexp", _indexBoundsRegisters);
        case sliceBounds:
            return DruntimeHookSpec(
                "_d_arraybounds_slicep", _sliceBoundsRegisters);
        case classInvariant:
            return DruntimeHookSpec(
                _classInvariantSymbol, _pointerOnlyRegisters);
        case gcMalloc:
            return DruntimeHookSpec(
                "gc_malloc", _gcMallocRegisters, _gcMallocReturnRegister);
        case callFinalizer:
            return DruntimeHookSpec("_d_callfinalizer", _pointerOnlyRegisters);
        case arrayAppendChar:
            return DruntimeHookSpec(
                "_d_arrayappendcd", _arrayAppendRegisters);
        case arrayAppendWchar:
            return DruntimeHookSpec(
                "_d_arrayappendwd", _arrayAppendRegisters);
    }
}


// The resolved `CallPlan` for `hook`, the same `null`-on-miss contract
// `PlanCache.rawPlanOf` itself returns - `null` when the symbol is not
// in this process. Every backend reaches a druntime hook through this,
// instead of hand-writing the hook's own register shape at the call
// site.
public const(imported!"snakebite.ffi.plan".CallPlan)* planOf(
    ref imported!"snakebite.ffi.plan".PlanCache plans,
    in DruntimeHook hook,
) {
    const spec = specOf(hook);
    return plans.rawPlanOf(
        spec.name, spec.parameterRegisters, spec.returnRegister);
}
