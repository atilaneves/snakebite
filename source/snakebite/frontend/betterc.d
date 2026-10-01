module snakebite.frontend.betterc;


private:


// What dmd's glue layer (`glue/e2ir.d`) reports for `-betterC` while it
// generates code, and the frontend does not: concatenation and appending
// need the GC, but a `CatExp` or `CatAssignExp` can still be part of
// compile-time code, so dmd decides at code generation. dmd generates code
// for a root module's functions, except those that `skipCodegen` marks (a
// template instance that uses the GC, for one). Report the same errors for
// the same functions after semantic analysis, so that a backend never
// reaches the node: dmd leaves it without a `lowering` under `-betterC`.
public void reportBetterCDiagnostics(
    imported!"dmd.dmodule".Module[] rootModules,
) {
    scope collector = new BetterCCollector(rootModules);
    foreach (module_; rootModules)
        module_.accept(collector);
}


// Named distinctly from the other collectors: see `DeclarationCollector`.
private extern(C++) class BetterCCollector
        : imported!"snakebite.frontend.declarationcollector".DeclarationCollector {
    import snakebite.frontend.declarationcollector: DeclarationCollector;
    alias visit = DeclarationCollector.visit;

    import dmd.dmodule: Module;
    import dmd.errors: error;
    import dmd.expression: CatAssignExp, CatElemAssignExp, CatExp;
    import dmd.dtemplate: TemplateInstance;
    import dmd.func: FuncDeclaration;
    import dmd.staticassert: StaticAssert;

    private bool[Module] _rootModules;
    private bool[FuncDeclaration] _visited;
    private bool _generated;

    private extern(D) this(Module[] rootModules) {
        foreach (module_; rootModules)
            _rootModules[module_] = true;
    }

    override void visit(FuncDeclaration function_) {
        import snakebite.frontend.dmd.functions: isRootOwned;

        if (function_ in _visited)
            return;
        _visited[function_] = true;
        if (function_.fbody is null)
            return;

        const outer = _generated;
        scope(exit) _generated = outer;
        _generated = isRootOwned(function_, _rootModules)
            && !function_.skipCodegen;
        function_.fbody.accept(this);
    }

    // A function body names a template instance without containing its
    // code: that instance is generated, or not, by its own functions.
    override void visit(TemplateInstance instance) {
        const outer = _generated;
        scope(exit) _generated = outer;
        _generated = false;
        super.visit(instance);
    }

    // Evaluated by the compiler, never generated.
    override void visit(StaticAssert) {}

    override void visit(CatExp expression) {
        if (_generated)
            error(
                expression.loc,
                "array concatenation of expression `%s` requires the GC "
                ~ "which is not available with -betterC",
                expression.toChars,
            );
        super.visit(expression);
    }

    override void visit(CatAssignExp expression) {
        reportAppend(expression);
        super.visit(expression);
    }

    override void visit(CatElemAssignExp expression) {
        reportAppend(expression);
        super.visit(expression);
    }

    private extern(D) void reportAppend(CatAssignExp expression) {
        if (_generated)
            error(
                expression.loc,
                "appending to array in `%s` requires the GC which is not "
                ~ "available with -betterC",
                expression.toChars,
            );
    }
}
