module dmd.iasm;


private:


version (MARS) {
    import dmd.iasm.dmdaarch64: inlineAsmAArch64Semantic;
    import dmd.iasm.dmdx86: inlineAsmSemantic;
}

public imported!"dmd.statement".Statement asmSemantic(
    imported!"dmd.statement".AsmStatement statement,
    imported!"dmd.dscope".Scope* scope_,
) {
    import dmd.expression: AssertExp, IntegerExp, StringExp;
    import dmd.mtype: Type;
    import dmd.statement: ErrorStatement, ExpStatement, InlineAsmStatement;
    import dmd.statementsem: statementSemantic;
    import dmd.target: target;
    import dmd.tokens: TOK;

    assert(scope_.parent.isFuncDeclaration !is null);

    if (statement.tokens is null)
        return null;

    scope_.func.hasInlineAsm = true;

    version (MARS) {
        if (statement.tokens.value == TOK.string_) {
            // `const` would qualify the class reference passed to ExpStatement.
            auto expression = new AssertExp(
                statement.loc,
                new IntegerExp(statement.loc, 0, Type.tint32),
                new StringExp(
                    statement.loc,
                    "Gnu Asm not supported - compile this function with gcc or clang",
                ),
            );
            return statementSemantic(
                new ExpStatement(statement.loc, expression),
                scope_,
            );
        }

        // `const` would prevent setting caseSensitive before semantic analysis.
        auto inline_ = new InlineAsmStatement(statement.loc, statement.tokens);
        inline_.caseSensitive = statement.caseSensitive;
        return target.isAArch64
            ? inlineAsmAArch64Semantic(inline_, scope_)
            : inlineAsmSemantic(inline_, scope_);
    } else version (NoBackend) {
        return null;
    } else {
        statement.error("D inline assembler statements are not supported");
        return new ErrorStatement;
    }
}

public void asmSemantic(
    imported!"dmd.dsymbol".CAsmDeclaration declaration,
    imported!"dmd.dscope".Scope* scope_,
) {
    version (MARS) {
        import dmd.errors: error;

        error(
            declaration.code.loc,
            "Gnu Asm not supported - compile this file with gcc or clang",
        );
    }
}

// dmd:lexer 2.112.x references Edition.init without emitting it.
pragma(mangle, "_D3dmd8astenums7Edition6__initZ")
public __gshared ushort editionInit = 2023;
