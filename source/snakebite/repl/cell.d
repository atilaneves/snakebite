module snakebite.repl.cell;


private:


// A `#line` directive that resets the following source to line 1 of a file
// named `<repl cell N>`, so DMD's own diagnostics report locations the user
// can trace back to a specific REPL cell without the REPL formatting them
// by hand.
public string replCellLineDirective(in uint cellNumber) @safe pure {
    import std.conv: text;

    return lineDirective(text("<repl cell ", cellNumber, ">"));
}

private string lineDirective(in string filePath) @safe pure {
    return `#line 1 "` ~ escapedLineDirectiveFilePath(filePath) ~ `"` ~ "\n";
}

private string escapedLineDirectiveFilePath(in string filePath) @safe pure {
    string result;
    foreach (character; filePath) {
        if (character == '\\' || character == '"')
            result ~= '\\';
        result ~= character;
    }

    return result;
}

// Whether `input` parses as one whole expression statement, so it can be
// wrapped in a synthetic `auto f() { return <input>; }` and evaluated.
// Anything that fails this (a declaration, an import, a unittest block) is
// module-level source instead, appended to the session's source as-is.
public bool isExpressionCell(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.globals: global;
    import dmd.parse: Parser;
    import dmd.tokens: TOK;
    import snakebite.frontend.compiler: resetErrors, withCompilerLock;

    bool result;
    withCompilerLock(() {
        resetErrors;

        const source = input ~ ";\0";
        scope parser = new Parser!ASTCodegen(
            null,
            source,
            false,
            global.errorSink,
            &global.compileEnv,
            true,
        );

        parser.nextToken;
        const statement = parser.parseStatement(0);
        const expression = statement is null ? null : statement.isExpStatement;
        const isExpressionStatement = expression !is null
            && expression.exp !is null
            && expression.exp.isDeclarationExp is null;
        result = isExpressionStatement
            && parser.token.value == TOK.endOfFile
            && global.errors == 0;
    });

    return result;
}

// Whether `input`, parsed as module-level source, is missing its closing
// syntax (an unclosed brace, typically) rather than being outright invalid:
// the parse fails with its last diagnostic sitting exactly at end of input.
// The REPL keeps accumulating lines while this holds, and only reports a
// real syntax error once the diagnostic moves earlier than the end.
public bool isIncompleteDeclaration(in string input) {
    import dmd.errors: diagnostics, ErrorKind;
    import dmd.frontend: parseModule;
    import snakebite.frontend.compiler: resetErrors, withCompilerLock;
    import std.conv: text;

    bool result;
    withCompilerLock(() {
        import core.atomic: atomicFetchAdd;

        resetErrors;

        auto moduleResult = parseModule(
            text("repl_probe_", atomicFetchAdd(_probeCounter, 1u), ".d"),
            input,
        );
        if (!moduleResult.diagnostics.hasErrors)
            return;

        foreach (diagnostic; diagnostics) {
            if (
                diagnostic.kind == ErrorKind.error
                && diagnostic.loc.fileOffset == input.length
            ) {
                result = true;
                return;
            }
        }
    });

    return result;
}

// Whether `input` is one `pragma(msg, ...)` statement and nothing else.
// DMD writes such a pragma's text straight to raw stderr the moment its
// declaration is semantically analysed, so it fires again on every future
// cell if this source stays in the session's accumulated buffer. It is
// dropped from the buffer after its one-time side effect instead of being
// kept.
public bool isStandalonePragmaMessageStatement(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.globals: global;
    import dmd.id: Id;
    import dmd.parse: Parser;
    import dmd.tokens: TOK;
    import snakebite.frontend.compiler: resetErrors, withCompilerLock;

    bool result;
    withCompilerLock(() {
        resetErrors;

        const source = input ~ '\0';
        scope parser = new Parser!ASTCodegen(
            null,
            source,
            false,
            global.errorSink,
            &global.compileEnv,
            true,
        );

        parser.nextToken;
        auto statement = parser.parseStatement(0);
        auto pragma_ = statement is null ? null : statement.isPragmaStatement;
        result = pragma_ !is null
            && pragma_.ident is Id.msg
            && parser.token.value == TOK.endOfFile
            && global.errors == 0;
    });

    return result;
}

private __gshared uint _probeCounter;
