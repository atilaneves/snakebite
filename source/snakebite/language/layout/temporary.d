module snakebite.language.layout.temporary;


private:

import snakebite.frontend.ast: STC;


// DMD records the destructor expression on the temporary declaration. Both
// runtime backends use this predicate before they add their own execution
// record, so ownership and explicit `nodtor` transfers have one definition.
private bool ownsTemporaryDestructor(
    imported!"snakebite.frontend.ast".VarDeclaration variable,
    imported!"snakebite.frontend.ast".DeclarationExp declaration,
    imported!"snakebite.frontend.ast".Expression root,
    bool rootOwns = false,
) {
    return root !is null && (rootOwns || declaration !is root)
        && hasTemporaryDestructor(variable);
}

// Whether `variable` is a temporary that dmd gives a destructor, which runs
// when the full expression that owns it ends.
public bool hasTemporaryDestructor(
    imported!"snakebite.frontend.ast".VarDeclaration variable,
) {
    return (variable.storage_class & STC.temp)
        && variable.edtor !is null
        && !(variable.storage_class & STC.nodtor);
}


// Whether a variable can point into the temporaries of its own
// initialiser: it can hold a pointer, and the initialiser builds an
// aggregate value that no variable owns. A backend that keeps those
// temporaries for the rest of the call decides from this alone, so a
// function without such a variable pays nothing.
public bool canRetainTemporaries(
    imported!"snakebite.frontend.ast".VarDeclaration variable,
) {
    import snakebite.frontend.ast: hasPointers;

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
    imported!"snakebite.frontend.ast".Expression initializer,
) {
    import snakebite.frontend.ast: Expression, isLvalue, StoppableVisitor,
        Tsarray, Tstruct, walkPostorder;
    import snakebite.frontend.typefacts: baseType;

    extern(C++) static final class Finder: StoppableVisitor {
        alias visit = StoppableVisitor.visit;

        override void visit(Expression expression) {
            if (expression.type is null)
                return;
            const ty = expression.type.baseType.ty;
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
    import snakebite.frontend.ast: DeclarationExp, Expression, VarDeclaration;

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
    imported!"snakebite.frontend.ast".FuncDeclaration function_,
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
