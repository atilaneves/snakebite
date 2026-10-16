module snakebite.frontend.inlineasm;


private:


// No backend executes inline assembler (see docs/adr/0012). Walk every
// root module's own declarations once, after semantic analysis finishes.
// Report one `dmd.errors.error` for each function that still has an
// unguarded `asm` block. This fails the load with a clear message,
// instead of a backend hitting the block at run time. Reporting through
// `error`, not a thrown exception, increases `global.errors` the same
// way every other frontend error does. So the caller's own
// `global.errors` check formats this failure like any other semantic
// error. See docs/adr/0012 for why only a root-owned function is
// reported. The same walk also rejects a reference to a C `setjmp` or
// `longjmp` function (see docs/adr/0014).
//
// On an LDC host the same walk refuses LLVM inline IR and LDC's inline
// assembler (`pragma(LDC_inline_ir)`, `pragma(LDC_inline_asm)`) called from
// root-owned code. `dependencyImage` says whether a dependency image will
// hold a copy that LDC compiled of each instance of a dependency template
// that root code causes; when none will, the root program runs those
// instances and the walk refuses the ones that call them too.
public void reportInlineAsmDiagnostics(
    imported!"dmd.dmodule".Module[] rootModules,
    in bool dependencyImage,
) {
    scope collector = new InlineAsmCollector(rootModules, dependencyImage);
    foreach (module_; rootModules)
        module_.accept(collector);
}

// Snakebite does not implement `D_InlineAsm_X86_64` (see docs/adr/0012).
// Walk `rootModule`'s syntax tree once. Pre-compute every
// `D_InlineAsm_X86_64` `VersionCondition` that no semantic pass has
// resolved yet to `Include.no`. This is exactly what dmd would compute if
// the identifier were undefined. Call this once per freshly parsed root
// module, before the shared semantic phases run, so that no condition is
// resolved yet. See docs/adr/0012 for why the walk must run this early.
// A module that becomes root-owned only after dmd loaded it as a plain
// import (`analyseLoadedRootOwnedImports`) has its module-scope
// conditions resolved already; a resolved condition keeps its answer,
// because dmd has already built the module's symbols from it.
public void disableInlineAsmVersion(
    imported!"dmd.dmodule".Module rootModule,
) {
    scope gate = new InlineAsmVersionGate(rootModule);
    rootModule.accept(gate);
}


