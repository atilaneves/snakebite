module snakebite.backends.contextpair;


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

// The offset in the pair of the object that a constructor with two contexts
// constructs. The constructor takes the pair as its hidden argument, but
// the object that it yields (and that its temporary is armed for) is the
// receiver word of the pair, as in dmd's code generator.
public enum constructedObjectOffset = DualContext.receiverWord * size_t.sizeof;

// Whether the hidden argument of `function_` is a pair that holds the
// object of a constructor.
public bool constructsThroughPair(imported!"dmd.func".FuncDeclaration function_) {
    import snakebite.frontend.dmd.delegates: isDualContext;

    return function_.isCtorDeclaration !is null && isDualContext(function_);
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
