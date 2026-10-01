module snakebite.frontend.betterc;


private:


// What dmd's glue layer reports for `-betterC` while it generates code, and
// the frontend does not: concatenation, appending and `TypeInfo` can still be
// part of compile-time code, so dmd decides at code generation, for the
// declarations it generates code for and only for them. This is the same
// walk as `FuncDeclaration_toObjFile`, `ToObjFile` and `Statement_toIR` in
// `dmd/glue`, with the same stops and the same order, and it reports the
// same errors with the same text, one for each node. A backend then never
// reaches a node that dmd leaves without a `lowering` under `-betterC`.
public void reportBetterCDiagnostics(
    imported!"dmd.dmodule".Module[] rootModules,
) {
    scope declarations = new BetterCGlueDeclarations;
    foreach (module_; rootModules) {
        // `genObjFile` takes the length again at each step: generating code
        // can append a template instance to the members.
        for (size_t index = 0; index < module_.members.length; index++)
            (*module_.members)[index].accept(declarations);
    }
}


// Named distinctly from the other visitors: an `extern(C++) class` with no
// explicit C++ namespace mangles by name alone, so a duplicate name would
// silently collide at link time instead of erroring.
//
// `ToObjFile` of `dmd/glue/toobj.d`: which declarations get code.
private extern(C++) class BetterCGlueDeclarations
        : imported!"dmd.visitor".SemanticTimePermissiveVisitor {
    import dmd.visitor: SemanticTimePermissiveVisitor;
    alias visit = SemanticTimePermissiveVisitor.visit;

    import dmd.aggregate: AggregateDeclaration;
    import dmd.astenums: STC, Terror;
    import dmd.attrib: AttribDeclaration;
    import dmd.dclass: ClassDeclaration, InterfaceDeclaration;
    import dmd.declaration: TupleDeclaration, TypeInfoDeclaration, VarDeclaration;
    import dmd.dsymbol: Dsymbol, PASS;
    import dmd.nspace: Nspace;
    import dmd.dsymbolsem: include, toAlias;
    import dmd.dstruct: StructDeclaration;
    import dmd.dtemplate: TemplateInstance, TemplateMixin;
    import dmd.errors: error;
    import dmd.expression: Expression;
    import dmd.func:
        FuncDeclaration,
        FuncLiteralDeclaration,
        UnitTestDeclaration;
    import dmd.globals: global;

    // `semanticRun >= PASS.obj` of dmd: the function was generated, or its
    // generation has begun.
    private bool[FuncDeclaration] _generated;
    // `FuncLiteralDeclaration.deferToObj`.
    private bool[FuncLiteralDeclaration] _literals;
    // `UnitTestDeclaration.deferredNested`.
    private FuncDeclaration[][UnitTestDeclaration] _deferredNested;
    // dmd ends the process after a `TypeInfo` error.
    private bool _fatal;

    override void visit(FuncDeclaration function_) {
        if (_fatal || function_ in _generated)
            return;
        if (function_.type !is null)
            if (auto type = function_.type.isTypeFunction)
                if (type.next is null || type.next.ty == Terror)
                    return;
        // A function that has no complete semantic analysis is not safe to
        // walk. dmd gives an error for it, after another error, which has
        // stopped the load already.
        if (function_.hasSemantic3Errors
                || global.errors != 0
                || function_.fbody is null
                || function_.skipCodegen
                || function_.semanticRun < PASS.semantic3done)
            return;
        if (function_.isUnitTestDeclaration !is null
                && !global.params.useUnitTests)
            return;

        for (auto outer = function_; outer !is null; ) {
            if (outer.inNonRoot)
                return;
            if (!outer.isNested)
                break;
            outer = outer.toParent2.isFuncDeclaration;
        }

        if (auto unitTest = enclosingUnitTest(function_)) {
            _deferredNested[unitTest] ~= function_;
            return;
        }

        _generated[function_] = true;
        // A nested function needs the frame of its enclosing function first.
        if (function_.isNested)
            if (auto parent = function_.toParent2.isFuncDeclaration)
                if (parent !in _generated)
                    visit(parent);

        generateBody(function_);
    }

    private extern(D) void generateBody(FuncDeclaration function_) {
        import dmd.funcsem: needsClosure;
        import dmd.semantic3: checkClosure;

        scope body_ = new BetterCGlueBody(this);

        // A template instance can make a function need a closure after its
        // semantic analysis.
        const oldValue = function_.requiresClosure;
        if (function_.needsClosure
                && oldValue != function_.requiresClosure
                && (function_.nrvo_var !is null || !global.params.useGC))
            function_.checkClosure;

        function_.fbody.accept(body_);
        if (global.errors != 0 || _fatal)
            return;

        foreach (declaration; body_.deferred)
            declaration.accept(this);
        if (auto unitTest = function_.isUnitTestDeclaration)
            if (auto nested = unitTest in _deferredNested)
                foreach (deferredFunction; *nested)
                    deferredFunction.accept(this);
    }

    private extern(D) UnitTestDeclaration enclosingUnitTest(
        FuncDeclaration function_,
    ) {
        for (auto outer = function_; outer !is null && outer.isNested; ) {
            auto parent = outer.toParent2.isFuncDeclaration;
            if (parent is null)
                break;
            if (auto unitTest = parent.isUnitTestDeclaration)
                return unitTest in _generated ? null : unitTest;
            outer = parent;
        }
        return null;
    }

    override void visit(StructDeclaration declaration) {
        if (declaration.isAnonymous || declaration.members is null)
            return;

        writeInitializers(declaration);
        foreach (member; *declaration.members)
            member.accept(this);
        if (declaration.xeq !is null
                && declaration.xeq !is StructDeclaration.xerreq)
            declaration.xeq.accept(this);
        if (declaration.xcmp !is null
                && declaration.xcmp !is StructDeclaration.xerrcmp)
            declaration.xcmp.accept(this);
        if (declaration.xhash !is null)
            declaration.xhash.accept(this);
    }

    override void visit(ClassDeclaration declaration) {
        if (declaration.members is null)
            return;

        foreach (member; *declaration.members)
            member.accept(this);
        writeInitializers(declaration);
    }

    override void visit(InterfaceDeclaration declaration) {
        if (declaration.members is null)
            return;

        foreach (member; *declaration.members)
            member.accept(this);
    }

    // The default initializer of an aggregate is written to the object
    // file as data.
    private extern(D) void writeInitializers(AggregateDeclaration declaration) {
        foreach (field; declaration.fields)
            writeData(field);
    }

    override void visit(VarDeclaration variable) {
        if (variable.aliasTuple !is null) {
            variable.toAlias.accept(this);
            return;
        }
        if (!variable.canTakeAddressOf)
            return;
        if (!variable.isDataseg || variable.storage_class & STC.extern_)
            return;
        writeData(variable);
    }

    // The `TypeInfo` of a type is data that this compilation writes only
    // with the `TypeInfo` switch on.
    override void visit(TypeInfoDeclaration) {}

    private extern(D) void writeData(imported!"dmd.declaration".VarDeclaration variable) {
        import dmd.typesem: size;

        if (variable._init is null || variable.type.size(variable.loc) == 0)
            return;
        auto initializer = variable._init.isExpInitializer;
        if (initializer is null)
            return;
        scope data = new BetterCGlueBody(this, true);
        initializer.exp.accept(data);
    }

    override void visit(AttribDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
                member.accept(this);
    }

    override void visit(TemplateInstance instance) {
        import dmd.templatesem: needsCodegen;

        if (instance.errors || instance.members is null)
            return;
        if (!instance.needsCodegen)
            return;
        foreach (member; *instance.members)
            member.accept(this);
    }

    override void visit(TemplateMixin mixin_) {
        if (mixin_.errors || mixin_.members is null)
            return;
        foreach (member; *mixin_.members)
            member.accept(this);
    }

    override void visit(Nspace namespace) {
        if (namespace.errors || namespace.members is null)
            return;
        foreach (member; *namespace.members)
            member.accept(this);
    }

    override void visit(TupleDeclaration tuple) {
        tuple.foreachVar((member) { member.accept(this); });
    }

    // A lambda reaches the object file once, from the first function that
    // names it.
    package extern(D) bool firstUse(FuncLiteralDeclaration literal) {
        if (literal in _literals)
            return false;
        _literals[literal] = true;
        return true;
    }

    // `genTypeInfo` of `dmd/typinf.d`, which the glue calls with no scope.
    package extern(D) void reportTypeInfo(Expression expression) {
        if (_fatal || global.params.useTypeInfo)
            return;
        error(
            expression.loc,
            "expression `%s` uses the GC and cannot be used with switch "
            ~ "`-betterC`",
            expression.toChars,
        );
        _fatal = true;
    }

    package extern(D) bool fatal() const {
        return _fatal;
    }
}


