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
// reported.
public void reportInlineAsmDiagnostics(
    imported!"dmd.dmodule".Module[] rootModules,
) {
    scope collector = new InlineAsmCollector(rootModules);
    foreach (module_; rootModules)
        module_.accept(collector);
}

// Snakebite does not implement `D_InlineAsm_X86_64` (see docs/adr/0012).
// Walk `rootModule`'s freshly parsed, not yet semantically analysed
// syntax tree once. Pre-compute every `D_InlineAsm_X86_64`
// `VersionCondition` to `Include.no`. This is exactly what dmd would
// compute if the identifier were undefined. Do this before any semantic
// pass reaches the condition. Call this once per freshly parsed root
// module, before the shared semantic phases run. See docs/adr/0012 for
// why the walk must run this early.
public void disableInlineAsmVersion(
    imported!"dmd.dmodule".Module rootModule,
) {
    scope gate = new InlineAsmVersionGate;
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
    import dmd.func: FuncDeclaration;

    private bool[Module] _rootModules;
    private bool[FuncDeclaration] _visited;

    private extern(D) this(Module[] rootModules) {
        foreach (module_; rootModules)
            _rootModules[module_] = true;
    }

    // The same question `Program.isRootOwned` (backend.d) answers, so the
    // predicate itself lives once, in `snakebite.frontend.dmd.functions`;
    // both forward to it (docs/adr/0009: one root-owned predicate).
    private extern(D) bool isRootOwned(FuncDeclaration function_) const {
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
        : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    import dmd.cond: Include, VersionCondition;
    import dmd.identifier: Identifier;

    // Pooled once per walk, not on every `VersionCondition` visited:
    // `Identifier.idPool` hashes and looks up its argument in dmd's global
    // identifier table on every call, and a root module's syntax tree can
    // hold many `version (...)` conditions.
    private const Identifier _inlineAsmIdent;

    private extern(D) this() {
        _inlineAsmIdent = Identifier.idPool("D_InlineAsm_X86_64");
    }

    // A version LEVEL condition, `version (2) { ... }`, has a `null`
    // `VersionCondition.ident` (dmd's `DVCondition` doc comment: "If
    // `null`, this condition will use an integer level"). `is` identity
    // comparison does not dereference either side, so a `null` `ident`
    // simply compares unequal to the pooled identifier below; it can never
    // be `D_InlineAsm_X86_64`, which is never anonymous.
    override void visit(VersionCondition condition) {
        if (condition.ident is _inlineAsmIdent)
            condition.inc = Include.no;
    }
}
