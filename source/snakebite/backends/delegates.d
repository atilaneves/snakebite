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
