module snakebite.frontend.dmd.delegates;


private:


import dmd.declaration: Declaration, VarDeclaration;
import dmd.dsymbol: Dsymbol;
import dmd.expression: Expression;
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
//
// `closureVars`, the variables the analysis walks, are collected by
// `functionSemantic3` (body semantic), so the answer is only trustworthy
// after that pass - forced here for the same reason `hasHiddenThis` below
// forces it: a function dmd never analysed eagerly (one in a non-root
// module, reached through a delegate) would otherwise answer `false` to
// one backend and, once analysed, `true` to the other.
public bool functionNeedsClosure(FuncDeclaration function_) {
    import dmd.dsymbol: PASS;
    import dmd.funcsem: functionSemantic3, needsClosure;
    import snakebite.frontend.compiler: forceIfNeeded;

    // `forceIfNeeded`'s own doc explains why reading `semanticRun`
    // first, unlocked, and skipping the call below when it already says
    // `semantic3done`, is exactly as safe as `functionSemantic3`'s own
    // gate - never a guess at it.
    forceIfNeeded(
        () => function_.semanticRun >= PASS.semantic3done,
        () { functionSemantic3(function_); },
    );
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
//
// `declareThis`, the one place dmd itself ever assigns `vthis`, only runs
// while walking a body (`semantic3.d` gates the whole block on `fbody`,
// or an in/out contract) - `Exception.this` has one, even though neither
// backend walks it, because dmd's own semantic still does. A declaration
// with no body anywhere - an `extern(C++)` method or constructor bound to
// a host library, with nothing for `functionSemantic3` to walk - never
// runs `declareThis` at all, so `vthis` stays null whether or not the
// declaration takes a hidden `this`. `isThis()`/`isNested()` answer that
// same question directly, from the declaration alone, with no body
// required, and agree with `vthis` on every case that does have a body:
// `declareThis` sets `vthis` from exactly those two facts (deliberately
// leaving it null when both are false), and its own dead-context lambda
// case, below, only ever narrows a non-null `vthis` to unused, never
// widens a null one.
public bool hasHiddenThis(FuncDeclaration function_) {
    import dmd.dsymbol: PASS;
    import dmd.funcsem: functionSemantic3;
    import dmd.tokens: TOK;
    import snakebite.frontend.compiler: forceIfNeeded;

    // As `functionNeedsClosure`'s own guarded force: skips the frontend
    // lock once `function_` is already past `semantic3`, which is
    // exactly the condition `functionSemantic3` itself checks before
    // doing anything.
    forceIfNeeded(
        () => function_.semanticRun >= PASS.semantic3done,
        () { functionSemantic3(function_); },
    );

    // Inferred function pointers can retain the provisional context variable
    // that DMD created before it knew whether the lambda captured anything.
    if (auto literal = function_.isFuncLiteralDeclaration)
        if (literal.tok != TOK.delegate_)
            return false;

    if (function_.vthis is null)
        return function_.isThis() !is null || function_.isNested();

    // A delegate call always passes its context word, even when the
    // function does not use it. Keep the slot so a delegate target and its
    // caller use one native layout.
    return true;
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
    while (parent !is null) {
        if (auto function_ = parent.isFuncDeclaration)
            return function_;
        parent = parent.toParent2();
    }
    return null;
}

// What a `DelegateExp` (`&nested`) or a delegate-typed `FuncExp` (a
// closure literal bound to a delegate) needs, decided from dmd facts alone
// - nothing a particular backend's own representation of a frame or a
// closure affects. `function_` is `null` in the result when the caller
// must reject the expression outright: dmd left no declaration to resolve
// (`DelegateExp.func`/`FuncExp.fd` can be null for an expression this
// project's frontend usage never actually produces, but both backends
// checked it defensively before this was factored out),
// or `type` is not actually `Tdelegate` (a plain function pointer takes
// neither backend's delegate path at all).
//
// A hidden context can be needed by a call to another nested function,
// even when this function reads no outer variables itself. Keep that link
// whenever the frontend gives the function a hidden context parameter.
// `contextOwner` identifies the enclosing frame or heap closure it needs.
public struct DelegateTarget {
    public FuncDeclaration function_;
    public bool needsContext;
    public FuncDeclaration contextOwner;
    public Expression receiver;
    public bool receiverIsAddress;
    public bool virtualDispatch;
}

public DelegateTarget delegateTargetOf(
    FuncDeclaration function_, Type type,
    imported!"dmd.expression".Expression receiver = null,
) {
    import dmd.astenums: Tdelegate, Tstruct;
    import dmd.funcsem: isVirtualMethod;

    if (function_ is null || type.ty != Tdelegate)
        return DelegateTarget.init;

    if (function_.isThis !is null)
        return DelegateTarget(function_, false, null, receiver,
            receiver !is null && receiver.type.ty == Tstruct,
            receiver !is null && receiver.isSuperExp is null
                && function_.isVirtualMethod);

    if (!hasHiddenThis(function_))
        return DelegateTarget(function_, false, null);

    auto contextOwner = outerFunctionOf(function_);
    if (contextOwner is null && function_.outerVars.length)
        contextOwner = outerFunctionOf(function_.outerVars[0]);
    return DelegateTarget(function_, true, contextOwner);
}
