module snakebite.frontend.dmd.mangle;


private:


// A function's type is not complete until dmd has run semantic on its
// body when the type is inferred: `auto`/`auto ref` return types, and
// attribute inference (`pure`, `nothrow`, `@nogc`, `@safe`, `scope`/
// `return` on parameters) for a template, an `auto` function, a nested
// function, or a lambda. Compiled D never mangles, calls, or classifies
// such a function before its own semantic reaches the expression that
// first needs it - taking its address, calling it, instantiating it -
// because `dmd.funcsem.functionSemantic` is the one gate every such site
// in dmd's own frontend (`expressionsem.d`, `typesem.d`) calls first.
// Snakebite mangles and classifies functions on demand, long after any
// particular guest program decided it needed one, so nothing upstream
// guarantees `functionSemantic` already ran for it - this calls that
// exact function, rather than re-deriving its conditions (`inferRetType`,
// the `STC.inference` attribute-inference flag - `funcsem.d`), so the
// answer can never drift from dmd's own.
//
// `functionSemantic` itself decides whether `functionSemantic3` (body
// semantic) is actually required - a function with no inference pending
// returns immediately without forcing it. Every site below that reads or
// mangles a `FuncDeclaration`'s type must call this (directly, or through
// `mangledNameOf`) before it does, or before `dmd.mangle.mangleExact`
// ever sees the declaration: `mangleExact` caches its answer on the
// declaration itself (`fd.mangleString`) the first time it runs, so one
// premature call poisons that cache for the rest of the process.
public void completeFunctionType(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import core.atomic: atomicLoad, MemoryOrder;
    import dmd.dsymbol: PASS;
    import dmd.funcsem: functionSemantic;
    import snakebite.frontend.compiler: forceIfNeeded;

    // Acquire load - see `snakebite.frontend.compiler.forceIfNeeded`'s
    // own doc for why the unlocked check needs that much, not a plain
    // field read. A function with nothing left to infer never reaches
    // `PASS.semantic3done` through `functionSemantic` alone (it returns
    // without forcing `functionSemantic3` at all), so this ready check
    // only ever skips the lock for a function some other forcing call -
    // this one or `snakebite.frontend.dmd.delegates`'s - already drove
    // all the way through; every other function retakes the lock and
    // calls `functionSemantic` again, which is exactly as cheap as dmd's
    // own repeat calls from `expressionsem.d`/`typesem.d`, never a guess
    // at when it is safe to skip.
    forceIfNeeded(
        () => atomicLoad!(MemoryOrder.acq)(function_.semanticRun)
            >= PASS.semantic3done,
        () { functionSemantic(function_); },
    );
}

// As `completeFunctionType`, for every `FuncDeclaration` `symbol` is
// mangled inside of, including `symbol` itself when it is one. A nested
// symbol's own mangled name recurses through each enclosing declaration's
// name (`dmd.mangle.package.mangleParent`), and, for a `FuncDeclaration`
// parent, through that function's own mangled signature - so that parent's
// type must already be complete the same way `symbol`'s own would need to
// be. Walks `Dsymbol.parent`, the same chain `mangleParent` itself walks,
// not `toParent2` (a different, closure-ownership chain `snakebite.
// frontend.dmd.delegates` uses for a different question).
public void completeMangleTargets(imported!"dmd.dsymbol".Dsymbol symbol) {
    for (auto current = symbol; current !is null; current = current.parent)
        if (auto function_ = current.isFuncDeclaration)
            completeFunctionType(function_);
}

// The complete, dmd-exact mangled linker name of `function_`, for
// resolving its native address or registering it under a dependency
// image's linker name. The one function every such site must call
// instead of `dmd.mangle.mangleExact` directly - see `completeFunctionType`
// for why a direct call can be wrong.
public const(char)[] mangledNameOf(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    completeMangleTargets(function_);
    return mangleExact(function_).fromStringz;
}
