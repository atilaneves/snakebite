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
    import dmd.funcsem: needsClosure;

    runSemantic3(function_);
    return function_.needsClosure();
}

// Runs `function_`'s body semantic, which sets `vthis`, `closureVars` and
// `hasDualContext`.
//
// `forceIfNeeded`'s own doc explains why reading `semanticRun` first,
// unlocked, and skipping the call below when it already says
// `semantic3done`, is exactly as safe as `functionSemantic3`'s own gate -
// never a guess at it. The read itself is `atomicLoad!(MemoryOrder.acq)`,
// not a plain field read - see `forceIfNeeded`'s doc for why the unlocked
// check needs that much, even though `semanticRun` is dmd's own plain
// field.
public void runSemantic3(FuncDeclaration function_) {
    import core.atomic: atomicLoad, MemoryOrder;
    import dmd.dsymbol: PASS;
    import dmd.funcsem: functionSemantic3;
    import snakebite.frontend.compiler: forceIfNeeded;

    forceIfNeeded!functionSemantic3(
        () => atomicLoad!(MemoryOrder.acq)(function_.semanticRun)
            >= PASS.semantic3done,
        function_,
    );
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
    import dmd.tokens: TOK;

    runSemantic3(function_);

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

// Whether `symbol` has two contexts: a function or aggregate template
// instantiated with an alias to a local symbol of another function or
// aggregate than the one that declares it. dmd settles this while it
// analyses a function body, so the answer for a function is read after
// that pass has run.
public bool isDualContext(Dsymbol symbol) {
    if (auto function_ = symbol.isFuncDeclaration) {
        runSemantic3(function_);
        return function_.hasDualContext;
    }

    auto aggregate = symbol.isAggregateDeclaration;
    return aggregate !is null && aggregate.vthis2 !is null;
}

// The function whose context `function_` receives as its hidden argument,
// or in word 0 of its pair when it has two contexts; `null` when no
// function encloses it. The context of a nested function that has two is
// the one of the function that declares its template, not of the function
// that owns the alias.
public FuncDeclaration nestedContextOwnerOf(FuncDeclaration function_) {
    if (!isDualContext(function_))
        return outerFunctionOf(function_);

    auto parent = function_.toParentLocal;
    while (parent !is null && parent.isFuncDeclaration is null)
        parent = parent.toParent2;
    return parent is null ? null : parent.isFuncDeclaration;
}

// What a `DelegateExp` (`&nested`) or a delegate-typed `FuncExp` (a
// closure literal bound to a delegate) needs, decided from dmd facts alone
// - nothing a particular backend's own representation of a frame or a
// closure affects. `function_` is `null` in the result when `function_` is
// null or `type` is not `Tdelegate` (a plain function pointer takes neither
// backend's delegate path at all). dmd always sets `DelegateExp.func` and
// `FuncExp.fd`, and a delegate expression always has a delegate type, so a
// backend treats a `null` result as a broken invariant.
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

    // The temporary dmd declares to hold the pair of contexts of a
    // dual-context function; the delegate's context word is its address.
    public VarDeclaration contextPair;
}

public DelegateTarget delegateTargetOf(
    FuncDeclaration function_, Type type,
    imported!"dmd.expression".Expression receiver = null,
    VarDeclaration contextPair = null,
) {
    import dmd.astenums: Tdelegate, Tstruct;
    import dmd.funcsem: isVirtualMethod;
    import dmd.typesem: toBasetype;

    if (function_ is null || type.toBasetype.ty != Tdelegate)
        return DelegateTarget.init;

    if (function_.isThis !is null)
        return DelegateTarget(function_, false, null, receiver,
            receiver !is null && receiver.type.toBasetype.ty == Tstruct,
            receiver !is null && receiver.isSuperExp is null
                && function_.isVirtualMethod, contextPair);

    if (!hasHiddenThis(function_))
        return DelegateTarget(function_, false, null);

    auto contextOwner = nestedContextOwnerOf(function_);
    if (contextOwner is null && function_.outerVars.length)
        contextOwner = outerFunctionOf(function_.outerVars[0]);
    // A literal outside every function, such as an enum member's value,
    // has no frame to point at: compiled D gives it a null context.
    return DelegateTarget(
        function_, contextOwner !is null, contextOwner,
        null, false, false, contextPair);
}
