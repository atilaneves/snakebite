module snakebite.backends.loweringvisitor;


private:

import dmd.expression: CatAssignExp, EqualExp, Expression;
import dmd.visitor: Visitor;


// DMD records semantic array equality as an EqualExp lowering. Make handling
// that lowering final so a backend visitor can implement only the remaining,
// byte-comparable equality path and cannot bypass DMD's decision.
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
}
