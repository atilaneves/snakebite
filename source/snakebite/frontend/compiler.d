module snakebite.frontend.compiler;

private:

public alias ModuleParseResult = imported!"std.typecons".Tuple!(
    imported!"dmd.dmodule".Module,
    "module_",
    imported!"dmd.frontend".Diagnostics,
    "diagnostics",
);

public struct FrontendFlags {
    string[] compilerArguments;
}

// DMD owns process-global compiler state; `Compiler` serializes access with a
// mutex and is initialized once for this process.
__gshared Compiler compiler;
// DMD registers modules by filename, so each parse call needs a unique name.
// TODO: bench harness re-runs grow this monotonically and DMD retains
// process-global semantic state keyed off the name. At small fixture counts
// the bias is below stddev, but as the fixture set grows we will need either
// a deinitializeDMD/initDMD reset between runs or a way to evict the
// registered module from DMD's tables.
private shared uint _moduleCounter;

shared static this() {
    compiler = new Compiler;
}

shared static ~this() {
    compiler.shutdown;
}

public ModuleParseResult parseModule(in string filePath) {
    return compiler.parseModule(filePath, [], FrontendFlags.init);
}

public ModuleParseResult parseModule(
    in string filePath,
    in string[] importPaths,
) {
    return compiler.parseModule(filePath, importPaths, FrontendFlags.init);
}

public ModuleParseResult parseModule(
    in string filePath,
    in string[] importPaths,
    in FrontendFlags flags,
) {
    return compiler.parseModule(filePath, importPaths, flags);
}

// Whether this process compiles like the single-snippet world (bin/ut, repl)
// or like `dub test` (a whole package as one root set). The snippet world needs
// the lightning rod + allInst to funnel every tiny fixture's borrowed template
// instances; a dub package is its own root set (`dmd -unittest <files>`) and so
// needs neither -- and must not parse the rod, or druntime modules home their
// instances on the rod (which the dub link never emits) instead of on the
// package root that instantiated them.
public alias DubMode = imported!"std.typecons".Flag!"dubMode";

// Initialise DMD's process-global state for this process. Must be called once,
// before any parse, by the entry point (it knows whether this is a dub run).
// Idempotent: a second call is a no-op.
public void initialize(in DubMode dubMode) {
    compiler.initialize(dubMode);
}

// Parse a set of files as root modules, modelling `dmd -unittest <files>
// -I<paths>`: every file is established as a root before any import traversal,
// so a module imported by a sibling root keeps its unittest bodies instead of
// becoming a bodyless non-root placeholder. Results follow input order.
public ModuleParseResult[] parseRootModules(
    in string[] filePaths,
    in string[] importPaths,
) {
    return compiler.parseRootModules(filePaths, importPaths, FrontendFlags.init);
}

public ModuleParseResult[] parseRootModules(
    in string[] filePaths,
    in string[] importPaths,
    in FrontendFlags flags,
) {
    return compiler.parseRootModules(filePaths, importPaths, flags);
}

public ModuleParseResult parseSnippet(in string source) {
    return compiler.parseSnippet(source, []);
}

public ModuleParseResult parseSnippet(
    in string source,
    in string[] importPaths,
) {
    return compiler.parseSnippet(source, importPaths);
}

public ModuleParseResult parseSnippetUncached(
    in string source,
    in string[] importPaths,
) {
    return compiler.parseSnippetUncached(source, importPaths);
}

public ModuleParseResult parseSnippetWithCheckActionContext(in string source) {
    return compiler.parseSnippetWithCheckActionContext(source, []);
}

public ModuleParseResult parseSnippetWithCheckActionContext(
    in string source,
    in string[] importPaths,
) {
    return compiler.parseSnippetWithCheckActionContext(
        source, importPaths, FrontendFlags.init,
    );
}

public ModuleParseResult parseSnippetWithCheckActionContext(
    in string source,
    in string[] importPaths,
    in FrontendFlags flags,
) {
    return compiler.parseSnippetWithCheckActionContext(source, importPaths, flags);
}

public ModuleParseResult parseModuleWithCheckActionContext(
    in string filePath,
    in string[] importPaths,
) {
    return compiler.parseModuleWithCheckActionContext(filePath, importPaths);
}

public void withCompilerLock(scope void delegate() action) {
    compiler.withLock(action);
}