// Named distinctly from `imagesource.d`'s own `Collector` and from
// `DeclarationCollector` (`declarationcollector.d`), the shared base both
// extend: all three are plain `extern(C++) class`es with no explicit C++
// namespace, so identical class names mangle to the identical C++ symbol
// and the linker keeps only one definition - silently routing calls meant
// for this class into another one's vtable instead of a link error.
private extern(C++) class InlineAsmCollector
        : imported!"snakebite.frontend.declarationcollector".DeclarationCollector {
    import snakebite.frontend.declarationcollector: DeclarationCollector;
    alias visit = DeclarationCollector.visit;

    import dmd.attrib: MixinDeclaration;
    import dmd.dmodule: Module;
    import dmd.dsymbolsem: include;
    import dmd.dtemplate: TemplateMixin;
    import dmd.errors: error;
    import dmd.expression: SymbolExp;
    import dmd.declaration: VarDeclaration;
    import dmd.dsymbol: Dsymbol;
    import dmd.func: FuncDeclaration;
    import dmd.location: Loc;

    private bool[Module] _rootModules;
    private bool[FuncDeclaration] _visited;
    private bool[Loc] _reported;
    private bool[string] _reportedOwners;
    private Dsymbol _owner;
    private bool _dependencyImage;

    private extern(D) this(Module[] rootModules, in bool dependencyImage) {
        foreach (module_; rootModules)
            _rootModules[module_] = true;
        _dependencyImage = dependencyImage;
    }

    // Whether the root program itself runs the body of `symbol`: the body is
    // root-owned, or it is part of an instance of a dependency template and
    // no dependency image holds a copy that LDC compiled of that instance.
    private extern(D) bool isRunByRoot(Dsymbol symbol) {
        return isRootOwned(symbol) || isRootInstance(symbol);
    }

    private extern(D) bool isRootInstance(Dsymbol symbol) {
        if (!ldcHost || _dependencyImage)
            return false;
        for (auto enclosing = symbol; enclosing !is null; enclosing = enclosing.parent)
            if (enclosing.isTemplateInstance !is null)
                return true;
        return false;
    }

    // The same question `Program.isRootOwned` (backend.d) answers, so the
    // predicate itself lives once, in `snakebite.frontend.dmd.functions`;
    // both forward to it (docs/adr/0009: one root-owned predicate).
    private extern(D) bool isRootOwned(Dsymbol function_) const {
        import snakebite.frontend.dmd.functions:
            frontendIsRootOwned = isRootOwned;

        return frontendIsRootOwned(function_, _rootModules);
    }

    // `mixin WithAsm;` instantiates a `mixin template` as a
    // `TemplateMixin`. `TemplateMixin : TemplateInstance`, but it overrides
    // `accept` with its own `v.visit(this)`, so it dispatches to this
    // overload rather than `DeclarationCollector`'s `visit(TemplateInstance)`;
    // `SemanticTimeTransitiveVisitor`'s own default `visit(TemplateMixin)`
    // walks only the mixin's type and template arguments, never its
    // instantiated members, so without this override a root-owned function
    // inside a root-owned mixin template's own body was never walked.
    override void visit(TemplateMixin instance) {
        if (instance.members !is null)
            foreach (member; *instance.members)
                member.accept(this);
    }

    // `mixin("...")` at declaration scope is a `MixinDeclaration`;
    // `SemanticTimeTransitiveVisitor`'s own traversal walks only its
    // string argument expression for this exact type (parse-time shape,
    // before expansion), shadowing `DeclarationCollector`'s generic
    // `AttribDeclaration` override, so a mixin's own expanded declarations
    // - including any `asm` block they compile in - are never reached at
    // all (docs/adr/0012's known mixin gap: the version gate cannot see
    // inside the mixin's source text either, so its `asm` compiles in
    // rather than out). `include` returns `.decl`, the declarations the
    // mixin expanded into once semantic analysis has run.
    override void visit(MixinDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
                member.accept(this);
    }

    // Every other `visit` override in this class walks straight into a
    // `Dsymbol`'s own children, so a declaration reached twice through two
    // different paths is walked twice - harmless everywhere else, since
    // dmd's own AST has no cycles there. `AliasDeclaration` breaks that:
    // `SemanticTimeTransitiveVisitor.visit(AliasDeclaration)` follows
    // `aliassym` unconditionally, and a local alias to its own enclosing
    // function (`alias self = f;` inside `f`'s body) resolves `aliassym`
    // back to `f` itself. Without this guard, that walked back into `f`'s
    // `fbody`, found the same alias again, and recursed without end -
    // valid code with no `asm` block anywhere overflowed the stack during
    // load. `_visited` is keyed by declaration, not by traversal path, so
    // it also collapses any other route back into an already-walked
    // function this class does not know about by name.
    override void visit(FuncDeclaration function_) {
        if (function_ in _visited)
            return;
        _visited[function_] = true;
        auto outer = _owner;
        _owner = function_;
        scope(exit) _owner = outer;
        if (function_.hasInlineAsm && isRootOwned(function_))
            error(
                function_.loc,
                "inline assembler is not supported in `%s`: guard it "
                ~ "with `version (D_InlineAsm_X86_64)`, which snakebite "
                ~ "does not define",
                function_.toPrettyChars,
            );
        if (function_.fbody !is null)
            function_.fbody.accept(this);
    }

    private extern(D) void reportInlineCode(
        SymbolExp expression, FuncDeclaration function_,
    ) {
        import std.string: fromStringz, toStringz;

        const construct = inlineCodeName(function_);
        // By name: dmd can hold two instances of one template for one
        // argument list, and the user sees one.
        const owner = _owner.toPrettyChars.fromStringz.idup;
        if (construct is null || owner in _reportedOwners)
            return;
        _reportedOwners[owner] = true;
        error(
            expression.loc,
            "%s is not supported in `%s`: no backend runs it. Only code "
            ~ "that LDC compiled into the host or the dependency image "
            ~ "can use it",
            construct.toStringz,
            owner.toStringz,
        );
    }

    // The initializer of a module-scope variable or of an aggregate field
    // is guest code too: a function pointer stored there is called later.
    override void visit(VarDeclaration variable) {
        auto outer = _owner;
        if (_owner is null)
            _owner = variable;
        scope(exit) _owner = outer;
        super.visit(variable);
    }

    // Any reference to a `setjmp`/`longjmp` function from a root-owned
    // declaration, not only a direct call: `VarExp.var` is the resolved
    // declaration, so an alias is already seen through, and taking the
    // address (`&longjmp`) reaches a `SymOffExp` or a `VarExp` too. A
    // template body is reached once for each instance at the same
    // location, so the error is reported once for each location.
    override void visit(SymbolExp expression) {
        import std.string: toStringz;

        if (_owner is null)
            return;
        auto function_ = expression.var.isFuncDeclaration;
        if (function_ !is null && ldcHost && isRunByRoot(_owner)) {
            reportInlineCode(expression, function_);
            // A program that an earlier load made the instance for does
            // not list it in its own members, so the call is the way to it,
            // at any depth.
            if (function_.fbody !is null && function_ !in _visited
                    && isRunByRoot(function_))
                function_.accept(this);
        }
        if (!isRootOwned(_owner))
            return;
        if (function_ is null || !isNonLocalJump(function_))
            return;
        if (expression.loc in _reported)
            return;
        _reported[expression.loc] = true;
        error(
            expression.loc,
            "`%s` is not supported in guest code: a backend cannot "
            ~ "jump back to a stack frame it has already left",
            nonLocalJumpName(function_).toStringz,
        );
    }
}

