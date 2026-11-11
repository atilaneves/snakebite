module snakebite.ffi.plan;


import snakebite.backends.bytecode.linkedmodules: LinkedModules;
import snakebite.ffi.callback: CallbackBridge;
import snakebite.ffi.symbol: Resolver;
import snakebite.ffi.callplan:
    CallPlan, NativeSignature, hasStoreWidth, planOf;


private:

import snakebite.frontend.typefacts: typeFacts;



import snakebite.failure.report: internalFailure;


// The plans already prepared, one per function. A backend owns one of
// these and keeps it for its whole life, so the second call to a function
// and every call after it reuses the first call's answers.
//
// Keyed by declaration rather than by call site: two call sites naming the
// same function need the very same plan, and the declaration is what both
// resolve to. A call site is the finer key, and would let a plan be found
// without hashing at all, but it needs somewhere on the call site to keep
// it, which is the caller's business and not this package's.
public struct PlanCache {
    // Holds `SharedTable`s (finding 2.4): a copy would share their
    // storage with the original until one side grows.
    @disable this(this);

    // `isRootOwned` is the owning program's own decision
    // (`Program.isRootOwned`). Without it every function can have native
    // code.
    public this(
        LinkedModules* linked,
        bool delegate(imported!"dmd.dsymbol".Dsymbol) const isRootOwned = null,
    ) {
        _linked = linked;
        _isRootOwned = isRootOwned;
    }

    import dmd.func: FuncDeclaration;
    import dmd.mtype: TypeFunction;

    // Owns the plans that this prepares, the resolver they bind symbols
    // with and the callback bridge. This keeps the index from a declaration
    // to its plan, and the counts. The owner of the cache keeps `_linked`
    // alive longer.
    private LinkedModules* _linked;

    public void* callableAddress(
        const(void)* word, FuncDeclaration declaration,
        in ptrdiff_t adjustment = 0,
    ) {
        if (word is null)
            word = of(declaration).address;
        // The bridge never reads the AST, so the signature is built here,
        // under the compiler lock and only when the bridge has no entry
        // yet. Lock order, outermost first: the compiler lock, then the
        // bridge's mutex. A caller may already hold the compiler lock
        // here (`ClassRuntimeCache.build` does), so the lock is not
        // always released before the bridge takes its mutex; the bridge
        // never takes the compiler lock.
        NativeSignature signature;
        if (adjustment != 0 && _linked.callbacks.reservedAdjustedEntry(
                word, adjustment) is null) {
            import snakebite.frontend.compiler: withCompilerLock;

            withCompilerLock({ signature = nativeSignatureOf(declaration); });
        }
        return cast(void*) _linked.callbacks.adjustedEntryOf(
            word, signature, adjustment);
    }

    public CallbackBridge.GuestTarget guestTarget(const(void)* address) const {
        return _linked.callbacks is null ? CallbackBridge.GuestTarget.init
            : _linked.callbacks.guestTarget(address);
    }

    public bool isGuestWord(const(void)* word) const {
        return _linked.callbacks !is null && _linked.callbacks.contains(word);
    }

    // Whether `of` and the callback entry of `function_` can plan its
    // signature. Each of them halts on a signature that this gives `false`
    // for, so a caller that only prepares calls this first and leaves such a
    // function for the program to reach.
    public bool canPlan(FuncDeclaration function_) {
        import snakebite.frontend.dmd.mangle: completeFunctionType;

        completeFunctionType(function_);
        auto type = function_.type.isTypeFunction;
        return type !is null && hasResultStore(type);
    }

    public void* addressOf(FuncDeclaration function_) {
        import snakebite.druntime.constructoratomic: nativeTarget;
        import snakebite.frontend.dmd.mangle: mangledNameOf;

        auto target = nativeTarget(function_);
        if (target.address !is null)
            return target.address;
        return _linked.resolver.resolve(mangledNameOf(function_));
    }

