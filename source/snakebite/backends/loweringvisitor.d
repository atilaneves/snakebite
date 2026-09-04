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
//
// `NewExp.lowering`, for a class, is a call to `core.lifetime._d_newclassT`
// (allocation only - the constructor call dmd leaves on `expression.member`
// itself is never part of it). Both the interpreter (`walker.d`,
// `visit(NewExp)`) and the bytecode compiler (`compiler.d`,
// `compileNewClass`) now run that lowering - tree-walked in one, compiled
// as an ordinary guest call in the other - and then run the constructor
// call it left out themselves. `_d_newclassT` names a `SymbolDeclaration`
// for the class's own `.init` bytes (`__traits(initSymbol, T)`); each
// backend's `visit(VarExp)` reads that back from its own class runtime
// info (`classRuntimeInfo`/`fillFieldInits` in the interpreter,
// `classRuntimeInfo`/`fillFieldInits` in the bytecode compiler) rather
// than resolving a symbol neither backend ever gives linkage to. What
// keeps `NewExp` out of this class is that extra constructor-call step:
// a single final `accept(this)` dispatch has nowhere to hang it, and each
// backend's own override still has to refuse the shapes that leave
// `lowering` null for a reason of its own (`onstack`/`scope class` here,
// `-betterC` in general) rather than mechanically falling through to one
// shared unlowered hook. A struct allocated with `new` (`_d_newitemT`,
// the same `NewExp.lowering` field) is not routed through its own
// lowering by either backend yet; both still allocate and initialize it
// by hand.
//
// `ArrayLiteralExp.lowering` is only ever set once, for the key and
// value array literals inside an `AssocArrayLiteralExp`'s own lowering
// (`expressionsem.d`, `lowerArrayLiteral`, called only from
// `AssocArrayLiteralExp` semantic) - an ordinary top-level array literal
// never gets one; the `_d_arrayliteralTX` call real compiled code makes
// for one is glue-layer codegen (`e2ir.d`) this project has no glue layer
// to reach, not anything dmd's semantic pass records here. Even where
// `lowering` is set, compiling it is confirmed unsafe: the interpreter
// can tree-walk `_d_arrayliteralTX`'s body without throwing, but the
// result is one the following `_d_assocarrayliteralTX` call rejects with
// an internal assertion failure - a wrong answer this project's own rule
// against silently wrong results forbids returning. Both backends ignore
// that `lowering` and build the array by hand instead
// (`snakebite.backends.interpreter.walker`,
// `snakebite.backends.bytecode.compiler`, each own `visit(ArrayLiteralExp)`
// comment). Making that lowering safe to interpret is new capability, not
// the mechanical wiring this class exists for.
//
// `ConstructExp` is left out for a different reason: dmd 2.112.1 has no
// `ConstructExp.lowering` field (2.113.0 added one), so a final override
// here would not compile against that version.
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