// Only an LDC host has LDC's pragmas for inline IR and inline assembler.
private version (LDC) enum ldcHost = true; else enum ldcHost = false;

// A call of a declaration that LDC compiles to LLVM inline IR or to inline
// assembler. Nothing here runs it (docs/adr/0012): it belongs to code that
// LDC compiled, in the host or in the image.
private string inlineCodeName(imported!"dmd.func".FuncDeclaration function_) {
    version (LDC) {
        import gen.dpragma: LDCPragma;

        with (LDCPragma) switch (function_.llvmInternal) {
            case LLVMinline_ir: return "LLVM inline IR (`pragma(LDC_inline_ir)`)";
            case LLVMinline_asm: return "inline assembler (`pragma(LDC_inline_asm)`)";
            default: return null;
        }
    } else
        return null;
}

// The C functions that save and restore a stack context, by the name the
// linker sees: `pragma(mangle)` wins over the D name, as it does there.
// Matching on C linkage and name, not on the declaring module, also
// covers a guest's own redeclaration of the function. A function with a
// body is guest code that backends can run, not the libc function.
private bool isNonLocalJump(imported!"dmd.func".FuncDeclaration function_) {
    import dmd.astenums: LINK;
    import std.algorithm: canFind;

    static immutable names = [
        "_setjmp", "setjmp", "__sigsetjmp", "sigsetjmp",
        "longjmp", "_longjmp", "siglongjmp",
    ];

    return function_.fbody is null
        && function_.resolvedLinkage == LINK.c
        && names.canFind(linkName(function_));
}

