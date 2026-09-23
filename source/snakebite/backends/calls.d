module snakebite.backends.calls;


private:


// Delegate values use native callback entries, so captured guest contexts
// do not change whether the receiving function executes as guest or host.
public struct CallSelection {
    // Holds a `SharedTable` (finding 2.4): a copy would share its
    // storage with the original until one side grows.
    @disable this(this);

    import dmd.func: BUILTIN, FuncDeclaration;

    import snakebite.backends.builtins: BuiltinCall, ParameterType;
    import snakebite.sharedtable: SharedTable;

    // Every call site resolves to exactly one of these. `guest` and
    // `native` are the two routes `usesGuestBody` always answered;
    // `builtin` is the third one this backend adds for a bodiless
    // function dmd itself classifies as a compiler intrinsic (`dmd.
    // builtin.isBuiltin`) - `core.math.fabs` and friends, which have no
    // host symbol FFI could ever resolve (they compile to an inline
    // instruction, not a call). `snakebite.backends.builtins` holds the
    // wrapper `builtinEntry` calls for that route.
    public enum Route { guest, native, builtin }

    // The dmd-touching questions a function's route needs, decided once
    // per function and read back without a lock (ADR-0006, finding
    // 1.2): whether a C-style variadic call must always go native,
    // whether the function nests inside another (so it needs this
    // backend's own static chain), the same-declaration preference
    // every call falls back to otherwise, and - for a bodiless
    // function - whether dmd classifies it as a compiler intrinsic this
    // backend has a wrapper for. `route` and `builtinEntry` together,
    // rather than two separate lookups, so a builtin call site - the
    // interpreter's hot path included - reads this cache once per call,
    // not twice.
    public struct Decision {
        public Route route;
        public BuiltinCall builtinEntry;
    }

    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a decision is built once per function.
    private SharedTable!(FuncDeclaration, Decision) _decisions;

    // `function_`'s full routing decision. The one call every hot path
    // wants: a single cache lookup carries both the route and, for
    // `builtin`, the wrapper to call - `usesGuestBody` below is the one
    // narrower, route-only caller still reaches for.
    //
    // No frontend lock here at all (measured: 7,721 acquisitions, 61.3s
    // wait, in a parallel `bin/ut` run before this fix) - every dmd
    // field `buildDecision` reads (`fbody`, `type`, `parent`, `vtbl`'s
    // `isInstantiated`/`isFuncLiteralDeclaration` classification) is set
    // by dmd's ordinary declaration/type semantic (phase 1), not lazily
    // deferred to a body walk (`semantic3`) the way `functionNeedsClosure`/
    // `hasHiddenThis`'s own fields are - a `FuncDeclaration` this ever
    // sees has already had its own signature resolved by whatever
    // frontend pass made it a valid call target in the first place, so
    // there is no dmd forward reference here to force at all, only a
    // cache miss to fill. `_decisions` is a `SharedTable`, which brings
    // its own insert lock (ADR-0006), so nothing about this cache needs
    // the frontend one - the same reasoning `snakebite.backends.
    // interpreter.walker`'s `Cache.build` already applies to its own
    // caches.
    public Decision decisionOf(
        FuncDeclaration function_,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
    ) {
        if (auto cached = function_ in _decisions)
            return *cached;

        return *_decisions.insert(
            function_,
            buildDecision(
                function_, hasNativeSymbol, hasIndependentNativeSymbol,
                isGuest,
            ),
        );
    }

    // Whether `function_`'s own body should interpret/compile - the one
    // question every caller that never needs a builtin's wrapper (only
    // `callableAddress`, in both backends, taking a function's address as
    // a value) still asks. A caller that also wants the builtin wrapper
    // itself should read `decisionOf` directly instead of calling this
    // and `decisionOf` both, which would pay the cache lookup twice.
    public bool usesGuestBody(
        FuncDeclaration function_,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
    ) {
        return decisionOf(
            function_, isGuest, hasNativeSymbol, hasIndependentNativeSymbol,
        ).route == Route.guest;
    }

