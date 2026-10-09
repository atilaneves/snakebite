module snakebite.backends.interpreter.temporarylifetime;


private:

import dmd.declaration: VarDeclaration;
import dmd.expression: DeclarationExp, Expression, StructLiteralExp;
import snakebite.backends.temporary: TemporaryPlan;
import snakebite.backends.temporarystack: TemporaryStack;
import snakebite.backends.fullexpression:
    FullExpressionScope;
import snakebite.framestack: FrameStack, defaultFrameCapacity;
import snakebite.cstack: CStack;
import snakebite.nativelayout: TypeFacts;


// Owns the storage and lifetime rules for expression-scoped guest values.
// The evaluator supplies only the operation which executes a DMD-built
// destructor expression. This keeps destruction in DMD's AST while making
// every lifetime transition happen at one seam.
public struct TemporaryLifetime {
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

    // The bytes that the temporaries of one declaration use, kept for the
    // whole call: a variable that the declaration initialises can point
    // into them, and compiled D gives each such temporary one stack slot
    // that every execution reuses. A declaration in a loop, or in a
    // function called many times, therefore runs in constant memory.
    private struct Slot {
        VarDeclaration variable;
        ubyte* base;
        size_t capacity;
    }

    // The declaration whose initialiser is running and whose temporaries
    // go to a slot. `root` stays null while no such declaration runs.
    private struct Retained {
        const(void)* root;
        VarDeclaration variable;
        size_t slot;
        size_t used;
        size_t firstTemporary;
    }

    private enum noSlot = size_t.max;

    private CStack!Temporary _temporaries;
    private TemporaryStack _stack;
    private size_t _callMark;
    private FrameStack _frames;
    private size_t _floor;
    private FullExpressionScope _expressions;
    private CStack!ExpressionState _expressionStates;
    private size_t _expressionDepth;
    private Destroy _destroy;
    private CStack!Slot _slots;
    private size_t _slotBase;
    private Retained _retained;

    @disable this(this);

    public this(Destroy destroy) {
        _frames = FrameStack(defaultFrameCapacity);
        _destroy = destroy;
    }

    public Expression root() const @nogc nothrow {
        return cast(Expression) _expressions.root;
    }

    // A callee with a variable that can keep temporaries (`slots`) gets
    // slots of its own.
    public void withNestedCall(in bool slots, scope Action action) {
        if (slots) {
            const activation = enterActivation;
            nestedCall(action);
        } else
            nestedCall(action);
    }

    pragma(inline, true)
    private void nestedCall(scope Action action) {
        const previousMark = _callMark;
        _callMark = _stack.mark;
        scope (exit) _callMark = previousMark;
        const state = _expressions.suspendCall;
        scope (exit) _expressions.resumeCall(state);
        action();
    }

    public bool readsResultAfterEnd(
        in FullExpressionScope.Position position,
        Expression result,
    ) const {
        return _expressions.readsResultAfterEnd(position, result);
    }

    public void withExpression(
        in FullExpressionScope.Position position,
        Expression root,
        scope Action action,
    ) {
        _expressions.run(position, cast(const(void)*) root,
            { beginExpression; }, action, { endExpression; });
    }

    // The slots of one guest call: given back, with their bytes, when the
    // call ends by any path.
    public struct Activation {
        private TemporaryLifetime* _lifetime;
        private FrameStack.Mark _storage;
        private size_t _slotBase;

        @disable this(this);

        ~this() {
            _lifetime._slots.truncate(_lifetime._slotBase);
            _lifetime._slotBase = _slotBase;
            if (_lifetime._frames.mark > _storage)
                _lifetime._frames.release(_storage);
        }
    }

