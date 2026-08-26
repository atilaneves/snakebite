module snakebite.frontend.dmd.functions;

private:

public bool hasNoAvailableSource(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody is null;
}

// A function whose body cannot be executed by an interpreter: either there is
// no body at all, or semantic analysis rejected the one that was parsed and
// replaced it with an `ErrorStatement`. A rejected body reaches here only for
// a non-root declaration, because a root module must have compiled cleanly
// before execution starts; for such a declaration the compiled dependency
// image is the authority, since the root's flags do not retroactively apply to
// an already-compiled dependency.
public bool hasNoInterpretableSource(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody is null ||
        function_.fbody.isErrorStatement !is null;
}

// Imported functions are analyzed on demand. DMD can defer semantic3
// work created while analyzing the body, so drain that queue before a
// backend reads parameters or the body. The inline-asm shim is
// likewise post-semantic, but its own snapshot is deferred to first
// read (`ensureInlineAsmSnapshot`) rather than retaken here: a
// backend lazily analyzing one callee at a time reaches this function
// once per newly discovered callee, and
// `snapshotInlineAsmInstructions` walks every symbol in every loaded
// module every time it runs -- paying that cost on each callee,
// rather than once before the one lookup that actually needs it.
public void ensureFunctionBodySemantic(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.dsymbol: PASS;
    import dmd.dsymbolsem: runDeferredSemantic3;
    import dmd.funcsem: functionSemantic3;

    // A prototype has nothing to analyze, and analyzing it under the root's
    // flags is what would replace its absent body with an `ErrorStatement`.
    if (function_.fbody is null)
        return;

    if (function_.semanticRun >= PASS.semantic3done)
        return;

    functionSemantic3(function_);
    runDeferredSemantic3;
    _inlineAsmSnapshotStale = true;
    assert(function_.semanticRun >= PASS.semantic3done);
}

// An `extern __gshared` global whose definition lives in a compiled dependency
// image: it is in the data segment, has no local initializer, and is declared
// `extern`. Reading it means resolving the native symbol.
public bool isExternDataSymbol(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: STC;

    return variable.isDataseg &&
        variable._init is null &&
        (variable.storage_class & STC.extern_) != STC.none;
}

public string noAvailableSourceMessage(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    return text(
        "`",
        function_.toChars,
        "` cannot be interpreted at compile time, ",
        "because it has no available source code",
    );
}

// Snapshot inline-asm tokens from the post-semantic AST. This includes AST
// bodies materialized by mixins, without reparsing source text.
public struct InlineAsmToken {
    public string kind;
    public string spelling;
}

private InlineAsmToken[][][
    imported!"dmd.statement".CompoundAsmStatement
] _inlineAsmInstructions;
private imported!"dmd.func".FuncDeclaration[
    imported!"dmd.statement".CompoundAsmStatement
] _inlineAsmOwners;
// Set whenever semantic work may have added or changed inline-asm-bearing
// AST the snapshot has not seen yet; cleared once a lookup retakes it.
private bool _inlineAsmSnapshotStale = true;

public void snapshotInlineAsmInstructions() {
    import dmd.dmodule: Module;

    // Parsed fixtures do not share an AST lifetime. DMD may reuse a reclaimed
    // statement's address in a later fixture, so retaining pointer-keyed
    // snapshots would let the new statement inherit the old statement's asm.
    _inlineAsmInstructions = null;
    _inlineAsmOwners = null;

    bool[imported!"dmd.dsymbol".Dsymbol] visited;
    foreach (index; 0 .. Module.amodules.length) {
        auto module_ = Module.amodules[index];
        snapshotSymbols(module_.members, visited);
    }
    _inlineAsmSnapshotStale = false;
}

// Retakes the snapshot only if semantic work has run since the last one:
// `ensureFunctionBodySemantic` marks it stale per newly analyzed callee
// instead of paying the full-program walk there, so the cost lands here,
// once, right before a lookup that actually needs current data.
private void ensureInlineAsmSnapshot() {
    if (_inlineAsmSnapshotStale)
        snapshotInlineAsmInstructions;
}

public const(InlineAsmToken[][]) inlineAsmInstructions(
    imported!"dmd.statement".CompoundAsmStatement statement,
) {
    ensureInlineAsmSnapshot;
    const saved = statement in _inlineAsmInstructions;
    return saved is null ? null : *saved;
}

