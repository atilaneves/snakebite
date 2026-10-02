module snakebite.repl;


private:

private alias DependencyImage =
    imported!"snakebite.dependencyimage".DependencyImage;

// One REPL session: an accumulated module source, the backend it runs
// on, and any input still waiting for a closing brace. Declarations from
// earlier cells stay visible to later ones because every accepted cell's
// source is kept and resubmitted, in full, with the next one.
//
// Known limitation: a fresh `Backend` is built from that resubmitted
// source on every accepted cell (there is no incremental-parse API to
// add a new cell's declarations to the existing `dmd.dmodule.Module`
// instead), so a mutation an earlier cell made is not visible later -
// `int x = 1;` then `++x` prints `2`, but a later `x` prints `1`,
// because the reparse re-runs `x`'s initializer on a new backend rather
// than reading the old one's mutated storage. Declarations themselves
// still accumulate correctly; only runtime mutation of that state does
// not survive a cell boundary. Tracked in
// https://github.com/atilaneves/snakebite/issues/154.
public struct Repl {
    import dmd.dmodule: Module;
    import snakebite.backends: Backend, BackendName;
    import snakebite.frontend.compiler: checksOf, FrontendFlags;

    private BackendName _backendName;
    private string[] _importPaths;
    private FrontendFlags _flags;
    private const(DependencyImage)* _dependencyImage;
    private string _accumulatedSource;
    private string _pendingInput;
    private uint _cellCount = 1;
    private Module _module;
    private imported!"snakebite.backends".Program _program;
    private Backend _backend;

    public this(
        BackendName backendName,
        in string[] importPaths = [],
        in string[] stringImportPaths = [],
        in FrontendFlags flags = FrontendFlags.init,
        const(DependencyImage)* dependencyImage = null,
    ) {
        import dmd.frontend: addImport, addStringImport;
        import snakebite.frontend.compiler: newInFrontend;

        _backendName = backendName;
        _importPaths = importPaths.dup;
        _flags = FrontendFlags(flags.compilerArguments.dup);
        _dependencyImage = dependencyImage;
        foreach (importPath; _importPaths)
            newInFrontend!addImport(importPath);
        foreach (stringImportPath; stringImportPaths)
            newInFrontend!addStringImport(stringImportPath);
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

            if (isExpressionCell(candidate, _flags))
                return submitExpression(candidate);
        }

        import snakebite.repl.cell: isImportCell;