// `Statement_toIR` and `toElem` of `dmd/glue`: which parts of a function
// body get code, for one function or one static initializer.
private extern(C++) class BetterCGlueBody
        : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    import dmd.astenums: STC, Tchar, Tclass;
    import dmd.dsymbol: Dsymbol;
    import dmd.dsymbolsem: include, toAlias;
    import dmd.dtemplate: TemplateInstance, TemplateMixin, isExpression, isType;
    import dmd.dmodule: Module;
    import dmd.mtype: Type;
    import dmd.rootobject: RootObject;
    import dmd.staticassert: StaticAssert;
    import dmd.errors: error;
    import dmd.expression:
        CastExp,
        CatAssignExp,
        CatDcharAssignExp,
        CatElemAssignExp,
        CatExp,
        CondExp,
        DeclarationExp,
        DelegateExp,
        DotTemplateInstanceExp,
        DotVarExp,
        FuncExp,
        NewExp,
        SymOffExp,
        TypeidExp,
        Expression,
        VarExp;
    import dmd.func: FuncDeclaration, FuncLiteralDeclaration;
    import dmd.globals: global;
    import dmd.location: Loc;
    import dmd.typesem: nextOf, toBasetype;
    import dmd.statement:
        IfStatement,
        ImportStatement,
        MixinStatement,
        PragmaStatement,
        ScopeGuardStatement,
        StaticAssertStatement;

    private BetterCGlueDeclarations _declarations;
    // A static initializer is written to the object file at once, a
    // function literal in a function body after the function.
    private bool _data;
    package Dsymbol[] deferred;

    package extern(D) this(
        BetterCGlueDeclarations declarations,
        bool data = false,
    ) {
        _declarations = declarations;
        _data = data;
    }

    // Nothing is generated for the body of `if (__ctfe)`: `__ctfe` is false
    // at run time. The frontend turned `if (!__ctfe) A else B` around.
    override void visit(IfStatement statement) {
        statement.condition.accept(this);
        if (statement.ifbody !is null && !statement.isIfCtfeBlock)
            statement.ifbody.accept(this);
        if (statement.elsebody !is null)
            statement.elsebody.accept(this);
    }

    // What names a type, a module, a template instance, a symbol or a trait is
    // resolved already, and a template instance gets its code from its own
    // members. Following those names would walk code that this function
    // does not contain.
    override void visitType(Type) {}

    override void visitObject(RootObject) {}

    override void visit(Module) {}

    override void visit(TemplateInstance) {}

    override void visit(TemplateMixin) {}

    override void visit(StaticAssert) {}

    override void visit(StaticAssertStatement) {}

    // The compiler evaluates the argument of `mixin`.
    override void visit(MixinStatement) {}

    override void visit(DotTemplateInstanceExp expression) {
        expression.e1.accept(this);
    }

    override void visit(NewExp expression) {
        if (expression.placement !is null)
            expression.placement.accept(this);
        if (expression.thisexp !is null)
            expression.thisexp.accept(this);
        if (expression.arguments !is null)
            foreach (argument; *expression.arguments)
                argument.accept(this);
        if (!global.params.useGC && !expression.onstack
                && expression.placement is null
                && expression.newtype.toBasetype.ty == Tclass)
            reportRuntimeFunction(expression, "_d_newclass".ptr, expression.loc);
    }

    override void visit(CastExp expression) {
        expression.e1.accept(this);
    }

    override void visit(ScopeGuardStatement) {}

    override void visit(PragmaStatement) {}

    override void visit(ImportStatement) {}

    override void visit(CondExp expression) {
        import snakebite.frontend.dmd.functions: ctfeBranchOf;

        if (auto taken = expression.ctfeBranchOf) {
            taken.accept(this);
            return;
        }

        expression.econd.accept(this);
        expression.e1.accept(this);
        expression.e2.accept(this);
    }

    // dmd returns at the concatenation: it does not generate its operands.
    override void visit(CatExp expression) {
        if (_declarations.fatal || global.params.useGC)
            return;
        error(
            expression.loc,
            "array concatenation of expression `%s` requires the GC which "
            ~ "is not available with -betterC",
            expression.toChars,
        );
    }

    override void visit(CatAssignExp expression) {
        if (_declarations.fatal || global.params.useGC)
            return;
        error(
            expression.loc,
            "appending to array in `%s` requires the GC which is not "
            ~ "available with -betterC",
            expression.toChars,
        );
    }

    override void visit(CatElemAssignExp expression) {
        visit(cast(CatAssignExp) expression);
    }

    // Appending a `dchar` to a `char[]` is a call of a runtime function
    // that dmd's glue names, and its own error is the linker's.
    override void visit(CatDcharAssignExp expression) {
        expression.e1.accept(this);
        expression.e2.accept(this);
        if (!global.params.useGC)
            reportRuntimeFunction(
                expression,
                expression.e1.type.toBasetype.nextOf.toBasetype.ty == Tchar
                    ? "_d_arrayappendcd".ptr : "_d_arrayappendwd".ptr,
                expression.loc,
            );
    }

    override void visit(TypeidExp expression) {
        if (isType(expression.obj) !is null) {
            _declarations.reportTypeInfo(expression);
            return;
        }
        auto operand = isExpression(expression.obj);
        if (auto variable = operand.isVarExp)
            if (auto member = variable.var.isEnumMember)
                operand = member.value;
        if (operand.isClassReferenceExp !is null) {
            _declarations.reportTypeInfo(operand);
            return;
        }
        operand.accept(this);
    }

    override void visit(FuncExp expression) {
        reference(expression.fd, expression);
        useLiteral(expression.fd);
    }

    override void visit(VarExp expression) {
        if (auto function_ = expression.var.isFuncDeclaration)
            reference(function_, expression);
        if (auto literal = expression.var.isFuncLiteralDeclaration)
            useLiteral(literal);
    }

    override void visit(SymOffExp expression) {
        if (auto function_ = expression.var.isFuncDeclaration)
            reference(function_, expression);
        if (auto literal = expression.var.isFuncLiteralDeclaration)
            useLiteral(literal);
    }

    override void visit(DotVarExp expression) {
        expression.e1.accept(this);
        if (auto function_ = expression.var.isFuncDeclaration)
            reference(function_, expression);
    }

    override void visit(DelegateExp expression) {
        expression.e1.accept(this);
        reference(expression.func, expression);
    }

    // The linker reports a reference to a function that has no code: dmd
    // generates none for a function that uses the GC under `-betterC`
    // (`skipCodegen`), and a `-betterC` program has no druntime to supply
    // the runtime functions that compiled code calls.
    private extern(D) void reference(
        FuncDeclaration function_, Expression expression,
    ) {
        if (global.params.useGC || _declarations.fatal)
            return;
        if (function_.fbody !is null) {
            if (function_.skipCodegen && !function_.inNonRoot)
                error(
                    expression.loc,
                    "`%s` uses the GC, so dmd generates no code for `%s` "
                    ~ "with -betterC and the reference to it cannot link",
                    expression.toChars,
                    function_.toPrettyChars,
                );
            return;
        }
        if (isRuntimeFunction(function_))
            reportRuntimeFunction(
                expression, function_.toPrettyChars, expression.loc,
            );
    }

    // A function of the D runtime that has no code here. The compiler
    // declares some with no module (`_d_criticalenter2`, `_aApplycd1`).
    // druntime's own C entry points have the names `gc_*`, `_d_*` and
    // `rt_*`, which the C library does not use, and its D functions have no
    // body outside its own modules.
    private extern(D) static bool isRuntimeFunction(
        FuncDeclaration function_,
    ) {
        import dmd.astenums: LINK;
        import std.algorithm.searching: any, startsWith;
        import std.string: fromStringz;

        auto module_ = function_.getModule;
        if (module_ is null)
            return true;

        const name = module_.toPrettyChars.fromStringz;
        const isRuntimeModule = name == "object" || name == "core.memory"
            || name.startsWith("core.internal.") || name.startsWith("rt.")
            || name.startsWith("gc.");
        if (function_.resolvedLinkage == LINK.d)
            return isRuntimeModule;

        // The linker name of a C function: `pragma(mangle)` or the name.
        const symbol = function_.mangleOverride.length != 0
            ? function_.mangleOverride : function_.ident.toString;
        return ["gc_", "_d_", "rt_", "_aApply", "_aaApply"]
            .any!(prefix => symbol.startsWith(prefix));
    }

    private extern(D) void reportRuntimeFunction(
        Expression expression, in char* name, in Loc loc,
    ) {
        error(
            loc,
            "`%s` needs the D runtime function `%s`, which is not "
            ~ "available with -betterC",
            expression.toChars,
            name,
        );
    }

    private extern(D) void useLiteral(FuncLiteralDeclaration literal) {
        if (_data) {
            literal.accept(_declarations);
            return;
        }
        if (_declarations.firstUse(literal))
            deferred ~= literal;
    }

    override void visit(DeclarationExp expression) {
        declare(expression.declaration);
    }

    // `Dsymbol_toElem` of `dmd/glue/e2ir.d`.
    private extern(D) void declare(Dsymbol symbol) {
        if (auto variable = symbol.isVarDeclaration) {
            auto target = symbol.toAlias;
            if (target !is variable) {
                declare(target);
                return;
            }
            if (variable.storage_class & STC.manifest)
                return;
            if (variable.isStatic
                    || variable.storage_class
                        & (STC.extern_ | STC.tls | STC.gshared))
                variable.accept(_declarations);
            else {
                if (variable._init !is null)
                    if (auto initializer = variable._init.isExpInitializer)
                        initializer.exp.accept(this);
                if (variable.needsScopeDtor)
                    variable.edtor.accept(this);
            }
        } else if (symbol.isClassDeclaration !is null
                || symbol.isStructDeclaration !is null
                || symbol.isFuncDeclaration !is null)
            deferred ~= symbol;
        else if (auto attributes = symbol.isAttribDeclaration) {
            if (auto members = include(attributes, null))
                foreach (member; *members)
                    declare(member);
        } else if (auto mixin_ = symbol.isTemplateMixin) {
            foreach (member; *mixin_.members)
                declare(member);
        } else if (auto tuple = symbol.isTupleDeclaration)
            tuple.foreachVar((member) { declare(member); });
        else if (symbol.isEnumDeclaration !is null
                || symbol.isTemplateInstance !is null)
            deferred ~= symbol;
    }
}
