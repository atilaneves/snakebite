module snakebite.frontend.declarationcollector;


private:


// Named distinctly from every class that extends it (`Collector` in
// `dependencyimage.d`, `InlineAsmCollector` and `InlineAsmVersionGate` in
// `inlineasm.d`): an `extern(C++) class` with no explicit C++ namespace
// mangles by name alone, so a duplicate name would silently collide at
// link time instead of erroring.
//
// Shared traversal skeleton for the two collectors that walk the
// declarations a real build compiles in, after semantic analysis:
// `dependencyimage.d`'s `Collector` and `inlineasm.d`'s
// `InlineAsmCollector`. Both need the same answer to "does this
// declaration compile into the build", so that answer lives here once.
// Each subclass overrides only `visit(FuncDeclaration)`, where the two
// collectors' jobs differ.
package extern(C++) class DeclarationCollector
        : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    import dmd.attrib: AttribDeclaration, ConditionalDeclaration;
    import dmd.dsymbolsem: include;
    import dmd.dtemplate: TemplateDeclaration, TemplateInstance;
    import dmd.expression: FuncExp;
    import dmd.func: CtorDeclaration, DtorDeclaration,
        FuncDeclaration, FuncLiteralDeclaration, InvariantDeclaration,
        NewDeclaration, PostBlitDeclaration, SharedStaticCtorDeclaration,
        SharedStaticDtorDeclaration, StaticCtorDeclaration,
        StaticDtorDeclaration, UnitTestDeclaration;

    // An uninstantiated template contributes no code to the build, so its
    // body is never walked; a used template's own instance is reached
    // through `TemplateInstance` below.
    override void visit(TemplateDeclaration declaration) {}

    override void visit(TemplateInstance instance) {
        if (instance.members !is null)
            foreach (member; *instance.members)
                member.accept(this);
    }

    // `.decl` is the syntactic "then" branch even when the condition
    // resolved otherwise; `include` gives the branch a real build compiles
    // in. This override reaches most `AttribDeclaration` subtypes
    // (`LinkDeclaration`, `VisibilityDeclaration`, ...): each one's own
    // `accept` dispatches by its exact static type, and
    // `SemanticTimeTransitiveVisitor` (whose traversal this class
    // otherwise reuses) has no more specific `visit` overload for those,
    // so dmd's own per-type forwarding stubs (`dmd.visitor.parsetime`)
    // fall through to this one. `ConditionalDeclaration` does have its
    // own more specific overload there, so it never reaches this one at
    // all and needs the override just below for the same `include`-based
    // reason.
    override void visit(AttribDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
                member.accept(this);
    }

    // `version (...) { ... } else { ... }` is a `ConditionalDeclaration`;
    // `SemanticTimeTransitiveVisitor`'s own traversal
    // (`dmd.visitor.transitive`'s `ParseVisitMethods`) walks both `.decl`
    // and `.elsedecl` unconditionally for this exact type, shadowing the
    // generic `AttribDeclaration` override above, so a declaration in the
    // branch that did not compile in would be walked as if it had. Route
    // through the same `include`-based override instead, so only the
    // branch a real build actually compiles in is walked.
    override void visit(ConditionalDeclaration declaration) {
        visit(cast(AttribDeclaration) declaration);
    }

    // `ParseTimeVisitor` forwards these function kinds to the plain
    // `FuncDeclaration` overload by default (`dmd/visitor/parsetime.d:57-
    // 67`), but `SemanticTimeTransitiveVisitor` (whose traversal this
    // class otherwise reuses) overrides each kind with its own body walk
    // (`dmd/visitor/transitive.d:854-921`) that never calls
    // `visit(FuncDeclaration)`. Forward each kind to the subclass's own
    // `FuncDeclaration` override by hand, so every function kind reaches
    // it exactly once regardless of which subclass is walking.
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

    // A function literal's own `FuncExp` wrapper is what the surrounding
    // expression tree holds; walk into the declaration it wraps so a
    // lambda's body is reached the same way any other function body is.
    override void visit(FuncExp expression) {
        expression.fd.accept(this);
    }
}
