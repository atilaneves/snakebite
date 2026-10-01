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

// The function whose context a dual-context callee receives in word 1,
// or `null` when that context is not a function.
public imported!"dmd.func".FuncDeclaration outerContextOwnerOf(
    imported!"dmd.func".FuncDeclaration function_,
) {
    auto parent = function_.toParent2();
    return parent is null ? null : parent.isFuncDeclaration;
}