public imported!"dmd.func".FuncDeclaration inlineAsmOwner(
    imported!"dmd.statement".CompoundAsmStatement statement,
) {
    ensureInlineAsmSnapshot;
    // `const` would qualify the DMD class reference and make it unreturnable.
    auto saved = statement in _inlineAsmOwners;
    return saved is null ? null : *saved;
}

private void snapshotSymbols(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref bool[imported!"dmd.dsymbol".Dsymbol] visited,
) {
    if (symbols is null)
        return;
    for (size_t index; index < symbols.length; ++index) {
        auto symbol = (*symbols)[index];
        if (symbol is null || (symbol in visited) !is null)
            continue;
        visited[symbol] = true;

        if (auto function_ = symbol.isFuncDeclaration)
            snapshotStatement(function_.fbody, function_);

        if (auto attributes = symbol.isAttribDeclaration)
            snapshotSymbols(attributes.decl, visited);

        if (auto scope_ = symbol.isScopeDsymbol)
            snapshotSymbols(scope_.members, visited);
    }
}

private void snapshotStatement(
    imported!"dmd.statement".Statement statement,
    imported!"dmd.func".FuncDeclaration owner,
) {
    if (statement is null)
        return;

    if (auto asm_ = statement.isCompoundAsmStatement) {
        InlineAsmToken[][] instructions;
        foreach (child; *asm_.statements) {
            // `const` would qualify the AST node and its mutable token list.
            auto inline_ = child is null ? null : child.isInlineAsmStatement;
            // `const` tokens cannot bind to inlineAsmToken's mutable ref input.
            auto tokens = inline_ is null ? null : inline_.tokens;
            if (tokens is null)
                continue;
            InlineAsmToken[] instruction;
            for (auto token = tokens;
                    token !is null; token = token.next)
                instruction ~= inlineAsmToken(*token);
            instructions ~= instruction;
        }
        if (instructions.length != 0) {
            _inlineAsmInstructions[asm_] = instructions;
            _inlineAsmOwners[asm_] = owner;
        }
        return;
    }

    if (auto scope_ = statement.isScopeStatement) {
        snapshotStatement(scope_.statement, owner);
        return;
    }
    if (auto compound = statement.isCompoundStatement) {
        foreach (child; *compound.statements)
            snapshotStatement(child, owner);
        return;
    }
    if (auto if_ = statement.isIfStatement) {
        snapshotStatement(if_.ifbody, owner);
        snapshotStatement(if_.elsebody, owner);
        return;
    }
    if (auto for_ = statement.isForStatement) {
        snapshotStatement(for_._init, owner);
        snapshotStatement(for_._body, owner);
        return;
    }
    if (auto do_ = statement.isDoStatement) {
        snapshotStatement(do_._body, owner);
        return;
    }
    if (auto while_ = statement.isWhileStatement) {
        snapshotStatement(while_._body, owner);
        return;
    }
    if (auto tryFinally = statement.isTryFinallyStatement) {
        snapshotStatement(tryFinally._body, owner);
        snapshotStatement(tryFinally.finalbody, owner);
        return;
    }
    if (auto tryCatch = statement.isTryCatchStatement) {
        snapshotStatement(tryCatch._body, owner);
        foreach (catch_; *tryCatch.catches)
            snapshotStatement(catch_.handler, owner);
        return;
    }
    if (auto with_ = statement.isWithStatement) {
        snapshotStatement(with_._body, owner);
        return;
    }
    if (auto label = statement.isLabelStatement) {
        snapshotStatement(label.statement, owner);
        return;
    }
    if (auto switch_ = statement.isSwitchStatement) {
        snapshotStatement(switch_._body, owner);
        return;
    }
    if (auto case_ = statement.isCaseStatement) {
        snapshotStatement(case_.statement, owner);
        return;
    }
    if (auto default_ = statement.isDefaultStatement)
        snapshotStatement(default_.statement, owner);
}

private InlineAsmToken inlineAsmToken(
    ref imported!"dmd.tokens".Token token,
) {
    import dmd.tokens: Token;

    return InlineAsmToken(
        Token.toString(token.value).idup,
        token.toString.idup,
    );
}