    // `TypeFunction`, not `const(TypeFunction)`: a `SharedTable` entry
    // assigns its whole key by value on insert, which a `const` field
    // would refuse.
    private struct Signature {
        TypeFunction type;
        bool context;
    }
    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a signature's plan is prepared once, on its first
    // indirect call.
    private SharedTable!(Signature, CallPlan*) _signatures;

    // No frontend lock: `_shapeOf` forces every dmd forward reference it
    // could still need itself, up front, through `typeFacts` (its
    // own doc), and `_signatures` is a `SharedTable`, which brings its
    // own insert lock (ADR-0006) - the same reasoning `snakebite.
    // backends.interpreter.walker`'s `Cache.build` and `snakebite.
    // language.call.selection.CallSelection.decisionOf` already apply to their
    // own caches.
    public const(CallPlan)* signatureOf(
        TypeFunction type, in bool context,
    ) {
        import dmd.astenums: VarArg;

        auto key = Signature(type, context);
        if (auto cached = key in _signatures)
            return *cached;

        auto plan = _linked.newPlan;
        // These indirect calls pass only the declared parameters.
        // A C variadic call with no extra arguments still needs its
        // variadic ABI plan (including the SSE register count).
        *plan = planOf(_signatureOf(type, context, type.linkage, null,
            type.parameterList.varargs == VarArg.variadic),
            null, _linked.callbacks);
        return *_signatures.insert(key, plan);
    }

    // How many chunks of entries the installed bridge has.
    version(unittest)
    public size_t callbackChunkCount() {
        return _linked.callbacks is null ? 0 : _linked.callbacks.chunkCount;
    }

    // Records that `word` is what this backend stores for the guest
    // function `declaration` when guest code takes its address or makes
    // a delegate to it. Only a word a backend itself emitted is ever
    // registered: a host code address must never be inspected as a
    // frontend or bytecode object, and an unregistered word crosses the
    // barrier unchanged.
    public void registerGuestFunction(
        const(void)* word,
        FuncDeclaration declaration,
    ) {
        requireCallbacks;
        if (!_linked.callbacks.contains(word))
            _linked.callbacks.register(word, nativeSignatureOf(declaration));
    }

    // As `registerGuestFunction`, for a backend that keeps the
    // declaration itself. It does not look at `contains`: the bridge
    // ignores a word it already holds, and the caller, which has to build
    // `signature` from the AST, asks `isGuestWord` first to skip that work.
    public void registerEntry(
        const(void)* word,
        NativeSignature signature,
    ) {
        requireCallbacks;
        _linked.callbacks.register(word, signature);
    }

    private void requireCallbacks() const {
        if (_linked.callbacks is null)
            throw new Exception(
                "ffi: a guest function was registered before the " ~
                    "backend installed its callback bridge",
            );
    }

    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import snakebite.ffi.argumentplan: Register;
    import snakebite.host.sharedtable: SharedTable;

    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a plan is prepared once, on its first use.
    private SharedTable!(FuncDeclaration, CallPlan*) _plans;
    private SharedTable!(string, CallPlan*) _rawPlans;
    private SharedTable!(FuncDeclaration, bool) _nativeSymbols;
    private SharedTable!(FuncDeclaration, bool) _independentNativeSymbols;
    private bool delegate(imported!"dmd.dsymbol".Dsymbol) const _isRootOwned;
    private shared size_t _preparations;
    version(unittest) private size_t _nativeSymbolLookups;

    // Resolves a linker name through the cache shared by this backend's
    // plan preparation and its other FFI operations.
    public void* resolve(in char[] name) {
        return _linked.resolver.resolve(name);
    }

    public void* resolveThreadLocal(in char[] name) const {
        return _linked.resolver.resolveThreadLocal(name);
    }

