module ut.backends.interpreter.framelayout;

import ut;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import dmd.expression: CatAssignExp;


// dmd's AST classes - `Expression` and everything under it, including
// `CallExp` and `CatAssignExp` - are declared `extern (C++)` and rooted
// at `RootObject`, not at D's `Object`. They carry no `ClassInfo` at the
// head of their vtable: `typeid(someDmdNode)` does not even compile
// ("runtime type information is not supported for `extern(C++)`
// classes"). A D dynamic cast (`cast(Derived) base`) lowers to
// `_d_dynamic_cast`, which reads `__vptr[0]` expecting a `ClassInfo*`
// there. On one of these nodes that word is the class's first virtual
// function pointer instead, so the cast walks a bogus "base chain" out
// of code bytes and can answer non-null for a type the object is not.
//
// This is the exact mistake `LocalsCollector.collectDeclarations` made
// (`cast(CatAssignExp) expression`, PR #50): a `CallExp` in a guest
// function's body was sometimes misread as a `CatAssignExp`, and
// `catAssign.lowering` then read a field at the wrong offset out of
// whatever the `CallExp` actually held - a rate-dependent-on-address
// crash, not a wrong answer any assertion here could catch by running
// the interpreter. What is not address-dependent is the underlying
// fact: for the real `CallExp`/`CatAssignExp` pairing this file cares
// about, the unsound cast does not merely risk a wrong answer, it is
// observed to always give one. This test pins that fact directly,
// rather than the crash it causes, so the pattern stays caught even
// where a real run's memory layout happens not to trigger a fault.
// dmd's own `isCatAssignExp` (what the fixed code uses) is the correct
// check: it compares `Expression.op`, so it gets this right regardless
// of memory layout.
@("collectDeclarations.dynamicCastOnDmdNodeIsUnsound")
unittest {
    auto module_ = parseSnippet(q{
        long identity(long value) { return value; }
        long useIdentity() { return identity(5); }
    });
    auto function_ = findFunction(module_, "useIdentity");
    auto compound = function_.fbody.isCompoundStatement;
    auto call = (*compound.statements)[0].isReturnStatement.exp.isCallExp;

    assert(call !is null, "expected useIdentity's body to be a CallExp");

    // The correct mechanism gets it right: a CallExp is not a
    // CatAssignExp.
    assert(
        call.isCatAssignExp is null,
        "dmd's own isCatAssignExp wrongly matched a CallExp",
    );

    // The unsound mechanism this file no longer uses does not: a bare D
    // dynamic cast reads __vptr[0] as a ClassInfo* on a class that has
    // none, and answers non-null anyway. Anyone reaching for
    // `cast(SomeExp) expression` on a dmd node instead of
    // `expression.isSomeExp` reintroduces exactly this.
    assert(
        cast(CatAssignExp) call !is null,
        "a D dynamic cast unexpectedly refused to misidentify a CallExp " ~
        "as a CatAssignExp - if dmd's class layout changed such that " ~
        "this no longer reproduces, the underlying hazard (no ClassInfo " ~
        "on an extern(C++) class) still stands; update or remove this " ~
        "test with that in mind rather than deleting it as flaky",
    );
}
