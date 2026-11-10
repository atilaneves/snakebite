module snakebite.backends.contextsource;


private:


import snakebite.backends.contextpair:
    DualContext, fieldTowards, parentTowards, wordTowards;
import snakebite.failure.report: internalFailure;


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
        // The `this` of the function that makes the call, which overrides
        // `function_`: an inherited `in` or `out` contract is a nested
        // function of `function_`, and reads nothing of its context but
        // that function's `this`. The context is the address that makes
        // this read, at `slotOffset` from it, find the receiver moved by
        // `receiverAdjustment` to the view of `function_`'s class.
        overrider,
    }

    public Kind kind;
    public FuncDeclaration function_;
    public const(size_t)[] fields;
    public bool throughPair;
    public size_t pairOffset;
    public size_t receiverAdjustment;
    public size_t slotOffset;
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
        internalFailure("dmd declares the pair for each call of a dual-context function");
    return PairPlan(
        pair,
        DualContext.receiverWord * size_t.sizeof,
        DualContext.outerWord * size_t.sizeof,
        contextSourceOf(caller, callee.toParent2()),
    );
}

// The source of the context that a call from `caller` hands to the nested
// function `callee`. dmd's code generator gives the `__require` and
// `__ensure` of an overridden function to the overriding function that
// calls them: the call is the `in` contract merged into an override, and
// the same holds for `out`.
public ContextSource calleeContextSourceOf(
    imported!"dmd.func".FuncDeclaration caller,
    imported!"dmd.func".FuncDeclaration callee,
    ref imported!"snakebite.native.argumentflow".SignatureTable signatures,
) {
    import snakebite.frontend.dmd.delegates: nestedContextOwnerOf;

    auto owner = nestedContextOwnerOf(callee);
    if (owner is null || owner is caller || !isContract(callee)
            || !overrides(caller, owner))
        return contextSourceOf(caller, owner);

    return overriderSourceOf(caller, owner, signatures);
}

private bool isContract(imported!"dmd.func".FuncDeclaration function_) {
    import dmd.id: Id;

    return function_.ident == Id.require || function_.ident == Id.ensure;
}

private bool overrides(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (overridden; function_.foverrides[])
        if (overridden is base || overrides(overridden, base))
            return true;
    return false;
}

private ContextSource overriderSourceOf(
    imported!"dmd.func".FuncDeclaration caller,
    imported!"dmd.func".FuncDeclaration owner,
    ref imported!"snakebite.native.argumentflow".SignatureTable signatures,
) {
    import snakebite.backends.closureplan: ClosurePlan;
    import snakebite.language.layout.frame: FrameLayout;

    int adjustment;
    const isBase = owner.isThis.isClassDeclaration.isBaseOf(
        caller.isThis.isClassDeclaration, &adjustment);
    if (!isBase)
        internalFailure("an overridden method belongs to a base of the overrider");

    const closure = ClosurePlan.of(owner);
    const layout = FrameLayout.of(owner, signatures);
    // `auto`: `hasSlot` and `offsetOf` take a mutable `VarDeclaration`.
    auto variable = cast() layout.hiddenThis.variable;
    const slotOffset = closure.needsClosure && closure.layout.hasSlot(variable)
        ? closure.layout.slotOf(variable).offset
        : layout.offsetOf(variable);
    return ContextSource(
        ContextSource.Kind.overrider, owner, null, false, 0, adjustment,
        slotOffset);
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
                internalFailure("an aggregate on the path to an enclosing this "
                    ~ "is nested or derives from the owner");
            fields ~= aggregate.fieldTowards(owner);
        } else
            break;

        auto next = symbol.parentTowards(owner);
        if (next is owner)
            return receiverFrom(member, fields);
        symbol = next;
    }

    internalFailure("dmd's code generator gives a path from the caller to the "
        ~ "this of the aggregate that owns the alias, or reports an error");
}
