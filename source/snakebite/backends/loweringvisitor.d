module snakebite.backends.loweringvisitor;


private:

import dmd.expression:
    ArrayLiteralExp, AssocArrayLiteralExp, CastExp, CatAssignExp, CatExp,
    CmpExp, EqualExp,
    CatElemAssignExp, CatDcharAssignExp,
    ConstructExp, Expression, IdentityExp, LoweredAssignExp, NewExp, ThrowExp,
    TupleExp;
import dmd.statement: ThrowStatement;
import snakebite.backends.identity: IdentityPlan, identityPlan;
import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;
import dmd.visitor: Visitor;
import dmd.mtype: Type;
import snakebite.nativelayout: TypeFacts;
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
extern(C++) package abstract class LoweringVisitor: Visitor {
    alias visit = Visitor.visit;

    final override void visit(ThrowStatement statement) {
        visitThrowStatement(statement);
    }

    final override void visit(ThrowExp expression) {
        visitThrowExp(expression);
    }

    protected abstract void visitThrowStatement(ThrowStatement statement);
    protected abstract void visitThrowExp(ThrowExp expression);

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

    final override void visit(IdentityExp expression) {
        visitIdentity(expression, identityPlan(expression));
    }

    final override void visit(CmpExp expression) {
        visitComparison(expression, comparisonPlan(expression));
    }

    protected abstract void visitComparison(
        CmpExp expression, in ComparisonPlan plan);

    protected abstract void visitIdentity(
        IdentityExp expression, in IdentityPlan plan);

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

    // dmd's expressionSemantic (`expressionsem.d`) attaches `lowering` - a
    // call to `_d_newclassT` and friends - to every heap `NewExp` before
    // dsymbolsem (`dsymbolsem.d`) decides a `scope` variable's initialiser
    // can live on the stack and sets `onstack` on that same node, without
    // clearing `lowering`. dmd's own glue layer (`glue/e2ir.d`) checks
    // `onstack` (and `placement`) first and ignores `lowering` when either
    // is set; a backend that dispatches on `lowering !is null` alone would
    // run the heap-allocating lowering for a `scope` variable of an
    // ordinary (non-`scope`) class instead of taking the on-stack path.
    final override void visit(NewExp expression) {
        if (expression.onstack || expression.placement !is null) {
            visitUnloweredNew(expression);
            return;
        }

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

    // DMD's tuple expansion stores a side-effecting receiver in `e0`; it must
    // run before the field expressions, which then retain their own lowering
    // and assignment semantics through this visitor.
    final override void visit(TupleExp expression) {
        if (expression.e0 !is null)
            visitTupleElement(expression.e0);

        if (expression.exps !is null)
            foreach (element; *expression.exps)
                visitTupleElement(element);
    }

    protected abstract void visitTupleElement(Expression expression);

    // A lowered literal's own `_d_arrayliteralTX` call needs somewhere to
    // put its result before this visitor can read the address back out of
    // it, so `withTemporaryDestination` substitutes a temporary of the
    // lowering's own type for the surrounding destination while `run`
    // evaluates the call and every element into it, then restores the
    // surrounding destination once `run` returns. `evaluateElement`,
    // `storeConstant`, `storeAddress`, and `copyBytes` are ordinary
    // execution primitives - "evaluate an expression at an offset from the
    // temporary", "write a constant", "write the temporary's own address",
    // "copy bytes out of it" - that carry no array-literal knowledge of
    // their own; a backend runs each one immediately (the interpreter) or
    // emits an op for the VM to run later (the bytecode compiler). Deciding
    // the element count, the per-element byte offsets, and whether the
    // result is a dynamic array, a pointer, or a static array stays here,
    // shared, instead of being re-derived by each backend.
    final override void visit(ArrayLiteralExp expression) {
        import dmd.astenums: Tpointer;
        import dmd.typesem: nextOf, toBasetype;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;

        if (expression.lowering !is null) {
            const temporaryFacts = TypeFacts.of(expression.lowering.type);
            withTemporaryDestination(
                    expression.lowering.type, temporaryFacts, {
                expression.lowering.accept(this);

                const count = expression.elements is null
                    ? 0 : expression.elements.length;
                auto elementType = expression.type.nextOf;
                const elementFacts = TypeFacts.of(elementType);
                foreach (i; 0 .. count)
                    evaluateElement(
                        expression[i], elementType, elementFacts,
                        i * elementFacts.size,
                    );

                const facts = TypeFacts.of(expression.type);
                if (facts.isDynamicArray) {
                    storeConstant(count, arrayLengthOffset);
                    storeAddress(arrayPointerOffset);
                } else if (expression.type.toBasetype.ty == Tpointer)
                    storeAddress(0);
                else
                    copyBytes(facts.size);
            });
            return;
        }

        visitUnloweredArrayLiteral(expression);
    }

    protected abstract void visitUnloweredArrayLiteral(
        ArrayLiteralExp expression);

    extern(D) protected abstract void withTemporaryDestination(
        Type type, in TypeFacts facts, scope void delegate() run,
    );
    protected abstract void evaluateElement(
        Expression element, Type elementType, in TypeFacts facts,
        in size_t byteOffset,
    );
    protected abstract void storeConstant(
        in size_t value, in size_t byteOffset,
    );
    protected abstract void storeAddress(in size_t byteOffset);
    protected abstract void copyBytes(in size_t width);

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
