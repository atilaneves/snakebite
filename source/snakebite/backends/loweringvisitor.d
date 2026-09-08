module snakebite.backends.loweringvisitor;


private:

import dmd.expression:
    ArrayLiteralExp, AssocArrayLiteralExp, CastExp, CatAssignExp, CatExp, EqualExp,
    CatElemAssignExp, CatDcharAssignExp,
    ConstructExp, Expression, LoweredAssignExp, NewExp;
import dmd.visitor: Visitor;
import std.meta: AliasSeq;


// Every expression node dmd's semantic pass can attach a `lowering` to and
// that a backend must follow rather than walk unlowered: the one list
// `LoweringVisitor` below dispatches on, and the one list a locals-slot
// pre-pass (`snakebite.backends.layout.LocalsCollector`) must also walk into
// to find a lowering's own compiler temporaries (`__arrayliteral_on_stack*`,
// `__appendtmp*`, and so on). Add a type here and to `LoweringVisitor`
// together; a type missing from `LocalsCollector`'s side surfaces as
// `FrameLayout.offsetOf` failing to find such a temporary at run time
// rather than a compile error, which is why both consult this same list
// instead of keeping their own.
package alias LoweredExpressionTypes = AliasSeq!(
    ArrayLiteralExp, AssocArrayLiteralExp, CastExp, CatAssignExp, CatExp,
    EqualExp, LoweredAssignExp, NewExp, ConstructExp,
    CatElemAssignExp, CatDcharAssignExp);

// A frontend update must not introduce a lowering that bypasses this policy.
static foreach (name; __traits(allMembers, imported!"dmd.expression")) {
    static if (__traits(compiles,
            __traits(getMember, imported!"dmd.expression", name)))
        static assert(hasSharedLoweringPolicy!(
            __traits(getMember, imported!"dmd.expression", name)),
            name ~ " needs a final shared lowering policy");
}

// Allocation lowering produces storage; constructor execution remains on
// NewExp. Destination hooks keep that result alive across nested evaluation.
// Array literals share one exception: their AA-temporary lowering currently
// produces data that druntime rejects, so every backend uses the residual
// literal operation until that lowering can be executed correctly.
extern(C++) package abstract class LoweringVisitor: Visitor {
    alias visit = Visitor.visit;

    // DMD's semantic pass records the complete runtime append operation in
    // `lowering`. An unlowered form belongs to backend code generation, such
    // as `dchar` append, and follows the normal unsupported-expression path.
    final override void visit(CatAssignExp expression) {
        if (expression.lowering is null) {
            visit(cast(Expression) expression);
            return;
        }

        expression.lowering.accept(this);
    }

    final override void visit(EqualExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        visitUnloweredEqual(expression);
    }

    protected abstract void visitUnloweredEqual(EqualExp expression);

    final override void visit(CatElemAssignExp expression) {
        visit(cast(CatAssignExp) expression);
    }

    final override void visit(CatDcharAssignExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }
        visitUnloweredCatDcharAssign(expression);
    }

    protected abstract void visitUnloweredCatDcharAssign(
        CatDcharAssignExp expression);

    // An associative-array literal is always a call to
    // `_d_assocarrayliteralTX`; dmd leaves `lowering` null only when that
    // hook could not be found, which is refused the same as any other
    // unsupported node.
    final override void visit(AssocArrayLiteralExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        visitUnloweredAssocArrayLiteral(expression);
    }

    protected abstract void visitUnloweredAssocArrayLiteral(
        AssocArrayLiteralExp expression);

    // Most casts are native reinterpretations this visitor's own backend
    // performs directly; a `lowering` only appears where dmd has decided the
    // cast needs a druntime call of its own (an array-of-array-of-T cast,
    // for instance), and that call is what must run.
    final override void visit(CastExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        visitUnloweredCast(expression);
    }

    protected abstract void visitUnloweredCast(CastExp expression);

    // DMD lowers, for instance, dynamic-array length assignment to a native
    // druntime call so allocation, prefix preservation, and the array
    // pointer update stay in druntime rather than being emulated by a
    // backend. `LoweredAssignExp` exists only to carry a non-null
    // `lowering` (`expressionsem.d` never constructs one without one), so
    // there is no unlowered form for a backend to refuse.
    final override void visit(LoweredAssignExp expression) {
        expression.lowering.accept(this);
    }

    final override void visit(ConstructExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        visitUnloweredConstruct(expression);
    }

    protected abstract void visitUnloweredConstruct(ConstructExp expression);

    final override void visit(NewExp expression) {
        if (expression.lowering is null) {
            visitUnloweredNew(expression);
            return;
        }

        prepareNew(expression);
        scope (exit) restoreNew;
        expression.lowering.accept(this);
        visitLoweredNew(expression);
    }

    protected abstract void visitUnloweredNew(NewExp expression);

    protected abstract void prepareNew(NewExp expression);
    protected abstract void restoreNew();
    protected abstract void visitLoweredNew(NewExp expression);

    final override void visit(ArrayLiteralExp expression) {
        visitUnloweredArrayLiteral(expression);
    }

    protected abstract void visitUnloweredArrayLiteral(
        ArrayLiteralExp expression);

    // `~` concatenation is always `_d_arraycatnTX`; the one shape without a
    // `lowering` is a node this visitor does not otherwise support, the same
    // fallback `CatAssignExp` above uses for its own unlowered form.
    final override void visit(CatExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        visitUnloweredCat(expression);
    }

    protected abstract void visitUnloweredCat(CatExp expression);
}


private template hasSharedLoweringPolicy(alias Node) {
    static if (is(Node : Expression) && __traits(hasMember, Node, "lowering")) {
        import std.meta: staticIndexOf;
        enum hasSharedLoweringPolicy =
            staticIndexOf!(Node, LoweredExpressionTypes) >= 0
            && hasFinalVisit!Node;
    } else
        enum hasSharedLoweringPolicy = true;
}

private bool hasFinalVisit(Node)() {
    import std.traits: Parameters;

    static foreach (method; __traits(getOverloads, LoweringVisitor, "visit")) {
        static if (Parameters!method.length == 1) {
            static if (is(Parameters!method[0] == Node)
                    && __traits(isFinalFunction, method))
                return true;
        }
    }
    return false;
}
