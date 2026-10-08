module snakebite.backends.loweringvisitor;


private:

import dmd.expression:
    ArrayLiteralExp, AssocArrayLiteralExp, CastExp, CatAssignExp, CatExp,
    CmpExp, EqualExp, HaltExp, LogicalExp,
    CatElemAssignExp, CatDcharAssignExp,
    ConstructExp, Expression, IdentityExp, LoweredAssignExp, NewExp, ThrowExp,
    TupleExp;
import dmd.statement:
    ExpStatement, IfStatement, ReturnStatement,
    SwitchErrorStatement, SwitchStatement, ThrowStatement, WithStatement;
import dmd.location: Loc;
import dmd.typesem: isString;
import snakebite.backends.fullexpression: FullExpressionScope;
import snakebite.backends.identity: IdentityPlan, identityPlan;
import snakebite.backends.logical: LogicalPlan, logicalPlan;
import snakebite.backends.ifplan: IfPlan, ifPlan;
import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;
import snakebite.backends.aggregateinit: NewPlan, planNew;
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

    // The statements and operands that end a full expression are opened
    // here, so no backend can forget one; the positions are listed in
    // `FullExpressionScope.Position`. A position that a backend's own control
    // flow owns (a loop's condition, a `switch` operand) goes through
    // `fullExpression` too. `withFullExpression` is the backend's hook and
    // nothing else calls it.
    extern(D) protected abstract void withFullExpression(
        in FullExpressionScope.Position position,
        Expression root,
        scope void delegate() evaluate,
    );

    extern(D) protected abstract bool readsResultAfterEnd(
        in FullExpressionScope.Position position,
        Expression result,
    );

    extern(D) protected final void fullExpression(
        in FullExpressionScope.Position position,
        Expression root,
        scope void delegate() evaluate,
    ) {
        withFullExpression(position, root, evaluate);
    }

    final override void visit(ExpStatement statement) {
        if (statement.exp is null)
            return;

        fullExpression(FullExpressionScope.Position.expressionStatement,
            statement.exp, { visitExpressionStatement(statement); });
    }

    final override void visit(SwitchErrorStatement statement) {
        assert(statement.exp !is null,
            "dmd always gives a `SwitchErrorStatement` its `__switch_error` call");
        fullExpression(FullExpressionScope.Position.switchError,
            statement.exp, { visitSwitchError(statement); });
    }

    // dmd ends the full expression of a `throw` operand before it starts
    // the throw, so a destructor of an operand temporary that throws
    // replaces the exception the operand built.
    final override void visit(ThrowStatement statement) {
        throwOperand(statement.exp);
    }

    final override void visit(ThrowExp expression) {
        throwOperand(expression.e1);
    }

    private void throwOperand(Expression operand) {
        const afterEnd = readsResultAfterEnd(
            FullExpressionScope.Position.throwOperand, operand);
        size_t thrown;
        fullExpression(FullExpressionScope.Position.throwOperand,
            operand, { thrown = visitThrowOperand(operand, afterEnd); });
        visitThrowTransfer(operand, thrown, afterEnd);
    }

    // The initialiser of the `with` handle is a full expression of its own:
    // its temporaries die before the body runs.
    final override void visit(WithStatement statement) {
        if (statement.wthis !is null) {
            auto initializer = statement.wthis._init.isExpInitializer;
            assert(initializer !is null,
                "a with statement temporary has an expression initializer");
            fullExpression(FullExpressionScope.Position.withOperand,
                initializer.exp, { visitWithOperand(statement); });
        }
        visitWithBody(statement);
    }

    // The operand of `return` is evaluated before the function starts to
    // return: a throw from the operand leaves with an exception, and no
    // handler or cleanup that runs then may see a pending return. Which
    // cleanups the transfer runs is the shared unwind plan's decision. The
    // temporaries of the operand die when it has been evaluated, whether
    // the function returns a value or a `ref`.
    final override void visit(ReturnStatement statement) {
        if (statement.exp is null) {
            enum readsAfterEnd = false;
            visitReturnOperand(statement, readsAfterEnd);
        } else {
            const afterEnd = readsResultAfterEnd(
                FullExpressionScope.Position.returnOperand, statement.exp);
            fullExpression(FullExpressionScope.Position.returnOperand,
                statement.exp, { visitReturnOperand(statement, afterEnd); });
        }
        visitReturnTransfer(statement);
    }

    protected abstract void visitExpressionStatement(ExpStatement statement);
    protected abstract void visitSwitchError(SwitchErrorStatement statement);
    // With `readsAfterEnd` the operand is an lvalue that dmd reads after the
    // destructors of its temporaries ran: the backend resolves its address
    // here and moves the value in `visitReturnTransfer`. A `ref` return
    // yields the address either way.
    protected abstract void visitReturnOperand(
        ReturnStatement statement, bool readsAfterEnd);
    protected abstract void visitReturnTransfer(ReturnStatement statement);

    final override void visit(IfStatement statement) {
        visitIf(statement, ifPlan(statement));
    }

    protected abstract void visitIf(IfStatement statement, in IfPlan plan);

    // How many `if (__ctfe)` bodies the walk is inside. A callee is not
    // inside the body that calls it, so a backend that walks callees with
    // the same visitor resets this at a call.
    protected uint ctfeBlockDepth;

    // A backend walks the body of an `if (__ctfe)` block through this, so
    // that the decision below knows where it is.
    extern(D) protected final void inCtfeBlock(scope void delegate() walk) {
        ++ctfeBlockDepth;
        scope (exit)
            --ctfeBlockDepth;

        walk();
    }

    // dmd compiles the body of an `if (__ctfe)` block for compile time only
    // and leaves some constructs in it without the lowering they get
    // everywhere else. Run-time code gets into that body through a `case`
    // label. Reaching such a construct there throws an `Error` that the
    // guest can catch. Returns whether the construct was in such a body, in
    // which case the backend has thrown and must not compile it.
    extern(D) protected final bool throwIfUnloweredInCtfeBlock(
        in string construct, in Loc loc,
    ) {
        import std.string: fromStringz;

        if (ctfeBlockDepth == 0)
            return false;

        visitCtfeBlockError(
            construct ~ " in the body of an if (__ctfe) block: dmd compiles "
                ~ "that body for compile time only",
            loc.filename.fromStringz.idup, loc.linnum);
        return true;
    }

    extern(D) protected abstract void visitCtfeBlockError(
        string message, string file, size_t line,
    );

    // dmd lowers a `switch` on a string only when it generates code, so the
    // condition of one in an `if (__ctfe)` body is still a string.
    protected final bool throwIfStringSwitchInCtfeBlock(
        SwitchStatement statement,
    ) {
        if (!statement.condition.type.isString)
            return false;

        return throwIfUnloweredInCtfeBlock("string switch", statement.loc);
    }

    protected abstract void visitWithOperand(WithStatement statement);
    protected abstract void visitWithBody(WithStatement statement);

    // Evaluates the operand and returns a backend-defined handle for the
    // object it made. The handle is a plain number because a destructor of
    // an operand temporary can run during a collection, where a throw must
    // not allocate. The shared visitor passes it to `visitThrowTransfer`
    // once the full expression has ended. With `readsAfterEnd` the handle
    // is the address of the object reference, which the transfer reads.
    protected abstract size_t visitThrowOperand(
        Expression operand, bool readsAfterEnd);
    protected abstract void visitThrowTransfer(
        Expression operand, size_t thrown, bool readsAfterEnd);

    // DMD's semantic pass leaves `lowering` null in a scope that needs no
    // code generation, and dmd's glue cannot compile such an append. In an
    // `if (__ctfe)` body that a `case` label reaches, the guest gets an
    // `Error`; anywhere else it halts.
    final override void visit(CatAssignExp expression) {
        if (expression.lowering is null) {
            if (!throwIfUnloweredInCtfeBlock("~= append", expression.loc))
                visitHalt;
            return;
        }

        expression.lowering.accept(this);
    }

    final override void visit(HaltExp) {
        visitHalt;
    }

    protected abstract void visitHalt();

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

    // The right operand of `&&` and `||` is a full expression
    // (`FullExpressionScope.Position.logicalOperand`): the backend opens it
    // around the operand, because only the backend knows where the branch
    // that skips it goes.
    final override void visit(LogicalExp expression) {
        visitLogical(expression, logicalPlan(expression));
    }

    protected abstract void visitLogical(
        LogicalExp expression, in LogicalPlan plan);

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
    // hook could not be found, and dmd then reports an error, so a backend
    // never runs such a literal.
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
        auto plan = planNew(expression);
        if (plan.destination != NewPlan.Destination.lowering) {
            visitUnloweredNew(expression, plan);
            return;
        }

        // dmd sets no lowering on a heap `new` in a scope that needs no code
        // generation, and, except for a class, also under `-betterC`.
        if (expression.lowering is null) {
            if (!throwIfUnloweredInCtfeBlock("heap new", expression.loc))
                visitUnloweredNew(expression, plan);
            return;
        }

        prepareNew(expression);
        scope (exit) restoreNew;
        expression.lowering.accept(this);
        visitLoweredNew(expression);
    }

    protected abstract void visitUnloweredNew(
        NewExp expression, NewPlan plan,
    );

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
    // surrounding destination once `run` returns.
    //
    // `evaluateElement`, `storeConstant`, `storeAddress`, and `copyBytes`
    // are ordinary execution primitives that carry no array-literal
    // knowledge of their own, but they are valid only inside
    // `withTemporaryDestination`'s `run` delegate, since all four act on
    // the temporary it opened:
    // - `evaluateElement` writes the element at a byte offset from the
    //   address the temporary *holds* (the pointer `_d_arrayliteralTX`
    //   returned into it), not from the temporary's own address.
    // - `storeConstant` writes a constant at a byte offset into the
    //   *surrounding* destination that `withTemporaryDestination` saved,
    //   not into the temporary.
    // - `storeAddress` copies the temporary's own *value* - the pointer
    //   `_d_arrayliteralTX` returned - to a byte offset in that surrounding
    //   destination.
    // - `copyBytes` copies bytes from the address the temporary holds into
    //   that surrounding destination.
    // A backend runs each one immediately (the interpreter) or emits an op
    // for the VM to run later (the bytecode compiler). Deciding the element
    // count, the per-element byte offsets, and whether the result is a
    // dynamic array, a pointer, or a static array stays here, shared,
    // instead of being re-derived by each backend.
    final override void visit(ArrayLiteralExp expression) {
        import dmd.astenums: Tpointer;
        import dmd.typesem: nextOf, toBasetype;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;

        if (expression.lowering !is null) {
            requireLiteralDestination(expression);
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

    // Called before a lowered literal's temporary is set up, so a backend
    // whose result can be discarded gives the stores below a destination.
    protected void requireLiteralDestination(ArrayLiteralExp expression) {
    }

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

    // `~` concatenation is always `_d_arraycatnTX`; dmd leaves `lowering`
    // null under `-betterC` (`trySetCatExpLowering`), where it uses no GC.
    final override void visit(CatExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        if (!throwIfUnloweredInCtfeBlock("~ concatenation", expression.loc))
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