public void withFrontendFlags(
    in FrontendFlags flags,
    scope void delegate() action,
) {
    const savedFlags = saveFrontendFlags;
    scope(exit) restoreFrontendFlags(savedFlags);
    applyFrontendFlags(flags);
    action();
}

// The lightning rod module: the first root module parsed in this process,
// where DMD's allInst+importedFrom funneling accumulates druntime/phobos
// template instances and TypeInfos (see parseLightningRod).
public imported!"dmd.dmodule".Module lightningRod() {
    return compiler._rod;
}

public imported!"dmd.expression".Expression parseExpression(in string source) {
    return compiler.parseExpression(source);
}

final class Compiler {
    private bool initialized;
    private imported!"core.sync.mutex".Mutex mutex;
    private imported!"dmd.dmodule".Module _rod;
    // Keyed by source content, import paths, and an optional caller-provided
    // identity salt; prevents re-registering the same root module in DMD's
    // process-global table.
    private imported!"dmd.dmodule".Module[string] sourceCache;

    private this() {
        import core.sync.mutex: Mutex;

        // Construct only. DMD's process-global state (allInst, the lightning
        // rod) depends on whether this is a dub run, which getopt has not seen
        // yet at module-ctor time, so the entry point calls initialize() once
        // it knows.
        mutex = new Mutex;
    }

    void initialize(in DubMode dubMode) {
        mutex.lock;
        scope(exit) mutex.unlock;

        if (initialized)
            return;

        initializeDmdState(dubMode);
        initialized = true;
    }

    private void requireInitialized() const {
        assert(
            initialized,
            "snakebite.frontend.compiler.initialize(dubMode) must be called "
            ~ "before parsing",
        );
    }

    private void initializeDmdState(in DubMode dubMode) {
        import dmd.common.charactertables:
            IdentifierCharLookup,
            IdentifierTable;
        import dmd.errors: diagnostics, fatalErrorHandler;
        import dmd.frontend: addImport, findImportPaths, initDMD;
        import dmd.globals: global;
        import std.algorithm.iteration: each;

        initDMD;
        findImportPaths.each!addImport;

        // Prevent DMD from calling exit() when too many cascading errors
        // accumulate. The shared parse path already checks global.errors after
        // fullSemantic and throws an Exception, so returning true here is safe.
        // This is intentionally process-global: the correct response to a DMD
        // fatal error in any snakebite test is a thrown Exception, not a
        // process abort that silently kills all subsequent tests.
        fatalErrorHandler = () => true;

        // Silence DMD's direct stderr printing; diagnostics are still captured
        // in the `diagnostics` array and surfaced via thrown exceptions.
        import dmd.console: Color;
        import dmd.errors: diagnosticHandler;
        import dmd.location: SourceLoc;
        import core.stdc.stdarg: va_list;

        diagnosticHandler = (
            const ref SourceLoc loc,
            Color, const(char)* header,
            const(char)* fmt,
            va_list args,
            const(char)* p1,
            const(char)* p2,
        )
        {
            import dmd.errors: Diagnostic, ErrorKind, diagnostics;
            import core.stdc.stdarg: va_copy, va_end;
            import core.stdc.stdio: vsnprintf;
            import core.stdc.string: strcmp;
            import std.string: fromStringz;

            if (!header || strcmp(header, "Error: ") != 0)
                return true;

            va_list copy;
            va_copy(copy, args);
            scope(exit) va_end(copy);

            const size = vsnprintf(null, 0, fmt, args);
            if (size <= 0) return true;

            auto buf = new char[size + 1];
            vsnprintf(buf.ptr, size + 1, fmt, copy);
            string message = buf[0 .. size].idup;

            if (p2) message = fromStringz(p2).idup ~ " " ~ message;
            if (p1) message = fromStringz(p1).idup ~ " " ~ message;

            diagnostics ~= Diagnostic(loc, message, ErrorKind.error);
            return true;
        };

        // Disable the error limit so DMD never prints "error limit (N) reached"
        // directly to stderr (a fprintf path that bypasses diagnosticHandler).
        global.params.v.errorLimit = 0;

        global.compileEnv.cCharLookupTable =
            IdentifierCharLookup.forTable(IdentifierTable.LR);
        global.compileEnv.dCharLookupTable =
            IdentifierCharLookup.forTable(IdentifierTable.LR);
        global.params.useUnitTests = true;
        // `dmd -unittest` pairs useUnitTests with the predefined `unittest`
        // version identifier (addDefaultVersionIdentifiers), so that
        // `version (unittest)` blocks compile in. initDMD's global._init()
        // runs that pairing while useUnitTests is still false, so register it
        // here, after the assignment and after _init, for both bin/ut and
        // --dub.
        import dmd.cond: VersionCondition;
        VersionCondition.addPredefinedGlobalIdent("unittest");
        resetErrors;

        // A dub package compiles like `dmd -unittest <files>`: it is its own
        // root set, so each reachable template instance homes on the package
        // root that instantiated it and emits in that root's object. The
        // lightning rod + allInst funnel is only for the single-snippet world,
        // and parsing the rod would actively break the dub link (its init
        // fixes druntime modules' importedFrom onto the rod, which the dub
        // codegen path never emits), so skip both entirely in dub mode.
        if (!dubMode) {
            global.params.allInst = true;
            parseLightningRod;
        }
    }