    // Every dmd query a function's decision needs, resolved once and
    // never again - no lock, `decisionOf`'s own doc explains why none of
    // these reads needs one.
    private static Decision buildDecision(
        FuncDeclaration function_,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
        scope bool delegate(FuncDeclaration) isGuest,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.frontend.dmd.delegates: outerFunctionOf;

        // A declaration without a body can only describe a native call or
        // a builtin - never a guest one, since there is no guest body to
        // run.
        if (function_.fbody is null)
            return builtinDecision(function_);

        const type = typeFunctionOf(function_);
        if (type.parameterList.varargs == VarArg.variadic
                && (!type.isDstyleVariadic || hasNativeSymbol))
            return Decision(Route.native);

        // This includes siblings and deeper nested callees: every static
        // chain points into frames whose offsets belong to this backend.
        if (outerFunctionOf(function_) !is null)
            return Decision(Route.guest);

        // A function literal in an imported aggregate has a body but no
        // native symbol of its own. Keep it guest when it is root-owned or
        // when the linker cannot resolve that symbol.
        if (function_.isFuncLiteralDeclaration !is null
                && function_.fbody !is null
                && (isGuest(function_) || !hasNativeSymbol))
            return Decision(Route.guest);

        // A root-owned body must run as guest even when its linker name
        // is in the host (notably _Dmain). A template instance can reuse
        // a native copy only when that copy is independent of the running
        // executable - the dependency image or an already-loaded shared
        // object (ADR-0008, ADR-0009). The executable's own copy is never
        // preferred: snakebite instantiates plenty of the same templates a
        // guest program also instantiates (`dirEntries` in
        // `snakebite.project` among them), and that copy's nested closures
        // carry the host compiler's frame layout, not this backend's -
        // reusing it for a guest call reads that closure with the wrong
        // layout. A missing independent symbol leaves the guest body.
        const prefers = function_.isInstantiated() !is null
            ? !hasIndependentNativeSymbol : isGuest(function_);
        return Decision(prefers ? Route.guest : Route.native);
    }

    // Asks dmd for `function_`'s own compiler-intrinsic classification
    // (`dmd.builtin.isBuiltin`) - the *only* dmd query this backend ever
    // makes about a builtin; `dmd.builtin.eval_builtin` (dmd's CTFE
    // evaluator) is never called here or anywhere at run time. A
    // function dmd does not classify (`BUILTIN.unimp`) - every ordinary
    // bodiless native declaration, and also, today, `core.math.rint` and
    // `core.math.rndtol`, which dmd's own `BUILTIN` enum has no member
    // for - keeps the native route FFI already handles. A function dmd
    // does classify but this table has no wrapper for fails loudly here,
    // at decision time, rather than at the call's first execution.
    private static Decision builtinDecision(FuncDeclaration function_) {
        import dmd.builtin: isBuiltin;
        import snakebite.backends.builtins: entryOf;
        import snakebite.exception: SnakebiteException;
        import std.conv: text;

        const kind = isBuiltin(function_);
        if (kind == BUILTIN.unimp)
            return Decision(Route.native);

        // dmd's own classification (`BUILTIN.popcnt` for the declared
        // identifier `_popcnt`, for one) does not always echo the
        // identifier back as its bare name, but the table's key is
        // every one of those identifiers - the same one dmd's own
        // `determine_builtin` keys on (`dmd/builtin.d`: `id3 = fd.
        // ident`) - so `function_.ident` is the lookup key, not `kind`.
        auto entry = entryOf(
            function_.ident.toString.idup, parameterTypeOf(function_));
        if (entry is null)
            throw new SnakebiteException(text(
                "snakebite has no builtin wrapper for `",
                function_.toString, "`, which dmd classifies as `",
                kind, "`"));

        return Decision(Route.builtin, entry);
    }