    // Whether `function_` has machine code in this process. Missing symbols
    // are cached too because a synthesized function with a body can validly
    // have no native counterpart.
    // `nativeTarget` reads only a template instance's own already-resolved
    // arguments (an AST structure walk, no forward reference to force),
    // and `resolve` is a host symbol lookup, not a dmd one - `mangledNameOf`
    // is the only call here that can still reach into dmd's own mutable
    // state, and only takes the frontend lock (`snakebite.frontend.
    // compiler.forceIfNeeded`) while `function_`'s type is not already
    // complete. `_nativeSymbols` is a `SharedTable` (ADR-0006).
    public bool hasNativeSymbol(
        FuncDeclaration function_,
    ) {
        import snakebite.druntime.constructoratomic: nativeTarget;
        import snakebite.frontend.dmd.mangle: mangledNameOf;

        if (auto cached = function_ in _nativeSymbols)
            return *cached;

        if (isInterpretedOnly(function_))
            return *_nativeSymbols.insert(function_, false);

        version(unittest) ++_nativeSymbolLookups;
        auto target = nativeTarget(function_);
        const found = target.address !is null
            || resolve(mangledNameOf(function_)) !is null;
        return *_nativeSymbols.insert(function_, found);
    }

    // Whether `function_` has machine code from a genuine, independent
    // native copy: the dependency image, or an already-loaded shared
    // object. Never the running executable's own copy of a template
    // instance snakebite itself instantiated
    // (`snakebite.language.call.selection.CallSelection.buildDecision` asks this,
    // never `hasNativeSymbol`, for that check). `nativeTarget` is a fixed
    // host wrapper, not a `dlsym` answer, so it counts as independent here
    // too.
    public bool hasIndependentNativeSymbol(
        FuncDeclaration function_,
    ) {
        import snakebite.druntime.constructoratomic: nativeTarget;
        import snakebite.frontend.dmd.mangle: mangledNameOf;

        if (auto cached = function_ in _independentNativeSymbols)
            return *cached;

        if (isInterpretedOnly(function_))
            return *_independentNativeSymbols.insert(function_, false);

        import snakebite.frontend.compiler: withCompilerLock;

        bool found;
        withCompilerLock({
            if (auto cached = function_ in _independentNativeSymbols) {
                found = *cached;
                return;
            }
            auto target = nativeTarget(function_);
            found = target.address !is null
                || _linked.resolver.resolveIndependent(
                    mangledNameOf(function_),
                ) !is null;
            _independentNativeSymbols.insert(function_, found);
        });
        return found;
    }

    // Whether `function_` has a body that only this program's interpreter
    // or compiler can run: the dependency image and the prebuilt libraries
    // are built without the root package (docs/adr/0009), so no native
    // copy of it exists. A bodiless declaration is not one - it names
    // native code, such as a designated test fixture. A template instance
    // is one when an argument, or an argument of an enclosing instance,
    // comes from a root module. An argument that this cannot classify
    // leaves the answer to the lookup.
    private bool isInterpretedOnly(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import dmd.dsymbol: Dsymbol;

        if (_isRootOwned is null || function_.fbody is null)
            return false;
        if (_isRootOwned(function_))
            return true;
        for (Dsymbol symbol = function_; symbol !is null && !symbol.isModule;
                symbol = symbol.parent) {
            if (hasRootArgument(symbol, 0))
                return true;
        }
        return false;
    }

    private bool hasRootArgument(
        imported!"dmd.dsymbol".Dsymbol symbol,
        in size_t depth,
    ) {
        import dmd.dsymbol: Dsymbol;
        import dmd.dtemplate: isDsymbol, isTuple, isType;
        import dmd.expression: Expression;
        import dmd.rootobject: RootObject;
        import dmd.typesem: nextOf, toDsymbol;

        auto instance = symbol.isTemplateInstance;
        if (instance is null || instance.tiargs is null)
            return false;

        // Bounds arguments that are themselves instances.
        enum maxDepth = 8;
        if (depth == maxDepth)
            return false;

        bool fromRoot(RootObject object) {
            if (auto tuple = object.isTuple) {
                foreach (element; tuple.objects[])
                    if (fromRoot(element))
                        return true;
                return false;
            }
            Dsymbol argument;
            if (auto type = object.isType) {
                while (type.nextOf !is null)
                    type = type.nextOf;
                argument = type.toDsymbol(null);
            } else if (auto expression = cast(Expression) object) {
                if (auto literal = expression.isFuncExp)
                    argument = literal.fd;
            } else
                argument = object.isDsymbol;
            if (argument is null)
                return false;
            if (_isRootOwned(argument))
                return true;
            for (auto enclosing = argument;
                    enclosing !is null && !enclosing.isModule;
                    enclosing = enclosing.parent)
                if (hasRootArgument(enclosing, depth + 1))
                    return true;
            return false;
        }

        foreach (argument; (*instance.tiargs)[])
            if (fromRoot(argument))
                return true;
        return false;
    }