        // A newline keeps the terminator outside any trailing line comment.
        const terminated = candidate ~ "\n;";
        return submitDeclaration(isImportCell(terminated, _flags) ? terminated : candidate);
    }

    private SubmitResult submitExpression(in string source) {
        import snakebite.backends: makeBackend;
        import snakebite.backends.guestmodules: GuestModules;
        import snakebite.frontend.compiler: parseSnippet;
        import snakebite.frontend.dmd.functions: findFunction;
        import snakebite.repl.cell: replCellLineDirective;
        import std.string: stripRight;

        const stripped = source.stripRight;
        const expression = stripped.length != 0 && stripped[$ - 1] == ';'
            ? stripped[0 .. $ - 1].stripRight
            : stripped;

        const evalName = syntheticEvalFunctionName(_cellCount);
        const cellSource = replCellLineDirective(_cellCount)
            ~ "string " ~ evalName ~ "() {\n"
            ~ "    import std.conv: text;\n"
            ~ "    return text(" ~ expression ~ ");\n"
            ~ "}\n";
        const fullSource = _accumulatedSource ~ cellSource;

        Module module_;
        try
            module_ = parseSnippet(fullSource, _importPaths, _flags);
        catch (Exception exception) {
            _pendingInput = null;
            return SubmitResult(SubmitResult.Kind.error, exception.msg.withoutDuplicateLines);
        }

        auto function_ = findFunction(module_, evalName);
        auto program = programOf(module_);
        program.dependencyImage = _dependencyImage;
        auto backend = makeBackend(
            _backendName,
            program,
        );

        // One expression cell runs the accumulated module as a program does:
        // its module constructors before the cell, its destructors after.
        auto modules = GuestModules.start(
            backend, program, GuestModules.Tests.no, GuestModules.Ends.program);
        if (modules.failed) {
            _pendingInput = null;
            return SubmitResult(
                SubmitResult.Kind.error, "a module constructor failed");
        }

        scope(exit) modules.finish;
        string display;
        try
            display = backend.eval(function_);
        catch (Throwable throwable) {
            _pendingInput = null;
            return SubmitResult(SubmitResult.Kind.error, throwable.msg.idup);
        }

        // An expression cell declares nothing later cells need to see -
        // `source` is an expression, not valid module-level syntax on its
        // own - and the synthetic `__snakebite_repl_eval_N__` wrapper that
        // ran it is never called again. Keeping it in `_accumulatedSource`
        // would only grow every future reparse with dead code, so the
        // session's accumulated declarations are left untouched; only the
        // cell counter and pending-input state advance.
        ++_cellCount;
        _pendingInput = null;

        return display.length == 0
            ? SubmitResult.init
            : SubmitResult(SubmitResult.Kind.value, display);
    }

    // A halt ends the cell, not the session: the REPL is a long-lived
    // process that holds the user's work.
    private imported!"snakebite.backends".Program programOf(Module module_) {
        import snakebite.backends: Program;

        return Program(
            interpretedModules(module_, _importPaths),
            "",
            checksOf(_flags),
            &endCell,
        );
    }

    private SubmitResult submitDeclaration(in string source) {
        import snakebite.backends: makeBackend;
        import snakebite.frontend.compiler: parseSnippet;
        import snakebite.repl.cell:
            isIncompleteDeclaration,
            isStandalonePragmaMessageStatement,
            replCellLineDirective;

        if (isIncompleteDeclaration(source, _flags)) {
            _pendingInput = source;
            return SubmitResult.init;
        }

        const cellSource = replCellLineDirective(_cellCount) ~ source ~ "\n";
        const fullSource = _accumulatedSource ~ cellSource;

        Module module_;
        try
            module_ = parseSnippet(fullSource, _importPaths, _flags);
        catch (Exception exception) {
            _pendingInput = null;
            return SubmitResult(SubmitResult.Kind.error, exception.msg.withoutDuplicateLines);
        }

        // A standalone `pragma(msg, ...)` already had its one-time effect
        // (writing straight to stderr) during the parse above; keeping it
        // in the accumulated buffer would fire it again on every future
        // cell, so it is dropped instead of accepted.
        //
        // Only the standalone form is caught: `pragma(msg, "a"); int x;`
        // stays in the buffer as part of `source` and so re-fires on
        // every later reparse. The acceptance spec only requires the
        // standalone form to be handled; covering pragmas embedded in a
        // larger declaration cell is tracked in
        // https://github.com/atilaneves/snakebite/issues/154.
        if (isStandalonePragmaMessageStatement(source, _flags)) {
            ++_cellCount;
            _pendingInput = null;
            return SubmitResult.init;
        }

        auto program = programOf(module_);
        program.dependencyImage = _dependencyImage;
        accept(
            fullSource,
            module_,
            program,
            makeBackend(_backendName, program),
        );

        return SubmitResult.init;
    }

    private void accept(
        in string fullSource,
        Module module_,
        imported!"snakebite.backends".Program program,
        Backend backend,
    ) {
        _accumulatedSource = fullSource;
        _module = module_;
        _program = program;
        _backend = backend;
        ++_cellCount;
        _pendingInput = null;
    }

    // Reruns every unittest accumulated so far, module by module, as
    // druntime's own default runner would. All failures are reported
    // together rather than stopping at the first one.
    private SubmitResult runLoadedTests() {
        import snakebite.backends.guestmodules: GuestModules;
        import snakebite.frontend.dmd.functions: findUnittests;
        import std.array: join;

        if (_module is null)
            return SubmitResult.init;

        auto modules = GuestModules.start(
            _backend, _program,
            GuestModules.Tests.no, GuestModules.Ends.program);
        if (modules.failed)
            return SubmitResult(
                SubmitResult.Kind.error, "a module constructor failed");

        scope(exit) modules.finish;
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


private noreturn endCell() {
    import snakebite.backends.haltprocess: Halted;

    throw new Halted;
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
    import snakebite.frontend.compiler: isUnderAnyPath;

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