    // With allInst on, DMD parks a template instance on the root module
    // reached through the declaring module's importedFrom. The rod's own
    // semantic loads object/druntime, so those instances home here; a Phobos
    // module first imported by some snippet homes its instances on that
    // snippet instead, and link-time adoption (native codegen's adoptOrphans)
    // re-homes them onto the rod. Parse a module we control first so the
    // emission point is known: SystemLinker emits it, pruned, next to every
    // snippet object so the snippet's borrowed instances resolve at link
    // time.
    private void parseLightningRod() {
        import dmd.dmodule: Module;
        import dmd.frontend: dmdParseModule = parseModule;
        import dmd.globals: global;

        // A root module parsed before the rod would silently become the
        // accumulation point instead; fail loudly here, not with a mystery
        // link error later.
        foreach (i; 0 .. Module.amodules.length)
            assert(
                !Module.amodules[i].isRoot,
                "a root module was parsed before the lightning rod",
            );

        auto result = dmdParseModule("snakebite_rod.d", "module snakebite_rod;\n");
        assert(!result.diagnostics.hasErrors, "lightning rod failed to parse");
        fullSemanticWithInlineAsmSnapshot(result.module_);
        assert(global.errors == 0, "lightning rod failed semantic");

        _rod = result.module_;
        // dmd.frontend never sets Module.rootModule (only dmd's own main.d
        // does). Setting it lets callers assert the rod really was first and
        // points dsymbolsem's sc-less importedFrom fallback at the rod.
        Module.rootModule = _rod;
        resetErrors;
    }

    void shutdown() {
        import dmd.frontend: deinitializeDMD;

        mutex.lock;
        scope(exit) mutex.unlock;

        if (!initialized)
            return;

        deinitializeDMD;
        initialized = false;
    }

    void withLock(scope void delegate() action) {
        import dmd.errors: diagnostics;
        import dmd.globals: global;

        mutex.lock;
        resetErrors;
        scope(exit) {
            resetErrors;
            mutex.unlock;
        }
        action();
    }

    ModuleParseResult parseModule(
        in string filePath,
        in string[] importPaths,
        in FrontendFlags flags,
    ) {
        import std.conv: text;
        import std.file: readText;

        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        if (auto module_ = parsedModuleForFile(filePath, importPaths)) {
            ModuleParseResult result;
            result.module_ = module_;
            return result;
        }

        return parseSourceLocked(
            filePath.readText,
            importPaths,
            text("file\0", filePath),
            true,
            dmdFileName(filePath, importPaths),
            flags,
        );
    }