    version(unittest)
    public size_t nativeSymbolLookups()
        @safe @nogc nothrow pure const scope
    {
        return _nativeSymbolLookups;
    }

    version(unittest)
    public size_t symbolLookups() @safe @nogc nothrow pure const scope {
        return _linked.resolver.lookups;
    }

    // How many plans this has had to prepare - the expensive work the
    // cache exists to avoid, counted so that it can be asserted on.
    //
    // The address of a cached plan cannot stand in for this: an
    // associative array's slot keeps its address when its value is
    // overwritten, so a cache that rebuilt a plan on every call would
    // still hand back the same address every time.
    public size_t preparations() const {
        import core.atomic: atomicLoad;

        return atomicLoad(_preparations);
    }

    private void countPreparation() {
        import core.atomic: atomicOp;

        atomicOp!"+="(_preparations, 1);
    }

    // `function_`'s plan, prepared on its first call and reused after.
    //
    // Returned by pointer, the same kind `variadicOf`/`rawPlanOf` return:
    // the plan stays in the cache, and a caller only ever calls through
    // it.
    // No frontend lock: `prepare` (through `shapeOf`/`_shapeOf`) forces
    // every dmd forward reference it could still need itself, up front
    // (`signatureOf`'s own doc), and `_plans` is a `SharedTable`
    // (ADR-0006).
    public const(CallPlan)* of(
        FuncDeclaration function_,
    ) {
        if (auto cached = function_ in _plans)
            return *cached;

        countPreparation;
        auto plan = _linked.newPlan;
        *plan = prepare(function_, _linked.resolver, _linked.callbacks);
        return *_plans.insert(function_, plan);
    }

    // As `.of`, but for one call site of an `extern(C)` C-style or
    // `extern(D)` untyped variadic callee (`prepareVariadic`'s own doc):
    // the plan depends on that call's own extra argument types, not on
    // `function_` alone, so this
    // never caches by declaration the way `_plans` does - it prepares a
    // fresh plan on every call. A caller keeps the returned plan itself,
    // alongside the call site it belongs to, to avoid paying that cost
    // more than once per site: the interpreter keeps it next to the
    // `CallExp` (`Evaluator.CallSitePlan`), and the bytecode compiler
    // calls this only once, while compiling the one `CallSite` a guest
    // `CallExp` ever produces.
    // No frontend lock: never cached (this method's own doc), so every
    // call touches dmd, but only through `prepareVariadic` (`shapeOf`/
    // `_shapeOf`), which forces every dmd forward reference it could
    // still need itself, up front (`signatureOf`'s own doc). This is
    // still a compile-time-triggered path: a caller reaches it once per
    // call site, not once per guest call.
    public const(CallPlan)* variadicOf(
        FuncDeclaration function_,
        scope Type[] extraArgumentTypes,
    ) {
        countPreparation;
        auto plan = _linked.newPlan;
        *plan = prepareVariadic(
            function_, _linked.resolver, extraArgumentTypes, _linked.callbacks);
        return plan;
    }

    public const(CallPlan)* variadicAtAddress(
        TypeFunction type, bool hasContext, const(void)* address,
        scope Type[] extraArgumentTypes,
    ) {
        countPreparation;
        auto plan = _linked.newPlan;
        *plan = prepareVariadicAtAddress(type, hasContext, address,
            extraArgumentTypes, _linked.callbacks);
        return plan;
    }