    public Activation enterActivation() {
        const slotBase = _slotBase;
        _slotBase = _slots.length;
        return Activation(&this, _frames.mark, slotBase);
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
            _temporaries.push(Temporary(null, _frames.mark, base, destructor));
            _stack.registerTemporary(base, payload);
        }, evaluate, { _stack.arm(base, _callMark); });
    }

    // The initialisation of a variable that can point into the temporaries
    // of its own initialiser: they stay in its slot until the call ends,
    // and their destructors still run at the end of the expression.
    public void initializeRetaining(
        VarDeclaration variable,
        DeclarationExp declaration,
        ubyte* base,
        scope Action evaluate,
    ) {
        if (!isOfRoot(declaration))
            return initialize(variable, declaration, base, evaluate);

        auto outer = _retained;
        _retained = Retained(
            _expressions.root, variable, noSlot, 0, _temporaries.length);
        scope (exit) _retained = outer;
        initialize(variable, declaration, base, evaluate);
    }

    // A declaration in a condition, `if (auto s = f())`, is the first
    // operand of a comma expression that is the root; another declaration
    // nested in an initialiser is not.
    private bool isOfRoot(DeclarationExp declaration) {
        static bool within(Expression expression, DeclarationExp wanted) {
            if (expression is wanted)
                return true;
            auto comma = expression.isCommaExp;
            return comma !is null
                && (within(comma.e1, wanted) || within(comma.e2, wanted));
        }

        return within(cast(Expression) _expressions.root, declaration);
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
        _stack.suspend(cast(void*) address, _callMark);
    }

    // Arms the matching declaration after its constructor returns.
    public void armConstructor(in void* address) {
        _stack.arm(cast(void*) address, _callMark);
    }

    private ubyte* reserve(
        StructLiteralExp node,
        in size_t size,
        in uint alignment,
    ) {
        if (_retained.root !is null && _retained.root is _expressions.root)
            return reserveRetained(node, size, alignment);

        const mark = _frames.mark;
        auto base = _frames.reserve(size, alignment);
        _temporaries.push(Temporary(node, mark, base, null));
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
            scope(exit) _floor = previousFloor;
            releaseSince(mark, stackMark);
        }
        action();
    }

    private ubyte* reserveRetained(
        StructLiteralExp node, in size_t size, in uint alignment,
    ) {
        if (_retained.slot == noSlot) {
            _retained.slot = slotOf(_retained.variable);
            _retained.used = 0;
        }

        auto slot = &_slots[_retained.slot];
        size_t start =
            alignedUp(cast(size_t) slot.base + _retained.used, alignment);
        if (slot.base is null
                || start + size > cast(size_t) slot.base + slot.capacity) {
            import std.algorithm.comparison: max;

            // Everything reserved so far in this execution stays valid in
            // the old bytes, which stay until the call ends. The next
            // execution fits in the new bytes.
            const capacity = max(256, 2 * slot.capacity,
                _retained.used + size + alignment);
            slot.base = _frames.reserve(capacity, 16);
            slot.capacity = capacity;
            _retained.used = 0;
            start = alignedUp(cast(size_t) slot.base, alignment);
            // The release at the end of the expression must not give the
            // new bytes back.
            foreach (ref temporary; _temporaries[_retained.firstTemporary .. $])
                temporary.mark = _frames.mark;
        }
        _retained.used = start + size - cast(size_t) slot.base;
        _temporaries.push(
            Temporary(node, _frames.mark, cast(ubyte*) start, null));
        return cast(ubyte*) start;
    }

    private size_t slotOf(VarDeclaration variable) {
        foreach (i; _slotBase .. _slots.length)
            if (_slots[i].variable is variable)
                return i;

        _slots.push(Slot(variable, null, 0));
        return _slots.length - 1;
    }

    private static size_t alignedUp(in size_t address, in uint alignment) {
        const mask = size_t(alignment) - 1;
        return (address + mask) & ~mask;
    }

    private void beginExpression() {
        if (_expressionDepth == _expressionStates.length)
            _expressionStates.push(ExpressionState.init);

        auto state = &_expressionStates[_expressionDepth++];
        state.mark = _temporaries.length;
        state.stackMark = _stack.mark;
        state.floor = _floor;
        _floor = _temporaries.length;
    }

    private void endExpression() {
        assert(_expressionDepth != 0);
        const state = _expressionStates[--_expressionDepth];
        scope(exit) _floor = state.floor;
        releaseSince(state.mark, state.stackMark);
    }

    private void releaseSince(in size_t mark, in size_t stackMark) {
        // The storage must be released even if a DMD-provided destructor
        // expression throws while unwinding this full expression.
        scope(exit) {
            if (_temporaries.length > mark)
                _frames.release(_temporaries[mark].mark);
            _temporaries.truncate(mark);
        }

        _stack.finish(stackMark, (in size_t payload) {
            _destroy(_temporaries[payload].edtor);
        });
    }
}
