module snakebite.backends.controlflow;

private:

public struct ControlFlowState {
    import dmd.identifier: Identifier;

    private enum Kind {
        none, return_, break_, continue_, goto_,
    }

    private Kind _kind;
    private Identifier _label;
    private const(void)* _target;
    private const(void)* _destinationScope;
    private const(void)* _resume;

    public bool hasTransfer() const @safe @nogc nothrow pure scope {
        return _kind != Kind.none;
    }

    public bool hasGoto() const @safe @nogc nothrow pure scope {
        return _kind == Kind.goto_;
    }

    public bool seeking() const @safe @nogc nothrow pure scope {
        return _resume !is null;
    }

    public bool at(const(void)* statement)
        @safe @nogc nothrow pure scope
    {
        if (_resume is null || _resume != statement)
            return false;

        _resume = null;
        return true;
    }

    public const(void)* target() const @safe @nogc nothrow pure {
        return _target;
    }

    public const(void)* destinationScope()
        const @safe @nogc nothrow pure
    {
        return _destinationScope;
    }

    public void transfer(
        const(void)* target,
        const(void)* destinationScope = null,
    )
        @safe @nogc nothrow pure scope
    {
        clearTransfer;
        _kind = Kind.goto_;
        _target = target;
        _destinationScope = destinationScope;
    }

    private void clearTransfer() @safe @nogc nothrow pure scope {
        _kind = Kind.none;
        _label = null;
        _target = null;
        _destinationScope = null;
    }

    public void returnFromFunction() @safe @nogc nothrow pure scope {
        clearTransfer;
        _kind = Kind.return_;
    }

    public void breakTo(Identifier label) @safe @nogc nothrow pure scope {
        clearTransfer;
        _kind = Kind.break_;
        _label = label;
    }

    public void continueTo(Identifier label) @safe @nogc nothrow pure scope {
        clearTransfer;
        _kind = Kind.continue_;
        _label = label;
    }

    public void finishLabel(Identifier label)
        @safe @nogc nothrow pure scope
    {
        if (_kind == Kind.break_ && _label is label)
            clearTransfer;
    }

    // A labelled break belongs to its label statement, even when a loop
    // with the same label sees it first.
    public bool leavesLoop(Identifier label)
        @safe @nogc nothrow pure scope
    {
        if (_kind == Kind.break_) {
            finishLabel(null);
            return true;
        }
        return !continuesLoop(label);
    }

    // Unrolled loops pass breaks onward, but consume their own continues.
    public bool continuesLoop(Identifier label = null)
        @safe @nogc nothrow pure scope
    {
        if (_kind == Kind.continue_
                && (_label is null || _label is label))
            clearTransfer;
        return !hasTransfer;
    }

    public bool leavesSwitch() @safe @nogc nothrow pure scope {
        if (!hasTransfer || hasGoto)
            return false;
        finishLabel(null);
        return true;
    }

    // Cleanup must run despite a pending transfer. Its own transfer takes
    // precedence; otherwise the earlier transfer resumes after cleanup.
    public void withCleanup(scope void delegate() run) {
        auto previous = this; // Restoration needs mutable identifier references.
        clearTransfer;
        run();
        if (!hasTransfer)
            this = previous;
    }

    public void resume() @safe @nogc nothrow pure scope {
        _resume = _target;
        clearTransfer;
    }

    public void seek(const(void)* target)
        @safe @nogc nothrow pure scope
    {
        _resume = target;
        _destinationScope = null;
    }
}

public struct ScopeFrame {
    public const(void)* owner;
    public bool cleanup;
}

public ScopeFrame[] scopePath(imported!"dmd.statement".Statement scope_)
    @safe
{
    ScopeFrame[] result;
    while (scope_ !is null) {
        if (auto finally_ = scope_.isTryFinallyStatement()) {
            result ~= ScopeFrame(cast(void*) finally_, true);
            scope_ = finally_.tryBody;
        }
        else if (auto catch_ = scope_.isTryCatchStatement()) {
            result ~= ScopeFrame(cast(void*) catch_, false);
            scope_ = catch_.tryBody;
        }
        else {
            break;
        }
    }
    return result;
}

public size_t cleanupCount(
    scope const(ScopeFrame)[] source,
    scope const(ScopeFrame)[] destination,
) @safe @nogc nothrow pure scope {
    size_t sourceEnd = source.length;
    size_t destinationEnd = destination.length;
    while (sourceEnd != 0 && destinationEnd != 0
            && source[sourceEnd - 1].owner
                == destination[destinationEnd - 1].owner) {
        --sourceEnd;
        --destinationEnd;
    }

    if (destinationEnd != 0)
        return size_t.max;

    size_t count;
    foreach (frame; source[0 .. sourceEnd])
        count += frame.cleanup;
    return count;
}