    // As `.of`, but for a raw address with no `FuncDeclaration` to key
    // on - see `CallPlan.ofRawAddress`. Keyed and cached by linker symbol
    // name instead, so a second bounds check anywhere in the guest
    // program reuses the first one's resolved address and plan. Returns
    // `null` when the symbol is not in this process, the same convention
    // `resolve` itself uses.
    // No frontend lock: `CallPlan.ofRawAddress` classifies from
    // caller-supplied `Register`s alone, with no `dmd.mtype.Type` and so
    // no dmd forward reference to force at all, and `_rawPlans` is a
    // `SharedTable` (ADR-0006).
    public const(CallPlan)* rawPlanOf(
        string name,
        scope const(Register)[]
            parameterRegisters,
        Register returnRegister =
            Register(Register.Kind.none, 0),
        Register secondReturnRegister = Register(Register.Kind.none, 0),
    ) {
        if (auto cached = name in _rawPlans) {
            import std.conv: text;

            assert((*cached).hasShape(
                    parameterRegisters, returnRegister, secondReturnRegister),
                text("ffi: `", name, "` was already planned with a ",
                    "different register shape"));
            return *cached;
        }

        auto address = resolve(name);
        if (address is null)
            return null;

        countPreparation;
        auto plan = _linked.newPlan;
        *plan = CallPlan.ofRawAddress(
            address, parameterRegisters, returnRegister, secondReturnRegister);
        return *_rawPlans.insert(name, plan);
    }

    // As `rawPlanOf`, for a required host symbol. The missing-symbol
    // failure is the same link failure an ordinary FFI call reports.
    public const(CallPlan)* requiredRawPlanOf(
        string name,
        scope const(Register)[] parameterRegisters,
        Register returnRegister = Register(Register.Kind.none, 0),
        Register secondReturnRegister = Register(Register.Kind.none, 0),
    ) {
        import std.conv: text;

        if (auto plan = rawPlanOf(name, parameterRegisters, returnRegister,
                secondReturnRegister))
            return plan;

        throw new Exception(text(
            "ffi cannot resolve the symbol `", name,
            "`: it is not in this process",
        ));
    }

}

// Whether `CallPlan` has a store width for each register of the result of
// `type`.
private bool hasResultStore(
    imported!"dmd.mtype".TypeFunction type,
) {
    import dmd.typesem: nextOf;
    import snakebite.ffi.abi: needsHiddenReturnPointer, returnPlanOf;
    import snakebite.ffi.argumentplan: Register;

    if (type.isRef || type.nextOf is null
            || needsHiddenReturnPointer(type.nextOf))
        return true;

    const result = returnPlanOf(type.nextOf);
    foreach (register; result.registers[0 .. result.count])
        if (register.kind != Register.Kind.x87
                && !hasStoreWidth(register.size))
            return false;
    return true;
}

// Works out how to call `function_`, once.
//
// The linkage decides only the symbol's name, which dmd's own mangler
// supplies, so nothing here is specific to C. A signature the implemented
// ABI does not cover throws, naming what it could not pass - here, when
// the plan is prepared, rather than on every call that would use it.
private CallPlan prepare(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
    CallbackBridge* callbacks,
) {
    return prepareCommon(function_, resolver, null, false, callbacks);
}

// As `prepare`, for one call site of an `extern(C)` C-style or
// `extern(D)` untyped variadic callee: `extraArgumentTypes` are that
// call's own extra arguments' types, in call order. For a C-style
// callee, the frontend has already applied C's default argument
// promotions (`float` widens to `double`, an integral narrower than
// `int` widens to `int`) - exactly the types the callee's own `va_arg`
// will read. An `extern(D)` untyped callee's own hidden `_arguments` is
// not one of these - it is a whole extra argument in its own right,
// added inside `prepareCommon` (`hasVArguments`'s own doc), since its
// value comes from the call site's `TypeidExp`, not from a caller-
// supplied type list. `PlanCache.variadicOf` is the one caller.
//
// The plan this builds is one call site's own shape, not `function_`'s
// alone (ADR-0010's C- and D-variadics paragraphs; issue #334 steps 5
// and 6): two call sites naming the same variadic function can pass
// different extra arguments, and need different plans. This is never
// cached by `function_` the way `PlanCache._plans` caches an ordinary
// plan - a backend's own call-site cache (`PlanCache.of`'s own doc,
// issue #96) is what makes a repeat call at the same site free instead.
package CallPlan prepareVariadic(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    CallbackBridge* callbacks,
) {
    return prepareCommon(
        function_, resolver, extraArgumentTypes, true, callbacks);
}

