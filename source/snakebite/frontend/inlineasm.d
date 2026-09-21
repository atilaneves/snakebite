module snakebite.frontend.inlineasm;


private:


// No backend executes inline assembler (see docs/adr/0012). dmd's own
// statement semantic sets `FuncDeclaration.hasInlineAsm` on the function
// that holds an `asm` block instead of erroring (the shim at
// `source/dmd/iasm/package.d` does this on purpose, so druntime modules
// with `asm` still pass semantic analysis). Walk every root module's own
// declarations once, after semantic analysis finishes, and return one
// diagnostic line per function that still has an unguarded `asm` block, so
// the frontend can fail the load with a clear message instead of a backend
// hitting the block at run time. An empty result means the root modules are
// clear.
// Dependency modules keep `D_InlineAsm_X86_64` defined (docs/adr/0012), so
// a dependency template such as `core.internal.atomic.atomicFetchAdd`
// really does compile its `asm` body in and set `hasInlineAsm` on its own
// `FuncDeclaration`. Root code instantiating that template makes dmd home
// the resulting `TemplateInstance` in the root module's own scope, so a
// walk from the root module reaches that dependency `FuncDeclaration`
// too; `Dsymbol.getModule` gives back the module that owns the
// declaration regardless of where the walk reached it from, so only a
// `FuncDeclaration` whose own module is one of `rootModules` is
// root-owned and worth a diagnostic.
public string[] inlineAsmDiagnostics(
    imported!"dmd.dmodule".Module[] rootModules,
) {
    scope collector = new InlineAsmCollector(rootModules);
    foreach (module_; rootModules)
        module_.accept(collector);
    return collector.lines;
}

// The D language specification gives `D_InlineAsm_X86_64` one meaning:
// "inline assembler for X86-64 is implemented" (docs/adr/0012). Snakebite
// does not implement it, so a root module is parsed as if this identifier
// were undefined, while dependency modules keep it (ADR-0009: they are
// compiled by real dmd and called across the barrier, and their own
// type-checking, e.g. `core.internal.atomic`, needs it).
//
// dmd resolves a `version (...)` block through
// `IncludeVisitor.visit(VersionCondition)`: once `Condition.inc` is no
// longer `notComputed`, that cached value wins and the identifier lookup
// never runs again. `vc.mod` (the module a `VersionCondition` checks
// itself against, before falling back to `global.versionids`) is fixed at
// parse time to the module whose source text holds the `version (...)`,
// and a template body resolves against its declaring module. So walk
// `rootModule`'s freshly parsed, not yet semantically analysed syntax
// tree once, and pre-compute every `D_InlineAsm_X86_64`
// `VersionCondition` to `Include.no` - exactly what dmd would compute
// were the identifier undefined - before any semantic pass reaches it.
// Call this once per freshly parsed root module, before the shared
// semantic phases run.
public void disableInlineAsmVersion(
    imported!"dmd.dmodule".Module rootModule,
) {
    scope gate = new InlineAsmVersionGate;
    rootModule.accept(gate);
}


