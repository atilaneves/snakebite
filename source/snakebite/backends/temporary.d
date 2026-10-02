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


// Whether a variable can point into the temporaries of its own
// initialiser: it can hold a pointer, and the initialiser builds an
// aggregate value that no variable owns. A backend that keeps those
// temporaries for the rest of the call decides from this alone, so a
// function without such a variable pays nothing.
public bool canRetainTemporaries(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.typesem: hasPointers;

    if (variable._init is null)
        return false;
    auto initializer = variable._init.isExpInitializer;
    if (initializer is null)
        return false;

    return ((variable.storage_class & STC.ref_) != 0
            || variable.type.hasPointers)
        && buildsAggregateValue(initializer.exp);
}

private bool buildsAggregateValue(
    imported!"dmd.expression".Expression initializer,
) {
    import dmd.astenums: Tsarray, Tstruct;
    import dmd.expression: Expression;
    import dmd.expressionsem: isLvalue;
    import dmd.typesem: toBasetype;
    import dmd.visitor: StoppableVisitor;
    import dmd.visitor.postorder: walkPostorder;

    extern(C++) static final class Finder: StoppableVisitor {
        alias visit = StoppableVisitor.visit;

        override void visit(Expression expression) {
            if (expression.type is null)
                return;
            const ty = expression.type.toBasetype.ty;
            if ((ty == Tstruct || ty == Tsarray) && !expression.isLvalue)
                stop = true;
        }
    }

    // The right side is the value; the left side of a construction is
    // the variable.
    if (auto construct = initializer.isConstructExp)
        initializer = construct.e2;
    else if (auto blit = initializer.isBlitExp)
        initializer = blit.e2;

    scope finder = new Finder;
    return walkPostorder(initializer, finder);
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