private CallPlan prepareVariadicAtAddress(
    imported!"dmd.mtype".TypeFunction type,
    bool hasContext,
    const(void)* address,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    CallbackBridge* callbacks,
) {
    return planOf(_signatureOf(type, hasContext, type.linkage,
        extraArgumentTypes, true), cast(void*) address, callbacks);
}

private CallPlan prepareCommon(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
    CallbackBridge* callbacks,
) {
    import snakebite.druntime.constructoratomic: nativeTarget;
    import snakebite.frontend.dmd.mangle: mangledNameOf;
    import std.conv: text;

    // Mangling forces `function_`'s type complete first (`mangledNameOf`'s
    // own doc) - done before `shapeOf` reads `function_.type.nextOf` to
    // classify the return value below, an inferred return type dmd has
    // not resolved yet would otherwise be read as `null`.
    const name = mangledNameOf(function_);

    auto target = nativeTarget(function_);

    // The symbol's calling convention comes from its declared linkage,
    // and `extern(D)` code built by the host's own compiler can read
    // its parameters out of the registers in reverse order - an ABI
    // fact about this process, not a routing decision about the
    // callee. `shapeOf`'s variadic checks need this fact too, to tell an
    // `extern(C)` variadic callee from an `extern(D)` one.
    const linkage = target.address is null
        ? function_.resolvedLinkage : target.linkage;

    auto signature = signatureOfFunction(function_, linkage, extraArgumentTypes,
        isVariadicCall);

    void* address = target.address;
    if (address is null)
        address = resolver.resolve(name);
    if (address is null) {
        version (LDC) {
            import gen.dpragma: LDCPragma;

            // LDC compiles this declaration inline, so the host has no symbol
            // for it; a wrapper in `snakebite.builtin.ldc` is the
            // way to a result, and this one has none.
            if (function_.llvmInternal != LDCPragma.LLVMnone)
                throw new Exception(
                    text("no host wrapper serves the LDC intrinsic `",
                        function_.mangleOverride.length
                            ? function_.mangleOverride : name,
                        "` declared by `", function_.toString, "`"),
                );
        }
        throw new Exception(
            text("ffi cannot resolve the symbol `", name,
                "` declared by `", function_.toString,
                "`: it is not in this process"),
        );
    }

    return planOf(signature, address, callbacks);
}

// The signature of the guest function `function_`, from its own declared
// linkage. Compile-time only: it reads the AST.
public NativeSignature nativeSignatureOf(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: VarArg;
    import snakebite.frontend.dmd.delegates: hasHiddenThis;
    import snakebite.frontend.dmd.mangle: completeFunctionType;
    import std.conv: text;

    // As `prepareCommon`: `signatureOf` below reads `function_.type.nextOf`
    // to classify the return value, an inferred return type or attribute
    // set dmd has not resolved yet would otherwise be read incomplete.
    completeFunctionType(function_);

    auto type = function_.type.isTypeFunction;
    if (type is null)
        throw new Exception(
            text("ffi cannot make a callback entry for `",
                function_.toString, "`: it is not a function"),
        );
    return signatureOf(type, hasHiddenThis(function_),
        function_.resolvedLinkage, null,
        type.parameterList.varargs == VarArg.variadic);
}

