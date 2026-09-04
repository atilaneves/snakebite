module snakebite.backends.loweringvisitor;


private:

import dmd.expression:
    AssocArrayLiteralExp, CastExp, CatAssignExp, CatExp, EqualExp,
    Expression, LoweredAssignExp;
import dmd.visitor: Visitor;


// DMD records semantic array equality as an EqualExp lowering. Make handling
// that lowering final so a backend visitor can implement only the remaining,
// byte-comparable equality path and cannot bypass DMD's decision.
//
// `NewExp` and `ArrayLiteralExp` are deliberately not part of this class.
// Both can carry a `lowering` whose own body is real druntime source
// (`_d_newclassT`, `_d_arrayliteralTX`) that this project's interpreter
// backend tree-walks like any other function with no native symbol to call
// through, rather than glue-layer codegen turning it into machine code -
// and that source was written assuming glue-layer codegen. `_d_newclassT`
// names a `SymbolDeclaration` synthesized for a guest class's init bytes,
// a symbol no backend here ever gives linkage to, and interpreting it
// throws inside variable resolution (`slotOf`, "not a parameter or local
// in the current frame") rather than allocating anything.
// `_d_arrayliteralTX`, reached through `AssocArrayLiteralExp`'s own
// lowering for its key and value arrays, gets further - interpreting it
// does not throw - but produces a result the subsequent
// `_d_assocarrayliteralTX` call rejects with an internal assertion
// failure, a wrong answer this project's own rule against silently wrong
// results forbids returning. Making either lowering interpretable
// correctly is new capability, not the mechanical wiring this class
// exists for, so both keep their own `override void visit` in each
// backend instead of a final one here. `ConstructExp` is left out for a
// different reason: dmd 2.112.1 has no `ConstructExp.lowering` field
// (2.113.0 added one), so a final override here would not compile against
// that version.
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
