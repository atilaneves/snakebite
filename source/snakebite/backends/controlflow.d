module snakebite.backends.controlflow;

private:

public struct ControlFlowState {
    private const(void)* _target;
    private const(void)* _destinationScope;
    private const(void)* _resume;

    public bool hasTransfer() const @safe @nogc nothrow pure scope {
        return _target !is null;
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
        _target = target;
        _destinationScope = destinationScope;
    }

    public void resume() @safe @nogc nothrow pure scope {
        _resume = _target;
        _target = null;
        _destinationScope = null;
    }

    public void seek(const(void)* target)
        @safe @nogc nothrow pure scope
    {
        _resume = target;
        _destinationScope = null;
    }

    public void clearTransfer() @safe @nogc nothrow pure scope {
        _target = null;
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