// The signature of `function_` under `linkage`, from which `planOf` lays out
// the plan.
private NativeSignature signatureOfFunction(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"dmd.astenums".LINK linkage,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
) {
    import snakebite.frontend.dmd.delegates: hasHiddenThis;
    return _signatureOf(function_.type.isTypeFunction,
        hasHiddenThis(function_), linkage, extraArgumentTypes,
        isVariadicCall);
}

private NativeSignature _signatureOf(
    imported!"dmd.mtype".TypeFunction type, in bool hasContext,
    in imported!"dmd.astenums".LINK linkage,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
) {
    return signatureOf(type, hasContext, linkage, extraArgumentTypes,
        isVariadicCall);
}

// The part of `_shapeOf` that reads the AST: classifies every parameter
// and the result into a `NativeSignature`.
private NativeSignature signatureOf(
    imported!"dmd.mtype".TypeFunction type, in bool hasContext,
    in imported!"dmd.astenums".LINK linkage,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
) {
    import snakebite.ffi.abi:
        argumentPlanOf, linkageOf, needsHiddenReturnPointer, returnPlanOf;
    import snakebite.ffi.argumentplan: ArgumentPlan, Register, supported;
    import dmd.astenums: LINK, STC, Tdelegate, VarArg;
    import dmd.typesem: nextOf, toBasetype;
    import std.conv: text;

    static if (!supported)
        throw new Exception(
            "ffi is implemented for the System V AMD64 ABI only",
        );
    else {
        if (type is null)
            throw new Exception(
                "ffi cannot call a value without a function type",
            );

        // Forces every dmd forward reference a struct or enum argument
        // or return type could still have - a class handle, a pointer
        // and every basic type have none (`typeFacts`'s own doc) - up
        // front, through the one mechanism every other backend and cache
        // already forces one through (`snakebite.frontend.compiler.
        // forceIfNeeded`, reached here via `typeFacts`), each only
        // while dmd has not already resolved it. `classify`/`argumentPlanOf`
        // (`snakebite.ffi.abi`) read a struct's own `.size`/
        // `.alignsize` directly, not through `TypeFacts`, so without this
        // they would be the one place left in this whole call reading a
        // forward reference dmd might still need to resolve, unlocked -
        // forcing the struct itself here is enough for its own fields
        // too: dmd's `finalizeSize` (`dsymbolsem.d`) determines every
        // field's own size as part of computing the struct's, all under
        // the one lock `typeFacts` takes only while still needed, so
        // `classify`'s later, recursive field reads find every size it
        // touches already resolved.
        {
            import snakebite.native.value: TypeFacts;

            auto returnType = type.nextOf;
            if (returnType !is null)
                typeFacts(returnType);
            foreach (i, parameter; type.parameterList)
                typeFacts(parameter.type);
            foreach (extraType; extraArgumentTypes)
                typeFacts(extraType);
        }

        // A variadic callee is handed its extra arguments differently -
        // on the System V AMD64 ABI the caller must also report how many
        // SSE registers it used (`%al`) - so a fixed-arity plan would be
        // the wrong call, not merely an incomplete one. Only `VarArg.
        // variadic` (an `extern(C)` C-style variadic callee, or an
        // `extern(D)` untyped one - issue #334 steps 5 and 6) needs a
        // call site's own extra argument types, and only through
        // `prepareVariadic`, one call site at a time (this function's own
        // doc). `VarArg.typesafe` (`T t...`) needs neither: the frontend
        // has already packed a typesafe call's trailing arguments into
        // one array-typed argument by the time this ever runs
        // (`snakebite.language.call.selection.arityMismatches`'s own doc), so it
        // classifies like any other declared parameter below, through the
        // ordinary `prepare`/`.of` path.
        const isCVariadic = type.parameterList.varargs == VarArg.variadic
            && (linkage == LINK.c || linkage == LINK.cpp
                || linkage == LINK.system || linkage == LINK.objc);
        // dmd's own frontend semantic (`dmd.expressionsem.
        // functionParameters`) inserts `_arguments` - a `TypeInfo_Tuple`
        // reference describing the call's own extra argument types - as
        // an ordinary leading argument on every `extern(D)` untyped
        // variadic call site, ahead of the declared parameters; nothing
        // about that insertion is C-specific, so this ABI fact holds
        // whichever host compiler built this process (ADR-0010's D
        // variadic paragraph).
        const isDVariadic = type.parameterList.varargs == VarArg.variadic
            && linkage == LINK.d;
        if (isVariadicCall) {
            if (!isCVariadic && !isDVariadic)
                throw new Exception(
                    text("ffi cannot call `", type.toString,
                        "` as a variadic function: its linkage does not use ",
                        "the System V C or D variadic convention"),
                );
        } else if (type.parameterList.varargs == VarArg.variadic)
            throw new Exception(
                text("ffi cannot call the variadic function `",
                    type.toString,
                    "` without its call-site argument types"),
            );

        NativeSignature signature;
        signature.linkage = linkageOf(linkage);
        signature.hasContext = hasContext;
        signature.variadic = type.parameterList.varargs == VarArg.variadic;
        signature.variadicCall = isVariadicCall;
        // A `ref` return hands back the *address* of the result in the
        // return register, not the result: that address is what travels,
        // whatever `type.nextOf` says, so the return is a pointer and
        // never needs the hidden pointer a large returned *value* would.
        // The caller gets the address and reads the value through it -
        // the call adapter in `ffi.call` applies this same convention to
        // interpreted and native callees.
        signature.returnsRef = type.isRef != 0;
        signature.hiddenReturnPointer = !signature.returnsRef
            && needsHiddenReturnPointer(type.nextOf);
        if (!signature.returnsRef && !signature.hiddenReturnPointer)
            signature.result = returnPlanOf(type.nextOf);

        foreach (i; 0 .. type.parameterList.length) {
            // A `ref` parameter occupies a pointer slot in the caller's
            // frame - the address of the argument's own storage, not a
            // copy of its value (see `FrameLayout.of` in
            // `language/layout/frame.d`, which lays such a slot out the
            // same way). That address is the value that travels, so the
            // argument is one pointer register whatever
            // `parameterList[i].type` - the *pointee* type - would
            // classify as.
            const storageClass = type.parameterList[i].storageClass;
            const isRef = (storageClass & (STC.ref_ | STC.out_)) != 0;
            auto parameterType = type.parameterList[i].type.toBasetype;
            auto pointer = parameterType.isTypePointer;
            const isFunctionPointer =
                pointer !is null && pointer.nextOf.isTypeFunction !is null;
            const isDelegate = parameterType.ty == Tdelegate
                || (storageClass & STC.lazy_) != 0;
            NativeSignature.Parameter parameter;
            parameter.indirect = isRef;
            parameter.isCallback = isFunctionPointer || isDelegate;
            parameter.isDelegate = isDelegate;
            if (!isRef)
                parameter.shape = storageClass & STC.lazy_
                    ? ArgumentPlan(
                        [
                            Register(Register.Kind.pointer, 8),
                            Register(Register.Kind.pointer, 8),
                        ],
                        2,
                        false,
                    )
                    : argumentPlanOf(type.parameterList[i].type);
            signature.parameters ~= parameter;
        }

        // A variadic call site's own extra arguments classify exactly
        // like a named parameter (ADR-0010's C-variadics paragraph).
        //
        // A function pointer or delegate extra argument gets the same
        // pool-entry swap (`callWithCallbacks`) a declared parameter of
        // that shape gets: its type is known at this call site, which is
        // all the swap needs.
        foreach (extraType; extraArgumentTypes) {
            auto base = extraType.toBasetype;
            auto pointer = base.isTypePointer;
            const isFunctionPointer =
                pointer !is null && pointer.nextOf.isTypeFunction !is null;
            const isDelegate = base.ty == Tdelegate;
            NativeSignature.Parameter parameter;
            parameter.isCallback = isFunctionPointer || isDelegate;
            parameter.isDelegate = isDelegate;
            parameter.shape = argumentPlanOf(extraType);
            signature.parameters ~= parameter;
        }

        return signature;
    }
}

