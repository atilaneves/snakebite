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

    public void transfer(const(void)* target)
        @safe @nogc nothrow pure scope
    {
        clearTransfer;
        _kind = Kind.goto_;
        _target = target;
    }

    private void clearTransfer() @safe @nogc nothrow pure scope {
        _kind = Kind.none;
        _label = null;
        _target = null;
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
    }
}

public struct ScopeFrame {
    import dmd.statement: Statement;

    public const(void)* owner;
    public bool cleanup;
    public Statement finallyBody;
}

// The protected scopes (`try` statements) that enclose each statement a jump
// can leave or enter, computed once from the final body of a function.
// dmd's own `tryBody` is set during statement semantic, before dmd wraps the
// body in the `try` statements for value parameters with a destructor and
// for a returned local, and it is never set on the `goto` that dmd makes for
// a `return` in a function with an `out` contract or an invariant. Both
// backends take where a jump starts and where it lands from here, so they
// agree on which cleanups it runs.
public struct ScopePaths {
    private ScopeFrame[][const(void)*] _enclosing;

    // Innermost scope first. A handler or a `finally` body is not inside the
    // `try` that owns it.
    public ScopeFrame[] enclosing(
        in imported!"dmd.statement".Statement statement,
    )
        @trusted
    {
        auto found = cast(const(void)*) statement in _enclosing;
        assert(found !is null,
            "the scope pass records every jump source and destination");
        return *found;
    }

    // The scope path that starts at `statement` itself.
    public ScopeFrame[] through(imported!"dmd.statement".Statement statement)
        @trusted
    {
        return frameOf(statement) ~ enclosing(statement);
    }
}

public ScopePaths scopePathsOf(imported!"dmd.statement".Statement body_)
    @trusted
{
    ScopePaths result;
    if (body_ is null)
        return result;

    scope recorder = new ScopeRecorder(&result._enclosing);
    recorder.visitStmt(body_);
    return result;
}

private ScopeFrame frameOf(imported!"dmd.statement".Statement statement)
    @trusted
{
    if (auto finally_ = statement.isTryFinallyStatement)
        return ScopeFrame(cast(void*) finally_, true, finally_.finalbody);

    auto catch_ = statement.isTryCatchStatement;
    assert(catch_ !is null);
    return ScopeFrame(cast(void*) catch_, false, null);
}

extern(C++) private final class ScopeRecorder:
    imported!"dmd.visitor.statement_rewrite_walker".StatementRewriteWalker
{
    import dmd.visitor.statement_rewrite_walker: StatementRewriteWalker;
    import dmd.statement:
        BreakStatement, CaseStatement, ContinueStatement, DefaultStatement,
        DoStatement, ForStatement, GotoCaseStatement, GotoDefaultStatement,
        GotoStatement, LabelStatement, ReturnStatement, ScopeGuardStatement,
        Statement, SwitchStatement, TryCatchStatement, TryFinallyStatement,
        UnrolledLoopStatement;

    alias visit = StatementRewriteWalker.visit;

    private ScopeFrame[][const(void)*]* _into;
    private ScopeFrame[] _path;

    public extern(D) this(ScopeFrame[][const(void)*]* into) {
        _into = into;
    }

    private extern(D) void record(Statement statement) {
        (*_into)[cast(const(void)*) statement] = _path;
    }

    static foreach (Node; imported!"std.meta".AliasSeq!(
        ReturnStatement, BreakStatement, ContinueStatement, GotoStatement,
        GotoCaseStatement, GotoDefaultStatement, ForStatement, DoStatement,
        UnrolledLoopStatement, SwitchStatement, CaseStatement,
        DefaultStatement, LabelStatement,
    )) {
        override void visit(Node statement) {
            record(statement);
            super.visit(statement);
        }
    }

    override void visit(ScopeGuardStatement statement) {
        record(statement);
        if (statement.statement !is null)
            visitStmt(statement.statement);
    }

    override void visit(TryCatchStatement statement) {
        record(statement);
        auto outer = _path;
        _path = [frameOf(statement)] ~ outer;
        if (statement._body !is null)
            visitStmt(statement._body);
        _path = outer;
        foreach (catch_; *statement.catches)
            if (catch_ !is null && catch_.handler !is null)
                visitStmt(catch_.handler);
    }

    override void visit(TryFinallyStatement statement) {
        record(statement);
        auto outer = _path;
        _path = [frameOf(statement)] ~ outer;
        if (statement._body !is null)
            visitStmt(statement._body);
        _path = outer;
        if (statement.finalbody !is null)
            visitStmt(statement.finalbody);
    }
}
