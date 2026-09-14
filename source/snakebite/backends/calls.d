module snakebite.backends.calls;


private:


// Guest delegates and captured guest frames cannot be passed to a host
// body that expects native callable addresses and native stack frames.
// The caller supplies its ordinary target preference; symbol resolution
// stays lazy because a guest callback can make that lookup unnecessary.
public bool usesGuestBody(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.arraytypes".Expressions* arguments,
    scope bool delegate(imported!"dmd.func".FuncDeclaration) isGuest,
    lazy bool preferGuest,
    imported!"dmd.func".FuncDeclaration contextOwner = null,
) {
    import snakebite.frontend.dmd.delegates: outerFunctionOf;

    if (function_.fbody is null)
        return false;

    if (hasGuestDelegateArgument(arguments, isGuest))
        return true;

    if (contextOwner !is null && outerFunctionOf(function_) is contextOwner)
        return true;

    return preferGuest;
}

// Whether a backend should run `function_`'s own body rather than the
// machine code this process may have for it. A guest function's body is
// the one being tested, so it runs as guest even when its linker name is
// also in this process: a guest `main` mangles to `_Dmain`, which the
// host program itself exports, and calling that re-enters the host. A
// template instance is the exception, because a native instantiation, when
// there is one, is the same code the guest would have compiled.
public bool prefersGuestBody(
    imported!"dmd.func".FuncDeclaration function_,
    in bool isGuest,
    lazy bool hasNativeSymbol,
) {
    const isTemplate = function_.isInstantiated() !is null
        && function_.fbody !is null;
    return isTemplate ? !hasNativeSymbol : isGuest;
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
// `allowExtra` opts a call site into accepting more arguments than
// `parameterList.length`, positionally unmatched to any parameter: only
// the call sites that go on to read those extra arguments themselves
// pass it - a C-style variadic call's own extra arguments (issue #334
// step 5), and an `extern(D)` untyped variadic call site's own leading
// `_arguments` plus its extra arguments (issue #334 step 6), both of
// which `snakebite.ffi.plan.CallPlan.prepareVariadic` is what actually
// classifies. `VarArg.typesafe` (`T t...`) needs no such allowance: the
// frontend has already packed a typesafe call's trailing arguments into
// one array-typed argument by the time this ever runs. Every other call
// site stays exact, so none of them can silently drop arguments it
// never reads.
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
