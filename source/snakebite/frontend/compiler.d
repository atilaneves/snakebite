module snakebite.frontend.compiler;

private:

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

// Whether this process compiles many small snippets (bin/ut, the REPL) or one
// whole program as a single root set (`dmd -unittest <files>`). The snippet
// world needs the lightning rod + allInst to funnel every tiny fixture's
// borrowed template instances; a whole program is its own root set and so
// needs neither -- and must not parse the rod, or druntime modules home their
// instances on the rod (which is never emitted) instead of on the program
// root that instantiated them.
public alias Snippets = imported!"std.typecons".Flag!"snippets";

// Initialise DMD's process-global state for this process. Must be called once,
// before any parse, by the entry point (it knows what kind of process this is).
// Idempotent: a second call is a no-op.
public void initialize(in Snippets snippets) {
    compiler.initialize(snippets);
}

// Parse a set of files as root modules, modelling `dmd -unittest <files>
// -I<paths>`: every file is established as a root before any import traversal,
// so a module imported by a sibling root keeps its unittest bodies instead of
// becoming a bodyless non-root placeholder. Results follow input order.
public imported!"dmd.dmodule".Module[] parseRootModules(
    in string[] filePaths,
    in string[] importPaths,
    in FrontendFlags flags,
) {
    return compiler.parseRootModules(filePaths, importPaths, flags);
}

public imported!"dmd.dmodule".Module parseSnippet(in string source) {
    return compiler.parseSnippet(source);
}

// Parse several whole guest programs, driving the shared semantic phases
// over the ones not already cached in one batched pass. Unlike `eval`'s
// snippets (wrapped as structs inside one shared module by the caller),
// two guest programs can each declare `main` at module scope, so they
// cannot be concatenated into a single module; each source becomes its own
// module here, but dmd's semantic setup cost is still paid once for the
// whole batch rather than once per source. Results follow input order.
public imported!"dmd.dmodule".Module[] parseSnippets(in string[] sources) {
    return compiler.parseSnippets(sources);
}

public void withCompilerLock(scope void delegate() action) {
    compiler.withLock(action);
}

final class Compiler {
    private bool initialized;
    private imported!"core.sync.mutex".Mutex mutex;
    // Keyed by source content; prevents re-registering the same root module
    // in DMD's process-global table.
    private imported!"dmd.dmodule".Module[string] sourceCache;

    private this() {
        import core.sync.mutex: Mutex;

        // Construct only. DMD's process-global state (allInst, the lightning
        // rod) depends on whether this process compiles snippets or a whole
        // program, which getopt has not seen yet at module-ctor time, so the
        // entry point calls initialize() once it knows.
        mutex = new Mutex;
    }

    void initialize(in Snippets snippets) {
        mutex.lock;
        scope(exit) mutex.unlock;

        if (initialized)
            return;

        initializeDmdState(snippets);
        initialized = true;
    }

    private void requireInitialized() const {
        assert(
            initialized,
            "snakebite.frontend.compiler.initialize(snippets) must be called "
            ~ "before parsing",
        );
    }

    private void initializeDmdState(in Snippets snippets) {
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
        // here, after the assignment and after _init, for both worlds.
        import dmd.cond: VersionCondition;
        VersionCondition.addPredefinedGlobalIdent("unittest");
        resetErrors;

        // A whole program compiles like `dmd -unittest <files>`: it is its own
        // root set, so each reachable template instance homes on the program
        // root that instantiated it and emits in that root's object. The
        // lightning rod + allInst funnel is only for the snippet world, and
        // parsing the rod would actively break a whole program (its init
        // fixes druntime modules' importedFrom onto the rod, which is never
        // emitted), so skip both entirely otherwise.
        if (snippets) {
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
        fullSemantic(result.module_);
        assert(global.errors == 0, "lightning rod failed semantic");

        // dmd.frontend never sets Module.rootModule (only dmd's own main.d
        // does). Setting it lets callers assert the rod really was first and
        // points dsymbolsem's sc-less importedFrom fallback at the rod.
        Module.rootModule = result.module_;
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

    imported!"dmd.dmodule".Module[] parseRootModules(
        in string[] filePaths,
        in string[] importPaths,
        in FrontendFlags flags,
    ) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        return parseRootModulesLocked(filePaths, importPaths, flags);
    }

    private imported!"dmd.dmodule".Module[] parseRootModulesLocked(
        in string[] filePaths,
        in string[] importPaths,
        in FrontendFlags flags,
    ) {
        import dmd.dmodule: Module;
        import dmd.frontend: addImport, dmdParseModule = parseModule;
        import dmd.globals: global;
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
        driveSharedSemantic(modules);
        if (global.errors != 0)
            throw new Exception(diagnosticMessageWithLocations);

        captured.replay;

        return modules;
    }

    imported!"dmd.dmodule".Module parseSnippet(in string source) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        return parseSourceLocked(source);
    }