    ModuleParseResult[] parseRootModules(
        in string[] filePaths,
        in string[] importPaths,
        in FrontendFlags flags,
    ) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        return parseRootModulesLocked(filePaths, importPaths, flags);
    }

    private ModuleParseResult[] parseRootModulesLocked(
        in string[] filePaths,
        in string[] importPaths,
        in FrontendFlags flags,
    ) {
        import dmd.dmodule: Module;
        import dmd.dsymbolsem:
            dsymbolSemantic,
            importAll,
            runDeferredSemantic,
            runDeferredSemantic2,
            runDeferredSemantic3;
        import dmd.frontend: addImport, dmdParseModule = parseModule;
        import dmd.globals: global;
        import dmd.semantic2: semantic2;
        import dmd.semantic3: semantic3;
        import std.file: readText;

        const originalPathLength = global.path.length;
        scope(exit) global.path.setDim(originalPathLength);
        foreach (importPath; importPaths)
            addImport(importPath);

        const savedFlags = saveFrontendFlags;
        scope(exit) restoreFrontendFlags(savedFlags);
        applyFrontendFlags(flags);

        resetErrors;

        auto captured = capturedStderr;
        scope(failure) captured.discard;

        // Establish every file as a root before any import traversal. Parsing a
        // file through dmdParseModule sets its importedFrom to itself, so its
        // unittest bodies are retained; registering all roots first means a
        // sibling root's import resolves to the already-loaded root rather than
        // a fresh non-root parse with bodyless unittest placeholders.
        Module[] modules;
        foreach (filePath; filePaths) {
            if (auto existing = parsedModuleForFile(filePath, importPaths)) {
                if (!existing.isRoot)
                    throw new Exception(
                        "module " ~ filePath ~ " was parsed as a non-root "
                        ~ "import before root-set preparation",
                    );
                modules ~= existing;
                continue;
            }

            auto result = dmdParseModule(
                dmdFileName(filePath, importPaths),
                filePath.readText,
            );
            if (result.diagnostics.hasErrors)
                throw new Exception(diagnosticMessageWithLocations);
            modules ~= result.module_;
        }

        // Drive the shared semantic phases over the whole root set the way dmd
        // drives `-unittest <files>`: each phase runs across all roots before
        // the next begins.
        foreach (m; modules) m.importAll(null);
        import snakebite.frontend.dmd.functions:
            snapshotInlineAsmInstructions;
        foreach (m; modules) m.dsymbolSemantic(null);
        runDeferredSemantic;
        foreach (m; modules) m.semantic2(null);
        runDeferredSemantic2;
        foreach (m; modules) m.semantic3(null);
        runDeferredSemantic3;
        snapshotInlineAsmInstructions;
        if (global.errors != 0)
            throw new Exception(diagnosticMessageWithLocations);

        captured.replay;

        ModuleParseResult[] results;
        foreach (m; modules) {
            ModuleParseResult result;
            result.module_ = m;
            results ~= result;
        }
        return results;
    }

    ModuleParseResult parseSnippet(in string source, in string[] importPaths) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        return parseSourceLocked(source, importPaths, null, true);
    }

    ModuleParseResult parseSnippetUncached(
        in string source,
        in string[] importPaths,
    ) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        return parseSourceLocked(source, importPaths, null, false);
    }

    ModuleParseResult parseSnippetWithCheckActionContext(
        in string source,
        in string[] importPaths,
    ) {
        return parseSnippetWithCheckActionContext(source, importPaths, FrontendFlags.init);
    }

    ModuleParseResult parseSnippetWithCheckActionContext(
        in string source,
        in string[] importPaths,
        in FrontendFlags flags,
    ) {
        import dmd.astenums: CHECKACTION;
        import dmd.globals: global;
        import std.array: join;
        import std.conv: text;

        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        const originalCheckAction = global.params.checkAction;
        global.params.checkAction = CHECKACTION.context;
        scope(exit) global.params.checkAction = originalCheckAction;

        return parseSourceLocked(
            source,
            importPaths,
            text("checkaction=context", "\0", flags.compilerArguments.join("\0")),
            true,
            null,
            flags,
        );
    }

    ModuleParseResult parseModuleWithCheckActionContext(
        in string filePath,
        in string[] importPaths,
    ) {
        import dmd.astenums: CHECKACTION;
        import dmd.globals: global;
        import std.file: readText;
        import std.conv: text;

        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        const originalCheckAction = global.params.checkAction;
        global.params.checkAction = CHECKACTION.context;
        scope(exit) global.params.checkAction = originalCheckAction;

        return parseSourceLocked(
            filePath.readText,
            importPaths,
            text("checkaction=context\0", filePath),
            true,
            filePath,
        );
    }

    private imported!"dmd.expression".Expression parseExpression(in string source) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;
        return parseExpressionLocked(source);
    }

    private imported!"dmd.expression".Expression parseExpressionLocked(in string source) {
        import dmd.astcodegen: ASTCodegen;
        import dmd.errors: diagnostics;
        import dmd.errorsink: ErrorSinkNull;
        import dmd.expression: Expression;
        import dmd.globals: global;
        import dmd.parse: Parser;
        import dmd.tokens: TOK;

        resetErrors;
        auto errorSink = new ErrorSinkNull;

        scope parser = new Parser!ASTCodegen(
            null,
            source ~ '\0',
            false,
            errorSink,
            &global.compileEnv,
            global.params.useUnitTests,
        );

        parser.nextToken;
        auto root = parser.parseAssignExp();

        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        if (parser.token.value != TOK.endOfFile)
            throw new Exception("trailing tokens after expression");

        auto expression = cast(Expression) root;
        if (expression is null)
            throw new Exception("not an expression");

        return expression;
    }

    private ModuleParseResult parseSourceLocked(
        in string source,
        in string[] importPaths,
        in string cacheSalt,
        in bool useCache,
        in string filePath = null,
        in FrontendFlags flags = FrontendFlags.init,
    ) {
        import core.atomic: atomicFetchAdd;
        import dmd.errors: diagnostics;
        import dmd.frontend:
            addImport,
            dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.conv: text;

        const key = cacheKey(source, importPaths, cacheSalt);
        if (useCache)
        if (auto cached = key in sourceCache) {
            ModuleParseResult result;
            result.module_ = *cached;
            return result;
        }

        const originalPathLength = global.path.length;
        scope(exit) global.path.setDim(originalPathLength);
        foreach (importPath; importPaths)
            addImport(importPath);

        const savedFlags = saveFrontendFlags;
        scope(exit) restoreFrontendFlags(savedFlags);
        applyFrontendFlags(flags);

        resetErrors;

        const fileName = filePath is null ?
            text(
                "snippet_",
                atomicFetchAdd(_moduleCounter, 1u),
                ".d",
            ) :
            filePath;

        // DMD's `onFileReadError` writes `import path[N] = …` lines directly to
        // C stderr via `fprintf`, bypassing the diagnostic handler installed in
        // the constructor, so a failed import leaks raw text. Capture fd 2 for
        // the duration of the parse + semantic and only replay it when the cell
        // succeeds: a successful cell's raw stderr (e.g. `pragma(msg)`) is
        // legitimate output, while a failing cell's raw stderr is noise we drop
        // in favour of the captured diagnostic surfaced via the thrown
        // exceptions below.
        auto captured = capturedStderr;
        scope(failure) captured.discard;

        ModuleParseResult moduleResult = dmdParseModule(fileName, source);
        if (moduleResult.diagnostics.hasErrors)
            throw new Exception(diagnosticMessage);

        fullSemanticWithInlineAsmSnapshot(moduleResult.module_);
        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        captured.replay;

        if (useCache)
            sourceCache[key] = moduleResult.module_;

        return moduleResult;
    }

    private void fullSemanticWithInlineAsmSnapshot(
        imported!"dmd.dmodule".Module module_,
    ) {
        import dmd.dsymbolsem:
            dsymbolSemantic, importAll, runDeferredSemantic,
            runDeferredSemantic2, runDeferredSemantic3;
        import dmd.semantic2: semantic2;
        import dmd.semantic3: semantic3;
        import snakebite.frontend.dmd.functions:
            snapshotInlineAsmInstructions;

        module_.importedFrom = module_;
        module_.importAll(null);
        module_.dsymbolSemantic(null);
        runDeferredSemantic;
        module_.semantic2(null);
        runDeferredSemantic2;
        module_.semantic3(null);
        runDeferredSemantic3;
        snapshotInlineAsmInstructions;
    }

    private string cacheKey(
        in string source,
        in string[] importPaths,
        in string cacheSalt,
    ) const {
        import std.array: join;
        import std.conv: text;

        return text(source, "\0", importPaths.join("\0"), "\0", cacheSalt);
    }

    private imported!"dmd.dmodule".Module parsedModuleForFile(
        in string filePath,
        in string[] importPaths,
    ) const {
        import dmd.dmodule: Module;

        foreach (module_; Module.amodules)
            if (moduleSourceMatches(module_, filePath, importPaths))
                return module_;

        return null;
    }

    private bool moduleSourceMatches(
        imported!"dmd.dmodule".Module module_,
        in string filePath,
        in string[] importPaths,
    ) const {
        import std.path: absolutePath, buildNormalizedPath;

        const absPath = filePath.absolutePath.buildNormalizedPath;
        const sourcePath = module_.sourceFileName;
        if (sourcePath.absolutePath.buildNormalizedPath == absPath)
            return true;

        foreach (importPath; importPaths) {
            const candidate = sourcePath
                .absolutePath(importPath)
                .buildNormalizedPath;
            if (candidate == absPath)
                return true;
        }

        return false;
    }

    private string dmdFileName(in string filePath, in string[] importPaths) const {
        import std.algorithm.searching: startsWith;
        import std.path: absolutePath, buildNormalizedPath, relativePath;

        const absPath = filePath.absolutePath.buildNormalizedPath;
        foreach (importPath; importPaths) {
            const relPath = absPath.relativePath(
                importPath.absolutePath.buildNormalizedPath,
            );
            if (!relPath.startsWith(".."))
                return relPath;
        }

        return filePath;
    }
}