    // The concrete type `function_`'s own first parameter declares - the
    // half of `snakebite.backends.builtins.entryOf`'s lookup key dmd's
    // `BUILTIN` classification does not carry, since it goes by name
    // alone: `sin(float)` and `sin(double)` both classify as `BUILTIN.
    // sin`, and `bswap(uint)`/`bswap(ulong)` both classify as `BUILTIN.
    // bswap`. Every builtin this table serves takes at least one
    // argument of the type its result (or, for `ldexp`'s second
    // argument, an unrelated `int`) shares.
    private static ParameterType parameterTypeOf(FuncDeclaration function_) {
        import dmd.astenums: Tfloat32, Tfloat64, Tfloat80,
            Tuns16, Tuns32, Tuns64;
        import snakebite.exception: SnakebiteException;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import std.conv: text;

        // `const` fails: `ParameterList.length` and `opIndex` are not
        // `const` methods.
        auto parameterList = typeFunctionOf(function_).parameterList;
        if (parameterList.length == 0)
            throw new SnakebiteException(text(
                "snakebite's builtin table has no entry for `",
                function_.toString, "`, which takes no parameters"));

        const parameterType = parameterList[0].type;
        switch (parameterType.ty) {
            case Tfloat32: return ParameterType.float_;
            case Tfloat64: return ParameterType.double_;
            case Tfloat80: return ParameterType.real_;
            case Tuns16: return ParameterType.ushort_;
            case Tuns32: return ParameterType.uint_;
            case Tuns64: return ParameterType.ulong_;
            default:
                throw new SnakebiteException(text(
                    "snakebite's builtin table has no entry for `",
                    function_.toString, "`'s first parameter type `",
                    parameterType.toString, "`"));
        }
    }
}

// Whether a call site's own argument list has the wrong length for
// `parameterList` - the one check every call-compiling and call-binding
// site makes before reading arguments positionally against parameters,
// whether the callee is a resolved declaration, a bare `TypeFunction`
// reached through a pointer or delegate value, or a constructor's own
// parameter list. Typesafe `T t...` arrives as one array-typed argument
// by the time this ever runs (the frontend already packed it), so this
// stays exact for that variadic kind too.
//
// A variadic parameter list (`VarArg.variadic`) only requires *at
// least* its declared parameters: a C-style variadic call site's own
// extra arguments (issue #334 step 5) sit past `parameterList.length`
// in `arguments`; an `extern(D)` untyped variadic call site adds its own
// leading `_arguments` too (issue #334 step 6), at index `0`, ahead of
// the declared parameters, not past them - only the call's total
// argument count exceeds `parameterList.length`, by one for
// `_arguments` and again for each of its own extra arguments past that.
// Either way, nothing here need know an extra argument's own count or
// types, positionally unmatched to any parameter - only whoever builds
// the call's own plan does (`snakebite.ffi.plan.CallPlan.
// prepareVariadic`). `VarArg.typesafe`
// (`T t...`) needs no such allowance: the frontend has already packed a
// typesafe call's trailing arguments into one array-typed argument by
// the time this ever runs, so `>=` never actually admits more arguments
// than `parameterList.length` for that kind.
public bool arityMismatches(
    imported!"dmd.mtype".ParameterList parameterList,
    imported!"dmd.arraytypes".Expressions* arguments,
    in bool allowExtra = false,
) {
    const count = arguments is null ? 0 : arguments.length;
    return allowExtra
        ? count < parameterList.length
        : count != parameterList.length;
}

// An indirect call - one whose callee `expression.e1` is a bare value,
// not a resolved `FuncDeclaration` - is a delegate call whenever that
// value's own type is `Tdelegate`, never mind whether dmd's parser put a
// `PtrExp` there. `key in aa` on an associative array of delegates, and
// `&someDelegateVariable`, both give a *pointer to a delegate*; calling
// through either dereferences with the same `(*p)(args)` syntax dmd
// itself lowers a bare function-pointer call to (`fn(args)` becomes
// `(*fn)(args)`, see `snakebite.backends.layout.FrameLayout.
// ofParameters`'s own callers). Reading the syntax instead of `e1.type`
// mistakes that delegate-pointer dereference for the function-pointer
// shape it merely resembles: `deref.e1`, the pointer's own pointee, is a
// `Tdelegate`, not the `Tfunction` a function pointer's pointee always
// is, so a function-pointer read off it is nonsense. Either shape leaves
// `e1` itself as the one expression to evaluate for the callee's value -
// the delegate's own two words when `e1.type` is `Tdelegate` (dereferenced
// already, whatever the syntax), or, when it is a `PtrExp` and dmd's
// lowering leaves `e1.type` the pointed-to `Tfunction`, that `PtrExp`'s
// own `e1` for the function pointer's single word.
public bool isIndirectDelegateCall(
    imported!"dmd.mtype".Type calleeType,
) {
    import dmd.astenums: Tdelegate;

    return calleeType !is null && calleeType.ty == Tdelegate;
}
