module snakebite.backends.dualcontext;


private:


// A function with two contexts, such as a member function template
// instantiated with an alias to a nested function, takes one hidden
// argument: the address of a `void*[2]`, as dmd's own code generator passes
// it. Word 0 is the receiver for a member function, or the context of
// `toParentLocal` for a nested one. Word 1 is the context of `toParent2`,
// the function or the aggregate that owns the alias. The callee reads its
// `this` from word 0 and finds an outer context through whichever word
// `wordTowards` selects.
public enum DualContext {
    receiverWord = 0,
    outerWord = 1,
}

// The byte offset in the pair of the word a lookup of `target`'s context
// follows when it passes through `symbol`.
public size_t wordTowards(
    imported!"dmd.dsymbol".Dsymbol symbol,
    imported!"dmd.dsymbol".Dsymbol target,
) {
    import dmd.dsymbolsem: followInstantiationContext;

    const word = symbol.followInstantiationContext(target)
        ? DualContext.outerWord : DualContext.receiverWord;
    return word * size_t.sizeof;
}

// The byte offset in an instance of `aggregate` of the context field a
// lookup of `target`'s context follows when it passes through `aggregate`.
public size_t fieldTowards(
    imported!"dmd.aggregate".AggregateDeclaration aggregate,
    imported!"dmd.dsymbol".Dsymbol target,
) {
    import dmd.dsymbolsem: followInstantiationContext;

    return (aggregate.followInstantiationContext(target)
        ? aggregate.vthis2 : aggregate.vthis).offset;
}

// The symbol whose context a lookup of `target`'s context reaches next
// after `symbol`.
public imported!"dmd.dsymbol".Dsymbol parentTowards(
    imported!"dmd.dsymbol".Dsymbol symbol,
    imported!"dmd.dsymbol".Dsymbol target,
) {
    import dmd.dsymbolsem: toParentP;
    import snakebite.frontend.dmd.delegates: isDualContext;

    return isDualContext(symbol)
        ? symbol.toParentP(target) : symbol.toParent2();
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
        // The `this` of the member function `function_`, followed through
        // the context fields at the byte offsets in `fields`: the context
        // is an object, not a frame, when the symbol that encloses the
        // callee is an aggregate. When `function_` has two contexts, its
        // hidden argument is the address of a pair, and the `this` to start
        // from is the word at `pairOffset` in it, not the receiver.
        receiver,
    }

    public Kind kind;
    public FuncDeclaration function_;
    public const(size_t)[] fields;
    public bool throughPair;
    public size_t pairOffset;
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
    imported!"dmd.func".FuncDeclaration caller,
    imported!"dmd.func".FuncDeclaration callee,
    imported!"dmd.declaration".VarDeclaration pair,
) {
    import snakebite.frontend.dmd.delegates: isDualContext;

    if (!isDualContext(callee))
        return PairPlan.init;

    if (pair is null)
        assert(0,
            "dmd declares the pair for each call of a dual-context function");
    return PairPlan(
        pair,
        DualContext.receiverWord * size_t.sizeof,
        DualContext.outerWord * size_t.sizeof,
        contextSourceOf(caller, callee.toParent2()),
    );
}

// The source, as seen from `caller`, of the context of `owner`: the symbol
// that encloses a callee, or that a nested aggregate was made in.
public ContextSource contextSourceOf(
    imported!"dmd.func".FuncDeclaration caller,
    imported!"dmd.dsymbol".Dsymbol owner,
) {
    if (owner is null)
        return ContextSource.init;

    if (auto function_ = owner.isFuncDeclaration)
        return ContextSource(ContextSource.Kind.frame, function_);

    return receiverSourceOf(caller, owner);
}

// The context of an aggregate is the `this` of one of its member
// functions, which `caller` reaches along its static chain. `getEthis` in
// dmd's code generator walks the same chain: the member function is the
// last function before the chain leaves for `owner`, and each nested
// aggregate between them adds the load of one of its context fields. The
// chain also ends at a class derived from `owner`, whose members have the
// `this` of `owner` as theirs.
private ContextSource receiverSourceOf(
    imported!"dmd.func".FuncDeclaration caller,
    imported!"dmd.dsymbol".Dsymbol owner,
) {
    import dmd.dsymbol: Dsymbol;
    import dmd.func: FuncDeclaration;
    import snakebite.frontend.dmd.delegates: isDualContext;

    ContextSource receiverFrom(FuncDeclaration member, const(size_t)[] fields) {
        const throughPair = isDualContext(member);
        return ContextSource(
            ContextSource.Kind.receiver,
            member,
            fields,
            throughPair,
            throughPair ? member.wordTowards(owner) : 0,
        );
    }

    FuncDeclaration member;
    const(size_t)[] fields;
    Dsymbol symbol = caller;
    while (symbol !is null) {
        if (auto function_ = symbol.isFuncDeclaration) {
            member = function_;
            fields = null;
        } else if (auto aggregate = symbol.isAggregateDeclaration) {
            // `auto`: `isBaseOf` is not callable on a `const` class.
            auto base = owner.isClassDeclaration;
            if (base !is null && aggregate.isClassDeclaration !is null
                    && base.isBaseOf(aggregate.isClassDeclaration, null))
                return receiverFrom(member, fields);

            if (!aggregate.isNested || aggregate.vthis is null)
                assert(0, "an aggregate on the path to an enclosing this "
                    ~ "is nested or derives from the owner");
            fields ~= aggregate.fieldTowards(owner);
        } else
            break;

        auto next = symbol.parentTowards(owner);
        if (next is owner)
            return receiverFrom(member, fields);
        symbol = next;
    }

    assert(0, "dmd's code generator gives a path from the caller to the "
        ~ "this of the aggregate that owns the alias, or reports an error");
}
