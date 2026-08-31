module snakebite.repl;


private:


// One REPL session: an accumulated module source, the backend it runs
// on, and any input still waiting for a closing brace. Declarations from
// earlier cells stay visible to later ones because every accepted cell's
// source is kept and resubmitted, in full, with the next one.
public struct Repl {
    private imported!"snakebite.repl.cli".ReplBackendName _backendName;
    private string[] _importPaths;
    private string _accumulatedSource;
    private string _pendingInput;
    private uint _cellCount = 1;
    private imported!"dmd.dmodule".Module _module;
    private imported!"snakebite.backends".Backend _backend;

    public this(
        imported!"snakebite.repl.cli".ReplBackendName backendName,
        in string[] importPaths = [],
    ) {
        import dmd.frontend: addImport;

        _backendName = backendName;
        _importPaths = importPaths.dup;
        foreach (importPath; _importPaths)
            addImport(importPath);
    }

    public bool shouldQuit(in string input) const @safe pure {
        return isQuitCommand(input) && _pendingInput.length == 0;
    }

    // Load one file's whole source as if it had been typed as one
    // (necessarily complete) declaration cell.
    public void loadModuleFile(in string filePath) {
        import std.file: readText;

        string source;
        try
            source = filePath.readText;
        catch (Exception exception)
            throw new Exception("cannot read " ~ filePath ~ ": " ~ exception.msg);

        const result = submitDeclaration(source);
        if (result.kind == SubmitResult.Kind.error)
            throw new Exception(result.text);
    }

    public SubmitResult submit(in string input) {
        import std.string: strip;

        if (_pendingInput.length == 0 && input.strip.length == 0)
            return SubmitResult.init;

        if (isReplCommand(input)) {
            if (_pendingInput.length != 0)
                return SubmitResult(
                    SubmitResult.Kind.error,
                    commandWhilePendingDiagnostic(input),
                );

            if (isQuitCommand(input))
                return SubmitResult(SubmitResult.Kind.quit);

            return runLoadedTests;
        }

        const candidate = _pendingInput.length == 0
            ? input
            : _pendingInput ~ "\n" ~ input;

        if (_pendingInput.length == 0) {
            import snakebite.repl.cell: isExpressionCell;

            if (isExpressionCell(candidate))
                return submitExpression(candidate);
        }

        return submitDeclaration(candidate);
    }

    private SubmitResult submitExpression(in string source) {
        import snakebite.backends.backend: Program;
        import snakebite.frontend.compiler: parseSnippet;
        import snakebite.frontend.dmd.functions: findFunction;
        import snakebite.repl.cell: replCellLineDirective;

        const evalName = syntheticEvalFunctionName(_cellCount);
        const cellSource = replCellLineDirective(_cellCount)
            ~ "string " ~ evalName ~ "() {\n"
            ~ "    import std.conv: text;\n"
            ~ "    return text(" ~ source ~ ");\n"
            ~ "}\n";
        const fullSource = _accumulatedSource ~ cellSource;

        imported!"dmd.dmodule".Module module_;
        try
            module_ = parseSnippet(fullSource);
        catch (Exception exception) {
            _pendingInput = null;
            return SubmitResult(SubmitResult.Kind.error, exception.msg.withoutDuplicateLines);
        }

        auto function_ = findFunction(module_, evalName);
        auto backend = makeBackend(
            _backendName,
            Program(interpretedModules(module_, _importPaths)),
        );

        string display;
        try
            display = backend.eval(function_);
        catch (Throwable throwable) {
            _pendingInput = null;
            return SubmitResult(SubmitResult.Kind.error, throwable.msg.idup);
        }

        accept(fullSource, module_, backend);

        return display.length == 0
            ? SubmitResult.init
            : SubmitResult(SubmitResult.Kind.value, display);
    }

    private SubmitResult submitDeclaration(in string source) {
        import snakebite.backends.backend: Program;
        import snakebite.frontend.compiler: parseSnippet;
        import snakebite.repl.cell:
            isIncompleteDeclaration,
            isStandalonePragmaMessageStatement,
            replCellLineDirective;

        if (isIncompleteDeclaration(source)) {
            _pendingInput = source;
            return SubmitResult.init;
        }

        const cellSource = replCellLineDirective(_cellCount) ~ source ~ "\n";
        const fullSource = _accumulatedSource ~ cellSource;

        imported!"dmd.dmodule".Module module_;
        try
            module_ = parseSnippet(fullSource);
        catch (Exception exception) {
            _pendingInput = null;
            return SubmitResult(SubmitResult.Kind.error, exception.msg.withoutDuplicateLines);
        }

        // A standalone `pragma(msg, ...)` already had its one-time effect
        // (writing straight to stderr) during the parse above; keeping it
        // in the accumulated buffer would fire it again on every future
        // cell, so it is dropped instead of accepted.
        if (isStandalonePragmaMessageStatement(source)) {
            ++_cellCount;
            _pendingInput = null;
            return SubmitResult.init;
        }

        accept(
            fullSource,
            module_,
            makeBackend(_backendName, Program(interpretedModules(module_, _importPaths))),
        );

        return SubmitResult.init;
    }

