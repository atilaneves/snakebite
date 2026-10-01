module snakebite.backends.dualcontext;


private:


// A function with two contexts, such as a member function template
// instantiated with an alias to a nested function, takes one hidden
// argument: the address of a `void*[2]`, as dmd's own code generator passes
// it. Word 0 is the receiver for a member function, or the context of
// `toParentLocal` for a nested one. Word 1 is the context of `toParent2`,
// the function that owns the alias. The callee reads its `this` from word 0
// and finds an outer frame through whichever word `wordTowards` selects.
public enum DualContext {
    receiverWord = 0,
    outerWord = 1,
    size = 2 * size_t.sizeof,
}

// The byte offset in the pair of the word a lookup of `target`'s context
// follows when it passes through `function_`.
public size_t wordTowards(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.dsymbol".Dsymbol target,
) {
    import dmd.dsymbolsem: followInstantiationContext;

    const word = function_.followInstantiationContext(target)
        ? DualContext.outerWord : DualContext.receiverWord;
    return word * size_t.sizeof;
}

// The symbol whose context a lookup of `target`'s context reaches next
// after `function_`.
public imported!"dmd.dsymbol".Dsymbol parentTowards(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.dsymbol".Dsymbol target,
) {
    import dmd.dsymbolsem: toParentP;
    import snakebite.frontend.dmd.delegates: isDualContext;

    return isDualContext(function_)
        ? function_.toParentP(target) : function_.toParent2();
}

// Where a context pointer that a call or a delegate hands to its callee
// comes from.
public struct ContextSource {
    import dmd.func: FuncDeclaration;

    public enum Kind {
        // No function encloses the callee, so compiled D passes null.
        none,
        // The frame, or the closure, of `function_`.
        frame,
    }

    public Kind kind;
    public FuncDeclaration function_;
}

// What a call or a delegate to a dual-context function stores before it
// passes the address of the pair. The pair is the variable that dmd
// declares for it in the caller (`CallExp.vthis2`, `DelegateExp.vthis2`),
// so the backends give it the storage of any other local and it lives as
// long as that local does. A callee with one context has no pair, and
// `variable` is `null`.
public struct PairPlan {
    import dmd.declaration: VarDeclaration;

    public VarDeclaration variable;
    // Byte offsets in the pair of the receiver (or of the context of the
    // function that declares the callee) and of the outer context.
    public size_t receiverOffset;
    public size_t outerOffset;
    // The source of the outer context.
    public ContextSource outer;
}

public PairPlan pairPlanOf(
    imported!"dmd.func".FuncDeclaration callee,
    imported!"dmd.declaration".VarDeclaration pair,
) {
    import snakebite.frontend.dmd.delegates: isDualContext;

    if (!isDualContext(callee))
        return PairPlan.init;

    assert(pair !is null,
        "dmd declares the pair for each call of a dual-context function");
    return PairPlan(
        pair,
        DualContext.receiverWord * size_t.sizeof,
        DualContext.outerWord * size_t.sizeof,
        contextSourceOf(callee.toParent2()),
    );
}

// The source of the context of `owner`, the symbol that encloses a callee.
public ContextSource contextSourceOf(
    imported!"dmd.dsymbol".Dsymbol owner,
) {
    auto function_ = owner is null ? null : owner.isFuncDeclaration;
    return function_ is null
        ? ContextSource.init
        : ContextSource(ContextSource.Kind.frame, function_);
}