// Named distinctly from `dependencyimage.d`'s own `Collector`: both are
// plain `extern(C++) class`es with no explicit C++ namespace, so identical
// class names mangle to the identical C++ symbol and the linker keeps only
// one definition - silently routing calls meant for this class into the
// other one's vtable instead of a link error.
private extern(C++) class InlineAsmCollector
        : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    import dmd.attrib: AttribDeclaration, ConditionalDeclaration,
        MixinDeclaration;
    import dmd.dmodule: Module;
    import dmd.dsymbolsem: include;
    import dmd.dtemplate: TemplateDeclaration, TemplateInstance,
        TemplateMixin;
    import dmd.expression: FuncExp;
    import dmd.func: CtorDeclaration, DtorDeclaration,
        FuncDeclaration, FuncLiteralDeclaration, InvariantDeclaration,
        NewDeclaration, PostBlitDeclaration, SharedStaticCtorDeclaration,
        SharedStaticDtorDeclaration, StaticCtorDeclaration,
        StaticDtorDeclaration, UnitTestDeclaration;

    private bool[Module] _rootModules;
    private bool[FuncDeclaration] _visited;
    private string[] _lines;

    private extern(D) this(Module[] rootModules) {
        foreach (module_; rootModules)
            _rootModules[module_] = true;
    }

    private extern(D) string[] lines() {
        return _lines;
    }

    private extern(D) bool isRootOwned(FuncDeclaration function_) {
        return (function_.getModule in _rootModules) !is null;
    }

    // An uninstantiated template contributes no code to the build, so its
    // body is never walked; a used template's own instance is reached
    // through `TemplateInstance` below, and dmd sets `hasInlineAsm` on
    // each instance's own `FuncDeclaration`, so no extra template logic is
    // needed here.
    override void visit(TemplateDeclaration declaration) {}

    override void visit(TemplateInstance instance) {
        if (instance.members !is null)
            foreach (member; *instance.members)
                member.accept(this);
    }

    // `mixin WithAsm;` instantiates a `mixin template` as a
    // `TemplateMixin`. `TemplateMixin : TemplateInstance`, but it overrides
    // `accept` with its own `v.visit(this)`, so it dispatches to this
    // overload rather than `visit(TemplateInstance)` above;
    // `SemanticTimeTransitiveVisitor`'s own default `visit(TemplateMixin)`
    // walks only the mixin's type and template arguments, never its
    // instantiated members, so without this override a root-owned function
    // inside a root-owned mixin template's own body was never walked.
    override void visit(TemplateMixin instance) {
        if (instance.members !is null)
            foreach (member; *instance.members)
                member.accept(this);
    }

    // `.decl` is the syntactic "then" branch even when the condition
    // resolved otherwise; `include` gives the branch a real build compiles
    // in, mirroring `Collector` in `dependencyimage.d`. This override
    // reaches most `AttribDeclaration` subtypes (`LinkDeclaration`,
    // `VisibilityDeclaration`, ...): each one's own `accept` dispatches by
    // its exact static type, and `SemanticTimeTransitiveVisitor` (whose
    // traversal this class otherwise reuses) has no more specific `visit`
    // overload for those, so dmd's own per-type forwarding stubs
    // (`dmd.visitor.parsetime`) fall through to this one. Two subtypes do
    // have their own more specific overload there and so never reach this
    // one at all - each needs its own override below for the same
    // `include`-based reason.
    override void visit(AttribDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
                member.accept(this);
    }

    // `version (D_InlineAsm_X86_64) { ... } else { ... }` is a
    // `ConditionalDeclaration`; `SemanticTimeTransitiveVisitor`'s own
    // traversal (`dmd.visitor.transitive`'s `ParseVisitMethods`) walks
    // both `.decl` and `.elsedecl` unconditionally for this exact type,
    // shadowing the generic `AttribDeclaration` override above, so an
    // `asm` block in the branch that did not compile in would be reported
    // as if it had. Route through `include` instead, the same as above,
    // so only the branch a real build actually compiles in is walked.
    override void visit(ConditionalDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
                member.accept(this);
    }

    // `mixin("...")` at declaration scope is a `MixinDeclaration`;
    // `SemanticTimeTransitiveVisitor`'s own traversal walks only its
    // string argument expression for this exact type (parse-time shape,
    // before expansion), shadowing the generic `AttribDeclaration`
    // override above, so a mixin's own expanded declarations - including
    // any `asm` block they compile in - are never reached at all
    // (docs/adr/0012's known mixin gap: the version gate cannot see
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
            _lines ~= diagnosticLine(function_);
        if (function_.fbody !is null)
            function_.fbody.accept(this);
    }

    override void visit(FuncExp expression) {
        expression.fd.accept(this);
    }

    // dmd's semantic pass never forwards these function kinds to the plain
    // `FuncDeclaration` overload by default; `dependencyimage.d`'s
    // `Collector` guards the same list for the same reason (see "Guard all
    // function kinds during dependency image collection").
    override void visit(FuncLiteralDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(PostBlitDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(CtorDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(DtorDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(InvariantDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(UnitTestDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(NewDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(StaticCtorDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(StaticDtorDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(SharedStaticCtorDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }

    override void visit(SharedStaticDtorDeclaration function_) {
        visit(cast(FuncDeclaration) function_);
    }
}

// Named distinctly from `InlineAsmCollector` above and `dependencyimage.d`'s
// `Collector` for the same reason as that one: an `extern(C++) class` with
// no explicit C++ namespace mangles by name alone, so a duplicate name
// would silently collide at link time instead of erroring.
//
// Reuses `SemanticTimeTransitiveVisitor`'s default traversal rather than
// the parse-time-only `ParseTimeTransitiveVisitor` template: every AST
// node's own `accept` takes the one concrete `Visitor` class dmd's AST
// headers are built against, and only `SemanticTimeTransitiveVisitor`
// (also `Visitor`'s descendant) is usable with it. The two share the same
// per-node traversal mixin (`dmd.visitor.transitive`'s
// `ParseVisitMethods`), so nothing here depends on semantic results:
// `ConditionalDeclaration`/`ConditionalStatement` walk their condition and
// both branches unconditionally (not just the branch `include` would
// pick), `TemplateDeclaration` walks its syntactic `members` directly
// (not through `TemplateInstance`, which has none yet at this point), and
// `StaticIfCondition` (`static if`, not a version) never reaches
// `visit(VersionCondition)` below.
private extern(C++) class InlineAsmVersionGate
        : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    import dmd.cond: Include, VersionCondition;
    import dmd.identifier: Identifier;

    // A version LEVEL condition, `version (2) { ... }`, has a `null`
    // `VersionCondition.ident` (dmd's `DVCondition` doc comment: "If
    // `null`, this condition will use an integer level"). `is` identity
    // comparison does not dereference either side, so a `null` `ident`
    // simply compares unequal to the pooled identifier below; it can never
    // be `D_InlineAsm_X86_64`, which is never anonymous.
    override void visit(VersionCondition condition) {
        if (condition.ident is Identifier.idPool("D_InlineAsm_X86_64"))
            condition.inc = Include.no;
    }
}

// One line, in dmd's own `file(line):` shape, naming the function and the
// remedy: guard the block with the version identifier snakebite parses
// root modules without (see `disableInlineAsmVersion` above).
private extern(D) string diagnosticLine(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;
    import std.string: fromStringz;

    return text(
        function_.loc.filename.fromStringz,
        "(", function_.loc.linnum, "): ",
        "inline assembler is not supported in `",
        function_.toPrettyChars.fromStringz,
        "`: guard it with `version (D_InlineAsm_X86_64)`, which snakebite ",
        "does not define",
    );
}
