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
package(snakebite) extern(C++) class ImportCSafeVisitor
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

// The native compiler generates code for a template instance only when
// `needsCodegen` says so. It says no for an instance with errors, for one
// that only a speculative check, such as `is(typeof(...))`, made, and for
// one that a non-root module makes when it imports no root module. dmd
// asserts that `needsCodegen` gets the primary instance, so any other
// instance is not one that compiles.
package(snakebite) bool compilesIntoBuild(
    imported!"dmd.dtemplate".TemplateInstance instance,
) {
    import dmd.templatesem: needsCodegen;

    return instance.inst is instance && instance.needsCodegen;
}

// Whether the code generator of dmd emits the storage of `variable` in the
// object of the module that declares it (`dmd.glue.toobj`, the visit of a
// `VarDeclaration`): a static variable that is not `extern`, not a tuple and
// not a variable whose address cannot be taken.
package(snakebite) bool hasStorageInObject(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: STC;

    return variable.aliasTuple is null && variable.canTakeAddressOf
        && variable.isDataseg && !(variable.storage_class & STC.extern_);
}

// Whether the code generator of dmd emits the type information of the struct
// `declaration` in the object of the module that declares it
// (`dmd.glue.toobj`, the visit of a `StructDeclaration`): a struct that is
// not anonymous and not only declared, in a compile with type information.
package(snakebite) bool hasTypeInfoInObject(
    imported!"dmd.dstruct".StructDeclaration declaration,
) {
    return !declaration.isAnonymous && declaration.members !is null
        && compilesTypeInfo;
}

// Whether the code generator of dmd emits the type information of the enum
// `declaration` in the object of the module that declares it
// (`dmd.glue.toobj`, the visit of an `EnumDeclaration`): an enum that is not
// anonymous, in a compile with type information. An enum that is only
// declared (`enum E;`) has type information too.
package(snakebite) bool hasTypeInfoInObject(
    imported!"dmd.denum".EnumDeclaration declaration,
) {
    return !declaration.isAnonymous && compilesTypeInfo;
}

// Whether the compile makes type information (`-betterC` does not), as the
// code generator of dmd decides it.
private bool compilesTypeInfo() nothrow @nogc {
    import dmd.globals: global;
    import dmd.mtype: Type;

    return global.params.useTypeInfo && Type.dtypeinfo !is null;
}

// Whether the code generator of dmd emits the class information of the
// class or interface `declaration`, with its vtable and its initial image,
// in the object of the module that declares it (`dmd.glue.toobj`, the visits
// of a `ClassDeclaration` and an `InterfaceDeclaration`): a class that is
// not only declared.
package(snakebite) bool hasClassInfoInObject(
    imported!"dmd.dclass".ClassDeclaration declaration,
) @safe pure nothrow @nogc {
    return declaration.members !is null;
}

// Named distinctly from every class that extends it (`Collector` in
// `imagesource.d`, `InlineAsmCollector` and `InlineAsmVersionGate` in
// `inlineasm.d`): an `extern(C++) class` with no explicit C++ namespace
// mangles by name alone, so a duplicate name would silently collide at
// link time instead of erroring.
//
// The walk over the declarations that a real build compiles in, after
// semantic analysis. Each walk that needs the answer to "does this
// declaration compile into the build" extends it: the `Collector` of
// `imagesource.d`, the `InlineAsmCollector` of `inlineasm.d` and the walk
// of a compile to an SBC file in the bytecode compiler. So that answer has
// one place.
package(snakebite) extern(C++) class DeclarationCollector : ImportCSafeVisitor {
    alias visit = ImportCSafeVisitor.visit;

    import dmd.attrib: AttribDeclaration, ConditionalDeclaration,
        MixinDeclaration;
    import dmd.dsymbolsem: include;
    import dmd.dtemplate: TemplateDeclaration, TemplateInstance,
        TemplateMixin;
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
        if (instance.members !is null && instance.compilesIntoBuild)
            foreach (member; *instance.members)
                member.accept(this);
    }

    // The members of a template mixin compile into the object of the module
    // that mixes it in, as any other member of that scope does: the code
    // generator of dmd walks into a `TemplateMixin` with no test of
    // `needsCodegen` (`dmd.glue.toobj`, `visit(TemplateMixin)`). Its
    // `accept` calls this overload, not `visit(TemplateInstance)`, and the
    // overload of `SemanticTimeTransitiveVisitor` walks only the type and
    // the template arguments of the mixin.
    override void visit(TemplateMixin instance) {
        if (instance.members !is null)
            foreach (member; *instance.members)
                member.accept(this);
    }

    // The declarations of `mixin("...")` at declaration scope compile in as
    // any other declaration of that scope. `include` gives the declarations
    // that the string expanded into. The overload of
    // `SemanticTimeTransitiveVisitor` walks only the string expression.
    override void visit(MixinDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
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