    imported!"dmd.dmodule".Module[] parseSnippets(in string[] sources) {
        mutex.lock;
        scope(exit) mutex.unlock;
        requireInitialized;

        return parseSnippetsLocked(sources);
    }

    private imported!"dmd.dmodule".Module parseSourceLocked(in string source) {
        import core.atomic: atomicFetchAdd;
        import dmd.errors: diagnostics;
        import dmd.frontend: dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.conv: text;

        if (auto cached = source in sourceCache)
            return *cached;

        resetErrors;

        const fileName = text(
            "snippet_",
            atomicFetchAdd(_moduleCounter, 1u),
            ".d",
        );

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

        auto moduleResult = dmdParseModule(fileName, source);
        if (moduleResult.diagnostics.hasErrors)
            throw new Exception(diagnosticMessage);

        fullSemantic(moduleResult.module_);
        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        captured.replay;

        sourceCache[source] = moduleResult.module_;

        return moduleResult.module_;
    }

    private void fullSemantic(imported!"dmd.dmodule".Module module_) {
        module_.importedFrom = module_;
        driveSharedSemantic([module_]);
    }

    // Parse each of `sources` not already in `sourceCache` as its own module,
    // then drive the shared semantic phases across those newly parsed modules
    // together, so dmd's per-batch setup cost (deferred semantic queues, etc.)
    // is paid once for the whole batch instead of once per source. Already
    // cached modules are returned as-is, in the same position as their source.
    private imported!"dmd.dmodule".Module[] parseSnippetsLocked(
        in string[] sources,
    ) {
        import dmd.dmodule: Module;
        import core.atomic: atomicFetchAdd;
        import dmd.frontend: dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.conv: text;

        resetErrors;

        auto captured = capturedStderr;
        scope(failure) captured.discard;

        auto modules = new Module[sources.length];
        string[] freshSources;
        Module[] freshModules;

        foreach (i, source; sources) {
            if (auto cached = source in sourceCache) {
                modules[i] = *cached;
                continue;
            }

            const fileName = text(
                "snippet_",
                atomicFetchAdd(_moduleCounter, 1u),
                ".d",
            );
            auto result = dmdParseModule(fileName, source);
            if (result.diagnostics.hasErrors)
                throw new Exception(diagnosticMessage);

            modules[i] = result.module_;
            freshSources ~= source;
            freshModules ~= result.module_;
        }

        driveSharedSemantic(freshModules);
        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        captured.replay;

        foreach (i, source; freshSources)
            sourceCache[source] = freshModules[i];

        return modules;
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

// Drive dmd's shared semantic phases (the ones that must see every root
// before the next phase starts, e.g. deferred semantic) across `modules`,
// the way `dmd -unittest <files>` drives them across its whole root set.
// Shared by the file-backed root set (`parseRootModulesLocked`) and the
// in-memory snippet batches (`fullSemantic`, `parseSnippetsLocked`) so the
// phase order is defined once. Leaves `global.errors` for the caller to
// check: what counts as fatal differs (root-set parsing reports locations,
// snippet parsing does not).
private void driveSharedSemantic(imported!"dmd.dmodule".Module[] modules) {
    import dmd.dsymbolsem:
        dsymbolSemantic,
        importAll,
        runDeferredSemantic,
        runDeferredSemantic2,
        runDeferredSemantic3;
    import dmd.semantic2: semantic2;
    import dmd.semantic3: semantic3;

    foreach (m; modules) m.importAll(null);
    foreach (m; modules) m.dsymbolSemantic(null);
    runDeferredSemantic;
    foreach (m; modules) m.semantic2(null);
    runDeferredSemantic2;
    foreach (m; modules) m.semantic3(null);
    runDeferredSemantic3;
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
