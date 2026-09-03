module snakebite.backends.loweringvisitor;


private:

import dmd.expression: EqualExp;
import dmd.visitor: Visitor;


// DMD records semantic array equality as an EqualExp lowering. Make handling
// that lowering final so a backend visitor can implement only the remaining,
// byte-comparable equality path and cannot bypass DMD's decision.
extern(C++) package abstract class LoweringVisitor: Visitor {
    alias visit = Visitor.visit;

    final override void visit(EqualExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        visitUnloweredEqual(expression);
    }

    protected abstract void visitUnloweredEqual(EqualExp expression);
}
