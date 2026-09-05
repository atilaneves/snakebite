module snakebite.backends.delegates;


private:


import dmd.declaration: Declaration, VarDeclaration;
import dmd.dsymbol: Dsymbol;
import dmd.func: FuncDeclaration;
import dmd.mtype: Type;


// `__ctfe`: dmd's own semantic pass (`expressionsem.d`) introduces this
// `VarDeclaration` wherever guest source reads `__ctfe`, sharing one
// instance across the whole compile rather than declaring it in any
// function's own frame - `outerFunctionOf` on it resolves to `null`, which
// both backends would otherwise read as "not a local variable this
// function can address" and reject outright. dmd's own code generator
// defines it as `false` at run time (`true` is reserved for dmd's CTFE
// engine, which never calls into either backend), so both backends fold a
// read of it to a constant `false` instead of resolving it as a variable.
// Compare the interned identifier, not source spelling that guest code
// could imitate.
public bool isCtfeVariable(Declaration variable) {
    import dmd.id: Id;

    return variable.ident is Id.ctfe;
}


// Whether `function_` needs a heap-allocated closure rather than living in
// its caller's own activation frame, as dmd's own escape analysis already
// decided (`FuncDeclaration.needsClosure`, `funcsem.d`): its address was
// taken by something that can escape the function that declared it, or one
// of its own nested functions does. Both backends ask dmd this same
// question before deciding whether a captured variable's storage is a
// frame slot or a slot in a heap block, so it is asked here once rather
// than reimplemented per backend.
public bool functionNeedsClosure(FuncDeclaration function_) {
    import dmd.funcsem: needsClosure;

    return function_.needsClosure();
}

// Whether `function_` receives a hidden `this`/context argument before its
// declared parameters: an ordinary member method or constructor, or a
// nested function that reads an outer member function's `this` implicitly.
//
// `vthis` is a local variable `functionSemantic3` (body semantic) creates,
// so it stays unset until that pass has run - forcing it here is what lets
// this answer be trusted for a native declaration neither backend ever
// walks the body of, such as `object.Exception`'s constructor, reached
// through a guest exception class's `super(...)`. Forcing it a second time
// for a function already past that pass is a no-op: `functionSemantic3`
// checks `semanticRun` itself. `FrameLayout.of`, the FFI call plan, and a
// call site's own argument count all ask this one function, so the three
// cannot disagree about whether a given callee takes a hidden `this`.
public bool hasHiddenThis(FuncDeclaration function_) {
    import dmd.funcsem: functionSemantic3;
    import dmd.tokens: TOK;

    functionSemantic3(function_);

    if (function_.vthis is null)
        return false;

    // dmd only clears a `FuncLiteralDeclaration`'s `vthis` when the
    // literal is coerced to a target pointer type at the point it is
    // written (`expressionsem.d`'s `visit(FuncExp)`); a lambda bound
    // through `auto`, with no target type to coerce to, keeps a `vthis`
    // nothing in its body ever reads. Two things must both hold before
    // that `vthis` counts as dead: `tok` must not have settled on
    // `TOK.delegate_` - dmd's own lazy-argument lowering builds its
    // implicit delegate directly with that `tok`, and it does read the
    // enclosing frame through `vthis` despite never appearing in
    // `closureVars` the way a written closure's own captures do - and
    // `closureVars` itself must be empty, proof nothing else is captured
    // either.
    auto literal = function_.isFuncLiteralDeclaration;
    const deadContext = literal !is null && literal.tok != TOK.delegate_
        && literal.closureVars.length == 0;
    return !deadContext;
}

// The nearest enclosing function `symbol` (a captured variable or a nested
// function) is declared in, or `null` if it is declared at module scope -
// `toParent2` already walks past any block or `Catch` scope that is not a
// `Dsymbol` of its own, straight to the nearest enclosing function or
// aggregate. Shared because a captured variable's owner (`VarDeclaration.
// toParent2`) and a delegate's own target's parent (`FuncDeclaration.
// toParent2`, see `delegateTargetOf` below) are both resolved the same way.
public FuncDeclaration outerFunctionOf(Dsymbol symbol) {
    auto parent = symbol.toParent2();
    return parent is null ? null : parent.isFuncDeclaration;
}

// What a `DelegateExp` (`&nested`) or a delegate-typed `FuncExp` (a
// closure literal bound to a delegate) needs, decided from dmd facts alone
// - nothing a particular backend's own representation of a frame or a
// closure affects. `function_` is `null` in the result when the caller
// must reject the expression outright: dmd left no declaration to resolve
// (`DelegateExp.func`/`FuncExp.fd` can be null for an expression this
// project's frontend usage never actually produces, but both backends
// checked it defensively before this was factored out), the function is a
// bound method (`isThis`, out of scope for both backends - a method's
// receiver is a `this` argument, not a static-chain context to resolve),
// or `type` is not actually `Tdelegate` (a plain function pointer takes
// neither backend's delegate path at all).
//
// `needsContext` is `false` when `function_` reads nothing from any
// enclosing scope (`outerVars` empty and `functionNeedsClosure` false): its
// delegate value's context word is always null, whatever backend fills it
// in, and `contextOwner` is left `null` too since nothing ever reads it.
// When `needsContext` is `true`, `contextOwner` is the function whose
// context (frame or heap closure, `functionNeedsClosure(contextOwner)`
// decides which) the delegate's context word must resolve to - `null`
// there instead means `function_` is nested directly in module scope with
// something to capture, which cannot happen: only a function nested in
// another function ever has `outerVars`/needs a closoure of its own.
public struct DelegateTarget {
    public FuncDeclaration function_;
    public bool needsContext;
    public FuncDeclaration contextOwner;
}

public DelegateTarget delegateTargetOf(FuncDeclaration function_, Type type) {
    import dmd.astenums: Tdelegate;

    if (function_ is null || function_.isThis() !is null
            || type.ty != Tdelegate)
        return DelegateTarget.init;

    if (function_.outerVars.length == 0 && !functionNeedsClosure(function_))
        return DelegateTarget(function_, false, null);

    return DelegateTarget(function_, true, outerFunctionOf(function_));
}
