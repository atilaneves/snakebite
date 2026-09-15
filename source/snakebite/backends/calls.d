module snakebite.backends.calls;


private:


// A call's target rules and cached declaration preference belong together.
// Argument-dependent guest requirements must run before symbol resolution:
// a host body cannot read a captured guest frame.
public struct CallSelection {
    import dmd.func: FuncDeclaration;
    import dmd.arraytypes: Expressions;

    private bool[FuncDeclaration] _preferences;

    public bool usesGuestBody(
        FuncDeclaration function_,
        Expressions* arguments,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        in string backend,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.frontend.dmd.delegates: outerFunctionOf;
        import snakebite.exception: SnakebiteException;
        import std.conv: text;

        if (function_.fbody is null)
            return false;

        // The barrier supports these calls, but neither backend executes
        // a guest body that reads the hidden variadic locals (ADR-0010).
        if (typeFunctionOf(function_).parameterList.varargs
                == VarArg.variadic) {
            if (isGuest(function_) && !hasNativeSymbol)
                throw new SnakebiteException(text(
                    backend, " cannot call `", function_.toString,
                    "`: guest-bodied D variadic functions are not ",
                    "interpreted yet",
                ));
            return false;
        }

        if (hasGuestDelegateArgument(arguments, isGuest))
            return true;

        // This includes siblings and deeper nested callees: every static
        // chain points into frames whose offsets belong to this backend.
        if (outerFunctionOf(function_) !is null)
            return true;

        if (auto cached = function_ in _preferences)
            return *cached;

        // A root-owned body must run as guest even when its linker name
        // is in the host (notably _Dmain). A template can reuse the host
        // instantiation; a missing template symbol leaves its guest body.
        const prefers = function_.isInstantiated() !is null
            ? !hasNativeSymbol : isGuest(function_);
        _preferences[function_] = prefers;
        return prefers;
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
