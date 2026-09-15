module snakebite.backends.temporary;


private:

import dmd.astenums: STC;


// DMD records the destructor expression on the temporary declaration. Both
// runtime backends use this predicate before they add their own execution
// record, so ownership and explicit `nodtor` transfers have one definition.
private bool ownsTemporaryDestructor(
    imported!"dmd.declaration".VarDeclaration variable,
    imported!"dmd.expression".DeclarationExp declaration,
    imported!"dmd.expression".Expression root,
    bool rootOwns = false,
) {
    return root !is null && (rootOwns || declaration !is root)
        && (variable.storage_class & STC.temp)
        && variable.edtor !is null
        && !(variable.storage_class & STC.nodtor);
}


public struct TemporaryPlan {
    import dmd.declaration: VarDeclaration;
    import dmd.expression: DeclarationExp, Expression;

    private Expression _destructor;

    public static TemporaryPlan of(
        VarDeclaration variable,
        DeclarationExp declaration,
        Expression root,
        bool rootOwns,
    ) {
        return TemporaryPlan(ownsTemporaryDestructor(
            variable, declaration, root, rootOwns) ? variable.edtor : null);
    }

    public void initialize(
        scope void delegate(Expression) register,
        scope void delegate() evaluate,
        scope void delegate() complete,
    ) const {
        // Backend visitors consume DMD's mutable graph nodes.
        if (_destructor !is null)
            register(cast() _destructor);
        evaluate();
        if (_destructor !is null)
            complete();
    }
}


// Suspension precedes argument evaluation: a throwing argument cannot leave
// an unfinished receiver eligible for destruction. DMD's nodtor metadata
// keeps a transferred value out of the caller's initialization plan.
public void constructTemporary(
    imported!"dmd.func".FuncDeclaration function_,
    scope void delegate() suspend,
    scope void delegate() evaluate,
    scope void delegate() complete,
) {
    const constructs = function_.isCtorDeclaration !is null;
    if (constructs)
        suspend();
    evaluate();
    if (constructs)
        complete();
}
