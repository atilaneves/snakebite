// dmd:frontend links against dmd.iasm but the dub package does not ship it;
// this shim provides the symbols. No backend executes inline assembler, but
// guest code (druntime's core.checkedint among others) contains it, so an
// asm body must survive semantic analysis rather than be an error: it is
// kept as an unanalysed InlineAsmStatement and only fails if executed.
module dmd.iasm;


private:


public imported!"dmd.statement".Statement asmSemantic(
    imported!"dmd.statement".AsmStatement statement,
    imported!"dmd.dscope".Scope* scope_,
) {
    import dmd.statement: InlineAsmStatement;

    assert(scope_.parent.isFuncDeclaration !is null);

    if (statement.tokens is null)
        return null;

    scope_.func.hasInlineAsm = true;

    // `const` would prevent setting caseSensitive before semantic analysis.
    auto inline_ = new InlineAsmStatement(statement.loc, statement.tokens);
    inline_.caseSensitive = statement.caseSensitive;
    return inline_;
}

public void asmSemantic(
    imported!"dmd.dsymbol".CAsmDeclaration declaration,
    imported!"dmd.dscope".Scope* scope_,
) {
    import dmd.errors: error;

    error(
        declaration.code.loc,
        "Gnu Asm not supported - compile this file with gcc or clang",
    );
}

// dmd:lexer 2.113.0 references Edition.init without always emitting
// it: `edition_init_amd64.S` (this package) supplies it as a weak
// fallback so it never collides with the real one, when linked.
// Pinned here so a `dmd:frontend` bump that moves `Edition.init` off
// 2023 fails the build instead of silently depending on link order
// for which definition wins.
static assert(
    cast(ushort) imported!"dmd.astenums".Edition.init == 2023,
    "edition_init_amd64.S must match Edition.init",
);
