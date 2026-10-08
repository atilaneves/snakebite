module snakebite.backends.fullexpression;


private:

public enum FullExpressionKind {
    effect,
    value,
}


// The shared policy for entering a full expression. A nested evaluation
// keeps the outer root and lifetime, so a declaration reached through a
// comma expression cannot start a second lifetime.
public struct FullExpressionScope {
    // The places where dmd's glue code (`toElemDtor`) ends a full
    // expression: the destructors of the temporaries made inside it run
    // there. A backend names the position, and `kindOf` and `endsWithin`
    // give the answer for all of them.
    public enum Position {
        expressionStatement,
        loopIncrement,
        switchError,
        returnOperand,
        throwOperand,
        withOperand,
        condition,
        switchOperand,
        logicalOperand,
        assertMessage,
    }

    public static FullExpressionKind kindOf(in Position position)
        @safe @nogc nothrow pure
    {
        final switch (position) with (Position) {
            case expressionStatement:
            case loopIncrement:
            case switchError:
            case withOperand:
                return FullExpressionKind.effect;
            case returnOperand:
            case throwOperand:
            case condition:
            case switchOperand:
            case logicalOperand:
            case assertMessage:
                return FullExpressionKind.value;
        }
    }

    // Whether the position ends a full expression that is part of a larger
    // one: the right operand of `&&` and `||`, the operand of a `throw`
    // expression and the message of an `assert`, as dmd's glue code does.
    // The temporaries of the enclosing expression stay alive, and the ones
    // made inside the operand die when the operand ends.
    public static bool endsWithin(in Position position)
        @safe @nogc nothrow pure
    {
        final switch (position) with (Position) {
            case throwOperand:
            case logicalOperand:
            case assertMessage:
                return true;
            case expressionStatement:
            case loopIncrement:
            case switchError:
            case withOperand:
            case returnOperand:
            case condition:
            case switchOperand:
                return false;
        }
    }

    // Whether the truth of a full expression at the position is read after
    // the destructors of its temporaries ran, when the expression is an
    // lvalue (`readsResultAfterEnd` below). The other positions are not
    // covered.
    public static bool testsResult(in Position position)
        @safe @nogc nothrow pure
    {
        final switch (position) with (Position) {
            case condition:
            case logicalOperand:
                return true;
            case expressionStatement:
            case loopIncrement:
            case switchError:
            case withOperand:
            case returnOperand:
            case throwOperand:
            case switchOperand:
            case assertMessage:
                return false;
        }
    }

    // dmd's glue code (`appendDtors`) ends a full expression whose result
    // is an lvalue by taking its address, running the destructors and then
    // reading the result. A backend resolves the address inside the full
    // expression and reads the value after it ends.
    public static bool readsResultAfterEnd(
        in Position position,
        imported!"dmd.expression".Expression result,
    ) {
        return testsResult(position) && isLvalueResult(result);
    }

    public struct CallState {
        private const(void)* root;
        private FullExpressionKind kind;
        private size_t depth;
    }

    private const(void)* _root;
    private FullExpressionKind _kind;
    private size_t _depth;

    public void run(
        in Position position,
        const(void)* root,
        scope void delegate() begin,
        scope void delegate() evaluate,
        scope void delegate() end,
    ) {
        if (!endsWithin(position))
            return run(kindOf(position), root, begin, evaluate, end);

        const state = suspendCall;
        scope (exit) resumeCall(state);
        run(kindOf(position), root, begin, evaluate, end);
    }

    private void run(
        in FullExpressionKind kind,
        const(void)* root,
        scope void delegate() begin,
        scope void delegate() evaluate,
        scope void delegate() end,
    ) {
        const outer = _depth == 0;
        if (outer) {
            _kind = kind;
            _root = root;
        }
        ++_depth;
        scope (exit) {
            --_depth;
            if (_depth == 0)
                _root = null;
        }
        if (outer)
            begin();
        scope (exit) {
            if (outer)
                end();
        }
        evaluate();
    }

    public CallState suspendCall() {
        const state = CallState(_root, _kind, _depth);
        _root = null;
        _depth = 0;
        return state;
    }

    public void resumeCall(CallState state) {
        _root = state.root;
        _kind = state.kind;
        _depth = state.depth;
    }

    public bool active() const {
        return _depth != 0;
    }

    public const(void)* root() const @safe @nogc nothrow pure {
        return _root;
    }

    public bool rootOwnsTemporary() const {
        return _kind == FullExpressionKind.value;
    }

}

// The expression kinds that dmd's glue code turns into a memory reference
// (`elemIsLvalue`): a field, a dereference or an element, or a comma or
// conditional expression whose results are such. A bit field is read through
// a different element, and a call that returns `ref` through a call.
bool isLvalueResult(imported!"dmd.expression".Expression result) {
    import dmd.astenums: Taarray;
    import dmd.typesem: toBasetype;

    if (auto comma = result.isCommaExp)
        return isLvalueResult(comma.e2);

    if (auto conditional = result.isCondExp)
        return isLvalueResult(conditional.e1)
            && isLvalueResult(conditional.e2);

    if (auto field = result.isDotVarExp) {
        auto variable = field.var.isVarDeclaration;
        return variable !is null && variable.isBitFieldDeclaration is null;
    }

    if (result.isPtrExp !is null)
        return true;

    if (auto element = result.isIndexExp)
        return element.e1.type.toBasetype.ty != Taarray;

    return false;
}
