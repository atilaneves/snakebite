module snakebite.backends.calls;


private:


// Guest delegates and captured guest frames cannot be passed to a host
// body that expects native callable addresses and native stack frames.
// The caller supplies its ordinary target preference; symbol resolution
// stays lazy because a guest callback can make that lookup unnecessary.
//
// A callee with an outer function reads that function's frame through
// the static chain, which only this compiler's own frame layout can
// supply - a native instantiation of the same nested function would
// read the enclosing frame at the offsets the host compiler gave it
// instead. This is why any such callee runs as guest, not only one
// nested directly in the function being compiled: `contextAddressOf`/
// `tryContextOf` already walk the static chain up from wherever
// execution currently is, one hop per level of nesting, to reach any
// ancestor's frame, so a sibling nesting level resolves the same way a
// direct child does. A template's own nested lambda - druntime's
// `_d_aaApply2`'s `_toAA` cast, for one - is where this shows: that
// lambda has a native instance the host links, and calling it there
// hands it a guest frame it cannot read (#275).
public bool usesGuestBody(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.arraytypes".Expressions* arguments,
    scope bool delegate(imported!"dmd.func".FuncDeclaration) isGuest,
    lazy bool preferGuest,
) {
    import snakebite.frontend.dmd.delegates: outerFunctionOf;

    if (function_.fbody is null)
        return false;

    if (hasGuestDelegateArgument(arguments, isGuest))
        return true;

    if (outerFunctionOf(function_) !is null)
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
