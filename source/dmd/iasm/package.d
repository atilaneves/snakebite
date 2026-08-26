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

// dmd:lexer 2.112.x references Edition.init without emitting it.
pragma(mangle, "_D3dmd8astenums7Edition6__initZ")
public __gshared ushort editionInit = 2023;