private struct SavedFrontendFlags {
    bool previewIn;
    bool transitionIn;
    bool ddocOutput;
    size_t versionIdentifierLength;
    size_t debugIdentifierLength;
    size_t stringImportPathLength;
    imported!"dmd.globals".FeatureState useDIP25;
    imported!"dmd.globals".FeatureState useDIP1000;
    bool ehnogc;
    bool useDIP1021;
    imported!"dmd.globals".FeatureState fieldwise;
    bool fixAliasThis;
    imported!"dmd.globals".FeatureState rvalueRefParam;
    imported!"dmd.globals".FeatureState safer;
    imported!"dmd.globals".FeatureState noSharedAccess;
    bool inclusiveInContracts;
    bool shortenedMethods;
    bool fixImmutableConv;
    bool fix16997;
    imported!"dmd.globals".FeatureState dtorFields;
    imported!"dmd.globals".FeatureState systemVariables;
    bool bitfields;
}

private SavedFrontendFlags saveFrontendFlags() {
    import dmd.globals: global;

    return SavedFrontendFlags(
        global.compileEnv.previewIn,
        global.compileEnv.transitionIn,
        global.compileEnv.ddocOutput,
        global.versionids.length,
        global.debugids.length,
        global.filePath.length,
        global.params.useDIP25,
        global.params.useDIP1000,
        global.params.ehnogc,
        global.params.useDIP1021,
        global.params.fieldwise,
        global.params.fixAliasThis,
        global.params.rvalueRefParam,
        global.params.safer,
        global.params.noSharedAccess,
        global.params.inclusiveInContracts,
        global.params.shortenedMethods,
        global.params.fixImmutableConv,
        global.params.fix16997,
        global.params.dtorFields,
        global.params.systemVariables,
        global.params.bitfields,
    );
}

