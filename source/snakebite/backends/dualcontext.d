module snakebite.backends.dualcontext;


private:


import dmd.dsymbol: Dsymbol;
import dmd.func: FuncDeclaration;


public:


// A function with two contexts, such as a member function template
// instantiated with an alias to a nested function, takes one hidden
// argument: the address of a `void*[2]`, as dmd's own code generator passes
// it. Word 0 is the receiver for a member function, or the context of
// `toParentLocal` for a nested one. Word 1 is the context of `toParent2`,
// the function that owns the alias. The callee reads its `this` from word 0
// and finds an outer frame through whichever word `wordTowards` selects.
enum DualContext {
    receiverWord = 0,
    outerWord = 1,
    size = 2 * size_t.sizeof,
}

// Whether `function_` takes the pair. dmd decides this while it analyses
// the body, so the answer is read after that pass has run.
bool isDualContext(FuncDeclaration function_) {
    import snakebite.frontend.dmd.delegates: hasHiddenThis;

    hasHiddenThis(function_);
    return function_.hasDualContext;
}

// The byte offset in the pair of the word a lookup of `target`'s context
// follows when it passes through `function_`.
size_t wordTowards(FuncDeclaration function_, Dsymbol target) {
    import dmd.dsymbolsem: followInstantiationContext;

    const word = function_.followInstantiationContext(target)
        ? DualContext.outerWord : DualContext.receiverWord;
    return word * size_t.sizeof;
}

// The symbol whose context a lookup of `target`'s context reaches next
// after `function_`.
Dsymbol parentTowards(FuncDeclaration function_, Dsymbol target) {
    import dmd.dsymbolsem: toParentP;

    return isDualContext(function_)
        ? function_.toParentP(target) : function_.toParent2();
}

// The function whose context a nested callee receives as its hidden
// argument, or in word 0 of its pair when it has two contexts; `null`
// when that context is not a function.
FuncDeclaration nestedContextOwnerOf(FuncDeclaration function_) {
    if (!isDualContext(function_))
        return outerContextOwnerOf(function_);

    auto parent = function_.toParentLocal();
    return parent is null ? null : parent.isFuncDeclaration;
}

// The function whose context a dual-context callee receives in word 1,
// or `null` when that context is not a function.
FuncDeclaration outerContextOwnerOf(FuncDeclaration function_) {
    auto parent = function_.toParent2();
    return parent is null ? null : parent.isFuncDeclaration;
}