    private void accept(
        in string fullSource,
        imported!"dmd.dmodule".Module module_,
        imported!"snakebite.backends".Backend backend,
    ) {
        _accumulatedSource = fullSource;
        _module = module_;
        _backend = backend;
        ++_cellCount;
        _pendingInput = null;
    }

    // Reruns every unittest accumulated so far, module by module, as
    // druntime's own default runner would. All failures are reported
    // together rather than stopping at the first one.
    private SubmitResult runLoadedTests() {
        import snakebite.frontend.dmd.functions: findUnittests;
        import std.array: join;

        if (_module is null)
            return SubmitResult.init;

        string[] failures;
        foreach (unittest_; findUnittests(_module)) {
            try
                _backend.call(unittest_, null, []);
            catch (Throwable throwable)
                failures ~= testFailureDiagnostic(unittest_, throwable.msg.idup);
        }

        return failures.length == 0
            ? SubmitResult.init
            : SubmitResult(SubmitResult.Kind.error, failures.join("\n"));
    }
}


public struct SubmitResult {
    public enum Kind {
        none,
        value,
        error,
        quit,
    }

    public Kind kind;
    public string text;
}


private imported!"snakebite.backends".Backend makeBackend(
    imported!"snakebite.repl.cli".ReplBackendName name,
    imported!"snakebite.backends.backend".Program program,
) {
    import snakebite.backends.bytecode: Bytecode;
    import snakebite.backends.ctfe: Ctfe;
    import snakebite.backends.interpreter: Interpreter;
    import snakebite.repl.cli: ReplBackendName;

    final switch (name) with (ReplBackendName) {
        case interpreter:
            return new Interpreter(program);
        case bytecode:
            return new Bytecode(program);
        case ctfe:
            return new Ctfe(program);
    }
}


// `module_` plus every module it imports that lives under one of
// `importPaths`: a project's own files, resolved by DMD's own import
// search rather than being concatenated into the REPL's source text. Only
// these count as guest code the interpreter runs directly - anything else
// reached through `import` (Phobos, druntime) stays native, resolved
// through FFI the way compiled D would call it.
private imported!"dmd.dmodule".Module[] interpretedModules(
    imported!"dmd.dmodule".Module module_,
    in string[] importPaths,
) {
    import dmd.dmodule: Module;

    bool[Module] visited;
    Module[] result;

    void visit(Module candidate) {
        if (candidate is null || (candidate in visited))
            return;

        visited[candidate] = true;
        result ~= candidate;
        foreach (imported_; candidate.aimports)
            if (isUnderAnyPath(imported_, importPaths))
                visit(imported_);
    }

    visit(module_);
    return result;
}


private bool isUnderAnyPath(
    imported!"dmd.dmodule".Module module_,
    in string[] paths,
) {
    import std.algorithm.searching: startsWith;
    import std.path: absolutePath, buildNormalizedPath;
    import std.string: fromStringz;

    const sourcePath = module_.srcfile.toString.fromStringz.idup
        .absolutePath.buildNormalizedPath;

    foreach (path; paths)
        if (sourcePath.startsWith(path.absolutePath.buildNormalizedPath))
            return true;

    return false;
}


// DMD sometimes reports the same diagnostic message through two paths for
// one failure (e.g. a failed import); collapse consecutive duplicate lines
// so the REPL does not echo it twice.
private string withoutDuplicateLines(in string diagnostic) @safe pure {
    import std.array: join, split;

    string[] result;
    string previous;
    bool havePrevious;
    foreach (line; diagnostic.split("\n")) {
        if (havePrevious && line == previous)
            continue;

        result ~= line;
        previous = line;
        havePrevious = true;
    }

    return result.join("\n");
}


private string testFailureDiagnostic(
    imported!"dmd.func".FuncDeclaration unittest_,
    in string message,
) {
    import std.conv: text;
    import std.string: fromStringz;

    return text(
        "unittest at ", unittest_.loc.filename.fromStringz,
        "(", unittest_.loc.linnum, ") failed: ", message,
    );
}


private bool isReplCommand(in string input) @safe pure {
    import std.string: strip;

    const stripped = input.strip;
    return isQuitCommand(stripped) || stripped == ":t";
}


private bool isQuitCommand(in string input) @safe pure {
    import std.string: strip;

    const stripped = input.strip;
    return stripped == ":q" || stripped == ":quit";
}


private string commandWhilePendingDiagnostic(in string input) @safe pure {
    import std.string: strip;

    return "cannot run REPL command `" ~ input.strip ~
        "` while input is pending";
}


private string syntheticEvalFunctionName(in uint cellNumber) @safe pure {
    import std.conv: text;

    return text("__snakebite_repl_eval_", cellNumber, "__");
}