private void restoreFrontendFlags(ref const SavedFrontendFlags saved) {
    import dmd.globals: global;

    global.compileEnv.previewIn = saved.previewIn;
    global.compileEnv.transitionIn = saved.transitionIn;
    global.compileEnv.ddocOutput = saved.ddocOutput;
    global.versionids.setDim(saved.versionIdentifierLength);
    global.debugids.setDim(saved.debugIdentifierLength);
    global.filePath.setDim(saved.stringImportPathLength);
    global.params.useDIP25 = saved.useDIP25;
    global.params.useDIP1000 = saved.useDIP1000;
    global.params.ehnogc = saved.ehnogc;
    global.params.useDIP1021 = saved.useDIP1021;
    global.params.fieldwise = saved.fieldwise;
    global.params.fixAliasThis = saved.fixAliasThis;
    global.params.rvalueRefParam = saved.rvalueRefParam;
    global.params.safer = saved.safer;
    global.params.noSharedAccess = saved.noSharedAccess;
    global.params.previewIn = saved.previewIn;
    global.params.inclusiveInContracts = saved.inclusiveInContracts;
    global.params.shortenedMethods = saved.shortenedMethods;
    global.params.fixImmutableConv = saved.fixImmutableConv;
    global.params.fix16997 = saved.fix16997;
    global.params.dtorFields = saved.dtorFields;
    global.params.systemVariables = saved.systemVariables;
    global.params.bitfields = saved.bitfields;
}

