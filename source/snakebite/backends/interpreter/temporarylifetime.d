module snakebite.backends.interpreter.temporarylifetime;


private:

import dmd.declaration: VarDeclaration;
import dmd.expression: DeclarationExp, Expression, StructLiteralExp;
import snakebite.backends.temporary: TemporaryPlan;
import snakebite.backends.temporarystack: TemporaryStack;
import snakebite.backends.fullexpression:
    FullExpressionKind, FullExpressionScope;
import snakebite.framestack: FrameStack, defaultFrameCapacity;
import snakebite.nativelayout: TypeFacts;


// Owns the storage and lifetime rules for expression-scoped guest values.
// The evaluator supplies only the operation which executes a DMD-built
// destructor expression. This keeps destruction in DMD's AST while making
// every lifetime transition happen at one seam.
public final class TemporaryLifetime {
    private alias Action = void delegate();
    private alias Destroy = extern(C++) void delegate(Expression);
    private alias Initialize = extern(C++) void delegate(
        StructLiteralExp,
        TypeFacts,
        ubyte*,
    );

    private struct Temporary {
        StructLiteralExp node;
        FrameStack.Mark mark;
        ubyte* base;
        Expression edtor;
    }

    private struct ExpressionState {
        size_t mark;
        size_t stackMark;
        size_t floor;
    }

    private Temporary[] _temporaries;
    private TemporaryStack _stack;
    private FrameStack _frames;
    private size_t _floor;
    private FullExpressionScope _expressions;
    private ExpressionState[] _expressionStates;
    private size_t _expressionDepth;
    private Destroy _destroy;

    public this(Destroy destroy) {
        _frames = FrameStack(defaultFrameCapacity);
        // Reserve the usual call nesting without putting an allocation in
        // the steady-state expression path. Recursive calls can grow this
        // stack when they exceed the initial depth.
        _expressionStates.length = 16;
        _destroy = destroy;
    }

    // Runs a top-level call with a clean expression lifetime. This is also
    // the unwind backstop for a guest call that exits before a statement
    // visitor gets control again.
    public void withCall(scope Action action) {
        const state = _expressions.suspendCall;
        scope (exit) _expressions.resumeCall(state);
        withLifetime(0, action);
    }

    public void withNestedCall(scope Action action) {
        const state = _expressions.suspendCall;
        scope (exit) _expressions.resumeCall(state);
        action();
    }

    public void withExpression(
        FullExpressionKind kind,
        Expression root,
        scope Action action,
    ) {
        _expressions.run(kind, cast(const(void)*) root,
            { beginExpression; }, action, { endExpression; });
    }

    // Gives a nested evaluation its own temporary pairing and cleanup
    // scope, without changing which declaration is the expression root.
    public void withTemporaryLifetime(scope Action action) {
        withLifetime(_temporaries.length, action);
    }

    public void initialize(
        VarDeclaration variable,
        DeclarationExp declaration,
        ubyte* base,
        scope Action evaluate,
    ) {
        const plan = TemporaryPlan.of(variable, declaration,
            cast(Expression) _expressions.root,
            _expressions.rootOwnsTemporary);
        plan.initialize((Expression destructor) {
            const payload = _temporaries.length;
            _temporaries ~= Temporary(null, _frames.mark, base, destructor);
            _stack.registerTemporary(base, payload);
        }, evaluate, { _stack.arm(base); });
    }

    // Reserves a value-returning temporary. Its address remains valid until
    // the containing full expression releases it.
    public ubyte* reserveValue(in size_t size, in uint alignment) {
        return reserve(null, size, alignment);
    }

    // Returns the existing slot for this literal within the active
    // expression, or creates and initializes one. This pairs DMD's two
    // visits to a constructor literal without exposing the record list.
    public ubyte* structLiteralAddress(
        StructLiteralExp node,
        in size_t size,
        in uint alignment,
        in TypeFacts facts,
        Initialize initialize,
    ) {
        foreach_reverse (ref temporary; _temporaries[_floor .. $])
            if (temporary.node is node)
                return temporary.base;

        auto base = reserve(node, size, alignment);
        initialize(node, facts, base);
        return base;
    }

    // Suspends destruction while a constructor is writing its destination.
    // A failed constructor therefore leaves no completed value to destroy.
    public void suspendConstructor(in void* address) {
        _stack.suspend(cast(void*) address);
    }

    // Arms the matching declaration after its constructor returns.
    public void armConstructor(in void* address) {
        _stack.arm(cast(void*) address);
    }

    private ubyte* reserve(
        StructLiteralExp node,
        in size_t size,
        in uint alignment,
    ) {
        const mark = _frames.mark;
        auto base = _frames.reserve(size, alignment);
        _temporaries ~= Temporary(node, mark, base, null);
        return base;
    }

    private void withLifetime(
        in size_t mark,
        scope Action action,
    ) {
        const previousFloor = _floor;
        const stackMark = _stack.mark;
        _floor = mark;
        scope(exit) {
            releaseSince(mark, stackMark);
            _floor = previousFloor;
        }
        action();
    }

    private void beginExpression() {
        if (_expressionDepth == _expressionStates.length)
            _expressionStates ~= ExpressionState.init;

        auto state = &_expressionStates[_expressionDepth++];
        state.mark = _temporaries.length;
        state.stackMark = _stack.mark;
        state.floor = _floor;
        _floor = _temporaries.length;
    }

    private void endExpression() {
        assert(_expressionDepth != 0);
        const state = _expressionStates[--_expressionDepth];
        releaseSince(state.mark, state.stackMark);
        _floor = state.floor;
    }

    private void releaseSince(in size_t mark, in size_t stackMark) {
        // The storage must be released even if a DMD-provided destructor
        // expression throws while unwinding this full expression.
        scope(exit) {
            if (_temporaries.length > mark)
                _frames.release(_temporaries[mark].mark);
            _temporaries.length = mark;
            _temporaries.assumeSafeAppend;
        }

        _stack.finish(stackMark, (in TemporaryStack.Entry entry) {
            _destroy(_temporaries[entry.payload].edtor);
        });
    }
}
