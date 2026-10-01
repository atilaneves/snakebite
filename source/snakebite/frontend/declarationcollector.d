module snakebite.frontend.declarationcollector;


private:


// dmd's own `SemanticTimeTransitiveVisitor.visit(CInitializer)` takes the
// designator list of every entry in a C initialiser list to be present,
// but the C parser leaves it null for an entry that has no designator
// (`{x, 3}`), so a walk over an ImportC module that has not been through
// semantic analysis yet dereferences null. Its
// `visit(CompoundDeclarationStatement)` asserts that each declaration is a
// `Declaration`, but the C parser wraps the variables of `int a, b;` in a
// `LinkDeclaration`, which is not one. The base of every walk that can
// start before semantic analysis, `inlineasm.d`'s version gate among them.
package extern(C++) class ImportCSafeVisitor
        : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.init: CInitializer;
    import dmd.statement: CompoundDeclarationStatement;
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    override void visit(CompoundDeclarationStatement statement) {
        foreach (child; *statement.statements) {
            if (child is null)
                continue;
            auto expression = child.isExpStatement;
            auto declaration = expression is null
                ? null : expression.exp.isDeclarationExp;
            if (declaration is null)
                continue;
            if (auto variable = declaration.declaration.isVarDeclaration)
                visitVarDecl(variable);
            else
                declaration.declaration.accept(this);
        }
    }

    override void visit(CInitializer initializer) {
        foreach (entry; initializer.initializerList) {
            if (entry.designatorList !is null)
                foreach (designator; (*entry.designatorList)[])
                    if (designator.exp !is null)
                        designator.exp.accept(this);
            entry.initializer.accept(this);
        }
    }
}

// Named distinctly from every class that extends it (`Collector` in
// `imagesource.d`, `InlineAsmCollector` and `InlineAsmVersionGate` in
// `inlineasm.d`): an `extern(C++) class` with no explicit C++ namespace
// mangles by name alone, so a duplicate name would silently collide at
// link time instead of erroring.
//
// Shared traversal skeleton for the two collectors that walk the
// declarations a real build compiles in, after semantic analysis:
// `imagesource.d`'s `Collector` and `inlineasm.d`'s
// `InlineAsmCollector`. Both need the same answer to "does this
// declaration compile into the build", so that answer lives here once.
// Each subclass overrides only `visit(FuncDeclaration)`, where the two
// collectors' jobs differ.
package extern(C++) class DeclarationCollector : ImportCSafeVisitor {
    alias visit = ImportCSafeVisitor.visit;

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

    // `SemanticTimeTransitiveVisitor` gives most `AttribDeclaration`
    // subtypes their own `visit` overload (dmd 2.113.0
    // `dmd/visitor/transitive.d:526-602`); those walk `.decl` directly
    // and never reach this override. Three subtypes have no such
    // overload: `StaticForeachDeclaration`, `CPPNamespaceDeclaration`,
    // and `ForwardingAttribDeclaration`. `ParseTimeVisitor`'s default
    // forwarder (`dmd/visitor/parsetime.d`) routes each of them here
    // instead. `StaticForeachDeclaration` is the one that matters:
    // `include` picks the branch a real build expands, so only that
    // branch is walked.
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
