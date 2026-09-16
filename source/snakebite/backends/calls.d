module snakebite.backends.calls;


private:


// A call's target rules and cached declaration preference belong together.
// Argument-dependent guest requirements must run before symbol resolution:
// a host body cannot read a captured guest frame.
public struct CallSelection {
    // Holds a `SharedTable` (finding 2.4): a copy would share its
    // storage with the original until one side grows.
    @disable this(this);

    import dmd.func: FuncDeclaration;
    import dmd.arraytypes: Expressions;

    import snakebite.sharedtable: SharedTable;

    // The three dmd-touching questions `usesGuestBody` answers about a
    // function alone, without its call site's own arguments: whether a
    // C-style variadic call must always go native, whether the function
    // nests inside another (so it needs this backend's own static
    // chain), and the same-declaration preference every call falls back
    // to otherwise. All three come from `dmd.astenums`/`typeFunctionOf`/
    // `outerFunctionOf`/`isInstantiated`, which touch dmd's shared,
    // mutable frontend state (finding 1.2), so they are decided once per
    // function, under the compiler lock, and read back without one.
    private struct Decision {
        bool variadicRejects;
        bool hasOuter;
        bool prefers;
    }

    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a decision is built once per function.
    private SharedTable!(FuncDeclaration, Decision) _decisions;

    public bool usesGuestBody(
        FuncDeclaration function_,
        Expressions* arguments,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        in string backend,
    ) {
        if (function_.fbody is null)
            return false;

        if (auto cached = function_ in _decisions)
            return decide(*cached, arguments, isGuest);

        import snakebite.frontend.compiler: withCompilerLock;

        Decision decision;
        withCompilerLock({
            if (auto found = function_ in _decisions) {
                decision = *found;
                return;
            }
            decision = buildDecision(function_, hasNativeSymbol, isGuest);
            _decisions.insert(function_, decision);
        });
        return decide(decision, arguments, isGuest);
    }

    // Called under the compiler lock only: every dmd query a function's
    // decision needs, resolved once and never again.
    private static Decision buildDecision(
        FuncDeclaration function_,
        lazy bool hasNativeSymbol,
        scope bool delegate(FuncDeclaration) isGuest,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.frontend.dmd.delegates: outerFunctionOf;

        const type = typeFunctionOf(function_);
        if (type.parameterList.varargs == VarArg.variadic
                && (!type.isDstyleVariadic || hasNativeSymbol))
            return Decision(true, false, false);

        // This includes siblings and deeper nested callees: every static
        // chain points into frames whose offsets belong to this backend.
        if (outerFunctionOf(function_) !is null)
            return Decision(false, true, false);

        // A root-owned body must run as guest even when its linker name
        // is in the host (notably _Dmain). A template can reuse the host
        // instantiation; a missing template symbol leaves its guest body.
        const prefers = function_.isInstantiated() !is null
            ? !hasNativeSymbol : isGuest(function_);
        return Decision(false, false, prefers);
    }

    private static bool decide(
        in Decision decision,
        Expressions* arguments,
        scope bool delegate(FuncDeclaration) isGuest,
    ) {
        if (decision.variadicRejects)
            return false;
        if (hasGuestDelegateArgument(arguments, isGuest))
            return true;
        return decision.hasOuter || decision.prefers;
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

private bool hasGuestDelegateArgument(
    imported!"dmd.arraytypes".Expressions* arguments,
    scope bool delegate(imported!"dmd.func".FuncDeclaration) isGuest,
) {
    import dmd.func: FuncDeclaration;

    if (arguments is null)
        return false;

    foreach (argument; *arguments) {
        auto expression = argument; // Casts do not change the target body.
        while (auto cast_ = expression.isCastExp)
            expression = cast_.e1;

        FuncDeclaration function_;
        if (auto literal = expression.isFuncExp)
            function_ = literal.fd;
        else if (auto delegate_ = expression.isDelegateExp)
            function_ = delegate_.func;

        if (function_ !is null && isGuest(function_))
            return true;
    }
    return false;
}