private void applyFrontendFlags(in FrontendFlags flags) {
    import dmd.arraytypes: Strings;
    import dmd.cli: Usage;
    import dmd.cond: DebugCondition, VersionCondition;
    import dmd.frontend: addStringImport;
    import dmd.globals: FeatureState, Param, global;
    import dmd.root.response: responseExpand;
    import dmd.root.string: toDString;
    import std.algorithm.searching: startsWith;
    import std.conv: text;
    import std.string: toStringz;

    if (flags.compilerArguments.length == 0)
        return;

    auto argumentText = ["dmd"] ~ flags.compilerArguments.dup;
    auto arguments = Strings(argumentText.length);
    foreach (i, argument; argumentText)
        arguments[i] = argument.toStringz;

    if (const missing = responseExpand(arguments))
        throw new Exception(text(
            "failed to expand dub compiler response file ",
            missing.toDString,
        ));

    Param parsedParams;
    foreach (argz; arguments[]) {
        const arg = argz.toDString;
        if (arg.startsWith("-preview=")) {
            const name = arg["-preview=".length .. $];
            if (!applyFeature!(Usage.previews)("preview", parsedParams, name))
                throw new Exception(text("unsupported DMD preview flag: ", arg));
            if (parsedParams.useDIP1021)
                parsedParams.useDIP1000 = FeatureState.enabled;
            if (parsedParams.useDIP1000 == FeatureState.enabled)
                parsedParams.useDIP25 = FeatureState.enabled;
        } else if (arg.startsWith("-revert=")) {
            const name = arg["-revert=".length .. $];
            if (!applyFeature!(Usage.reverts)("revert", parsedParams, name))
                throw new Exception(text("unsupported DMD revert flag: ", arg));
        } else if (arg == "-dip1000") {
            parsedParams.useDIP25 = FeatureState.enabled;
            parsedParams.useDIP1000 = FeatureState.enabled;
        } else if (arg == "-dip25")
            parsedParams.useDIP25 = FeatureState.enabled;
        else if (arg == "-dip1008")
            parsedParams.ehnogc = true;
        else if (arg.startsWith("-version="))
            VersionCondition.addGlobalIdent(arg["-version=".length .. $]);
        else if (arg.startsWith("-debug="))
            DebugCondition.addGlobalIdent(arg["-debug=".length .. $]);
        else if (arg.length > 2 && arg.startsWith("-J="))
            addStringImport(arg["-J=".length .. $]);
        else if (arg.length > 2 && arg.startsWith("-J"))
            addStringImport(arg["-J".length .. $]);
    }

    applyParsedFrontendParams(parsedParams);
    global.compileEnv.previewIn = global.params.previewIn;
    global.compileEnv.transitionIn = global.params.v.vin;
    global.compileEnv.ddocOutput = global.params.ddoc.doOutput;
}

private bool applyFeature(alias features)(
    in string flagName,
    ref imported!"dmd.globals".Param params,
    const(char)[] ident,
) {
    string cases() {
        string ret = `case "all":`;
        foreach (feature; features) {
            if (feature.deprecated_)
                continue;
            ret ~= `setFlagFor(flagName, params.` ~ feature.paramName ~ `);`;
        }
        ret ~= "return true;";

        foreach (feature; features) {
            ret ~= `case "` ~ feature.name ~ `":`;
            ret ~= `setFlagFor(flagName, params.`
                ~ feature.paramName
                ~ `); return true;`;
        }
        return ret;
    }

    switch (ident) {
        mixin(cases);
        default:
            return false;
    }
}

private void setFlagFor(
    in string flagName,
    ref bool value,
) @safe pure nothrow @nogc {
    value = flagName != "revert";
}

private void setFlagFor(
    in string flagName,
    ref imported!"dmd.globals".FeatureState value,
) @safe pure nothrow @nogc {
    import dmd.globals: FeatureState;

    value = flagName != "revert" ? FeatureState.enabled : FeatureState.disabled;
}

private void applyParsedFrontendParams(ref const imported!"dmd.globals".Param params) {
    import dmd.globals: global;

    global.params.useDIP25 = params.useDIP25;
    global.params.useDIP1000 = params.useDIP1000;
    global.params.ehnogc = params.ehnogc;
    global.params.useDIP1021 = params.useDIP1021;
    global.params.fieldwise = params.fieldwise;
    global.params.fixAliasThis = params.fixAliasThis;
    global.params.rvalueRefParam = params.rvalueRefParam;
    global.params.safer = params.safer;
    global.params.noSharedAccess = params.noSharedAccess;
    global.params.previewIn = params.previewIn;
    global.params.inclusiveInContracts = params.inclusiveInContracts;
    global.params.shortenedMethods = params.shortenedMethods;
    global.params.fixImmutableConv = params.fixImmutableConv;
    global.params.fix16997 = params.fix16997;
    global.params.dtorFields = params.dtorFields;
    global.params.systemVariables = params.systemVariables;
    global.params.bitfields = params.bitfields;
}

private string sourceFileName(imported!"dmd.dmodule".Module module_) @trusted {
    import std.string: fromStringz;

    // DMD owns `srcfile` for the lifetime of the Module; copy the
    // null-terminated string immediately so no borrowed pointer escapes.
    return module_.srcfile.toString.fromStringz.idup;
}