// The name in the diagnostic is the libc function the guest called, not
// the glibc symbol behind it: druntime aliases `setjmp` to `_setjmp` and
// `sigsetjmp` to `__sigsetjmp`.
private string nonLocalJumpName(
    imported!"dmd.func".FuncDeclaration function_,
) {
    switch (linkName(function_)) {
        case "_setjmp": return "setjmp";
        case "__sigsetjmp": return "sigsetjmp";
        default: return linkName(function_);
    }
}

private string linkName(imported!"dmd.func".FuncDeclaration function_) {
    return function_.mangleOverride.length
        ? function_.mangleOverride.idup
        : function_.ident.toString.idup;
}

// Named distinctly from `InlineAsmCollector` above and `imagesource.d`'s
// `Collector` for the same reason as that one: an `extern(C++) class` with
// no explicit C++ namespace mangles by name alone, so a duplicate name
// would silently collide at link time instead of erroring.
//
// Extends `SemanticTimeTransitiveVisitor`, not the parse-time-only
// `ParseTimeTransitiveVisitor` template. Every AST node's `accept` takes
// the one concrete `Visitor` class dmd's headers build against. Only
// `SemanticTimeTransitiveVisitor` works here. The walk covers every
// branch unconditionally, not only the branch `include` would pick. It
// reaches `TemplateDeclaration` through its own syntactic `members`,
// not through `TemplateInstance`, which has none yet at this point. See
// docs/adr/0012 for why the walk must cover a root module's whole syntax
// tree this way. `StaticIfCondition` (`static if`, not a version) never
// reaches `visit(VersionCondition)` below.
private extern(C++) class InlineAsmVersionGate
        : imported!"snakebite.frontend.declarationcollector".ImportCSafeVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    import snakebite.frontend.declarationcollector: ImportCSafeVisitor;
    alias visit = ImportCSafeVisitor.visit;

    import dmd.cond: Include, VersionCondition;
    import dmd.declaration: AliasDeclaration;
    import dmd.dmodule: Module;
    import dmd.dsymbol: Dsymbol;
    import dmd.identifier: Identifier;

    // Pooled once per walk, not on every `VersionCondition` visited:
    // `Identifier.idPool` hashes and looks up its argument in dmd's global
    // identifier table on every call, and a root module's syntax tree can
    // hold many `version (...)` conditions.
    private const Identifier _inlineAsmIdent;
    private Module _module;
    private bool[Dsymbol] _aliasTargets;

    private extern(D) this(Module module_) {
        _inlineAsmIdent = Identifier.idPool("D_InlineAsm_X86_64");
        _module = module_;
    }

    // Once dmd has analysed an alias, `aliassym` is the declaration it
    // names: one in another module, whose conditions are not this
    // module's to gate, or one in this module, possibly the alias's own
    // enclosing function (`alias self = f;` in `f`). Only this module's
    // own declarations are walked, each once. Before analysis `aliassym`
    // is the alias's own syntax (a function literal, say), with no parent.
    override void visit(AliasDeclaration declaration) {
        auto target = declaration.aliassym;
        if (target is null) {
            SemanticTimeTransitiveVisitor.visit(declaration);
            return;
        }

        import snakebite.frontend.dmd.functions: moduleOf;

        const owner = moduleOf(target);
        if ((owner !is null && owner !is _module) || target in _aliasTargets)
            return;
        _aliasTargets[target] = true;
        target.accept(this);
    }

    // A version LEVEL condition, `version (2) { ... }`, has a `null`
    // `VersionCondition.ident` (dmd's `DVCondition` doc comment: "If
    // `null`, this condition will use an integer level"). `is` identity
    // comparison does not dereference either side, so a `null` `ident`
    // simply compares unequal to the pooled identifier below; it can never
    // be `D_InlineAsm_X86_64`, which is never anonymous.
    override void visit(VersionCondition condition) {
        if (condition.ident is _inlineAsmIdent
                && condition.inc == Include.notComputed)
            condition.inc = Include.no;
    }
}
