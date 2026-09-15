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
    public struct CallState {
        private const(void)* root;
        private FullExpressionKind kind;
        private size_t depth;
    }

    private const(void)* _root;
    private FullExpressionKind _kind;
    private size_t _depth;

    public void run(
        FullExpressionKind kind,
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

    public const(void)* root() const {
        return _root;
    }

    public bool rootOwnsTemporary() const {
        return _kind == FullExpressionKind.value;
    }

}
