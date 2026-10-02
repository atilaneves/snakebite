module snakebite.backends.interpreter.temporarylifetime;


private:

import dmd.declaration: VarDeclaration;
import dmd.tokens: EXP;
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
        // For a retaining expression: its declaration, and the slot that
        // the bytes of its value temporaries come from.
        Expression root;
        size_t slot;
        size_t used;
    }

    // The bytes that the temporaries of one declaration use, kept for the
    // whole activation: a variable that the declaration initialises can
    // point into them, and compiled D gives each such temporary one stack
    // slot that every execution reuses. A declaration in a loop, or in a
    // function called many times, therefore runs in constant memory.
    private struct Slot {
        Expression declaration;
        ubyte* base;
        size_t capacity;
    }

    private enum noSlot = size_t.max;

    // What a guest call gives back when it ends: the bytes of its slots,
    // and the slot table of the call that made it.
    public struct Activation {
        private FrameStack.Mark storage;
        private size_t slotBase;
    }

    private Temporary[] _temporaries;
    private TemporaryStack _stack;
    private FrameStack _frames;
    private size_t _floor;
    private FullExpressionScope _expressions;
    private ExpressionState[] _expressionStates;
    private size_t _expressionDepth;
    private Destroy _destroy;
    private Slot[] _slots;
    private size_t _slotCount;
    private size_t _slotBase;
    // Whether the running outer expression of this call takes its
    // temporaries from a slot. No other outer expression can begin or end
    // while this is set, except one in a callee, which `withNestedCall`
    // hides.
    private bool _retaining;

    public this(Destroy destroy) {
        _frames = FrameStack(defaultFrameCapacity);
        // Reserve the usual call nesting without putting an allocation in
        // the steady-state expression path. Recursive calls can grow this
        // stack when they exceed the initial depth.
        _expressionStates.length = 16;
        _destroy = destroy;
    }

    public void withNestedCall(scope Action action) {
        const state = _expressions.suspendCall;
        const retaining = _retaining;
        _retaining = false;
        scope (exit) {
            _expressions.resumeCall(state);
            _retaining = retaining;
        }
        action();
    }

    // The temporaries of a declaration live in the slot of that
    // declaration until the activation ends or the declaration runs again:
    // a variable that it initialises can point into them. Their destructors
    // still run at the end of the expression.
    public void withExpression(
        FullExpressionKind kind,
        Expression root,
        scope Action action,
    ) {
        _expressions.run(kind, cast(const(void)*) root,
            { beginExpression(root); }, action, { endExpression; });
    }

    // Starts the slots of one guest call. `leaveActivation` gives back
    // every slot made since, whichever way the call ends.
    public Activation enterActivation() {
        const activation = Activation(_frames.mark, _slotBase);
        _slotBase = _slotCount;
        return activation;
    }

    public void leaveActivation(in Activation activation) {
        _slotCount = _slotBase;
        _slotBase = activation.slotBase;
        if (_frames.mark > activation.storage)
            _frames.release(activation.storage);
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
        if (_retaining)
            return reserveRetained(node, size, alignment);

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

    private ubyte* reserveRetained(
        StructLiteralExp node, in size_t size, in uint alignment,
    ) {
        auto base = reserveInSlot(size, alignment);
        _temporaries ~= Temporary(node, _frames.mark, base, null);
        return base;
    }

    private ubyte* reserveInSlot(in size_t size, in uint alignment) {
        auto state = &_expressionStates[_expressionDepth - 1];
        if (state.slot == noSlot) {
            state.slot = slotOf(state.root);
            state.used = 0;
        }

        auto slot = &_slots[state.slot];
        size_t start = alignedUp(cast(size_t) slot.base + state.used, alignment);
        if (slot.base is null
                || start + size > cast(size_t) slot.base + slot.capacity) {
            import std.algorithm.comparison: max;

            // Everything reserved so far in this execution stays valid in
            // the old bytes, which stay until the activation ends. The next
            // execution fits in the new bytes.
            const capacity = max(256, 2 * slot.capacity,
                state.used + size + alignment);
            slot.base = _frames.reserve(capacity, 16);
            slot.capacity = capacity;
            state.used = 0;
            start = alignedUp(cast(size_t) slot.base, alignment);
        }
        state.used = start + size - cast(size_t) slot.base;
        return cast(ubyte*) start;
    }

    private size_t slotOf(Expression declaration) {
        foreach (i; _slotBase .. _slotCount)
            if (_slots[i].declaration is declaration)
                return i;

        if (_slotCount == _slots.length)
            _slots.length = _slots.length ? 2 * _slots.length : 8;
        _slots[_slotCount] = Slot(declaration, null, 0);
        return _slotCount++;
    }

    private static size_t alignedUp(in size_t address, in uint alignment) {
        const mask = size_t(alignment) - 1;
        return (address + mask) & ~mask;
    }

    private void beginExpression(Expression root) {
        if (_expressionDepth == _expressionStates.length)
            _expressionStates ~= ExpressionState.init;

        auto state = &_expressionStates[_expressionDepth++];
        state.mark = _temporaries.length;
        state.stackMark = _stack.mark;
        state.floor = _floor;
        _floor = _temporaries.length;
        if (root.op == EXP.declaration) {
            _retaining = true;
            state.root = root;
            state.slot = noSlot;
        }
    }

    private void endExpression() {
        assert(_expressionDepth != 0);
        // Copied out: a destructor that runs while the expression ends can
        // begin an expression of its own and move the state array.
        const state = &_expressionStates[--_expressionDepth];
        const mark = state.mark;
        const stackMark = state.stackMark;
        const floor = state.floor;
        const retains = _retaining;
        _retaining = false;
        releaseSince(mark, stackMark, retains);
        _floor = floor;
    }

    private void releaseSince(
        in size_t mark, in size_t stackMark, in bool retainStorage = false,
    ) {
        // The storage must be released even if a DMD-provided destructor
        // expression throws while unwinding this full expression.
        scope(exit) {
            if (_temporaries.length > mark && !retainStorage)
                _frames.release(_temporaries[mark].mark);
            _temporaries = _temporaries[0 .. mark];
        }

        _stack.finish(stackMark, (in TemporaryStack.Entry entry) {
            _destroy(_temporaries[entry.payload].edtor);
        });
    }
}