public string diagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.algorithm.iteration: filter, map;
    import std.array: array, join;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.message)
        .array;

    if (messages.length == 0)
        return "DMD reported an error without a diagnostic message.";

    return messages.join("\n");
}

// Like diagnosticMessage, but each message keeps its dmd-style source
// location ("file(line,column): ..."). Used where the message identifies a
// place in real package source (the dub bench preparation note) rather than
// a throwaway snippet.
public string diagnosticMessageWithLocations() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.algorithm.iteration: filter, map;
    import std.array: array, join;
    import std.conv: text;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.loc.filename.length == 0
            ? diagnostic.message
            : text(
                diagnostic.loc.filename,
                "(", diagnostic.loc.line, ",", diagnostic.loc.column, "): ",
                diagnostic.message,
            ))
        .array;

    if (messages.length == 0)
        return "DMD reported an error without a diagnostic message.";

    return messages.join("\n");
}

public void resetErrors() {
    import dmd.globals: global;
    import dmd.errors: diagnostics;
    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;
}

// Holds the saved C-level stderr (fd 2) and a temporary file collecting the raw
// stderr writes DMD performs while fd 2 is redirected.
struct CapturedStderr {
    import core.stdc.stdio: FILE;

    private int savedFd = -1;
    private FILE* sink;

    // Restore fd 2, then copy the captured bytes to the original stderr. Used
    // when the parse succeeds so legitimate raw output (e.g. `pragma(msg)`)
    // still reaches the user.
    void replay() @trusted nothrow {
        import core.stdc.stdio: fclose, fflush, fread, rewind, stderr;
        import core.sys.posix.unistd: write;

        const restoredFd = unwind;
        if (sink is null || restoredFd < 0) {
            close;
            return;
        }

        fflush(sink);
        rewind(sink);

        char[4096] buffer;
        for (size_t read = fread(buffer.ptr, 1, buffer.length, sink);
             read != 0;
             read = fread(buffer.ptr, 1, buffer.length, sink))
            write(restoredFd, buffer.ptr, read);

        close;
    }

    // Restore fd 2 and drop the captured bytes. Used when the parse fails so the
    // raw import-path noise is suppressed in favour of the thrown diagnostic.
    void discard() @trusted nothrow @nogc {
        unwind;
        close;
    }

    // @trusted: flushes C stderr and swaps fd 2 back to the saved descriptor;
    // operates only on descriptors this struct owns. Returns the restored fd.
    private int unwind() @trusted nothrow @nogc {
        import core.stdc.stdio: fflush, stderr;
        import core.sys.posix.unistd: dup2;

        if (savedFd < 0)
            return -1;

        fflush(stderr);
        dup2(savedFd, 2);
        return savedFd;
    }

    // @trusted: closes the saved descriptor and the temporary sink, both owned
    // by this struct; idempotent via the sentinel/null guards.
    private void close() @trusted nothrow @nogc {
        import core.stdc.stdio: fclose;
        import core.sys.posix.unistd: closeFd = close;

        if (savedFd >= 0) {
            closeFd(savedFd);
            savedFd = -1;
        }
        if (sink !is null) {
            fclose(sink);
            sink = null;
        }
    }
}

// Redirect fd 2 into a temporary file and return a handle that can replay or
// discard the captured output. DMD writes some diagnostics (e.g. failed-import
// path lines and `pragma(msg)` text) straight to C stderr, bypassing the
// diagnostic handler; capturing lets the caller decide per cell whether the raw
// output is wanted.
// @trusted: tmpfile/fileno/dup/dup2 operate only on file descriptors and a
// C-owned FILE*; no D memory is touched, and a failed setup leaves stderr
// untouched with savedFd == -1 so replay/discard are no-ops.
CapturedStderr capturedStderr() @trusted nothrow @nogc {
    import core.stdc.stdio: fileno, tmpfile;
    import core.sys.posix.unistd: dup, dup2;

    auto sink = tmpfile;
    if (sink is null)
        return CapturedStderr.init;

    const sinkFd = fileno(sink);
    if (sinkFd < 0) {
        import core.stdc.stdio: fclose;
        fclose(sink);
        return CapturedStderr.init;
    }

    CapturedStderr captured;
    captured.savedFd = dup(2);
    captured.sink = sink;
    dup2(sinkFd, 2);

    return captured;
}
