module snakebite.frontend.dependencyimage;


private:


public string imageSource(imported!"snakebite.backends.backend".Program program) {
    scope collector = new Collector(program);
    foreach (module_; program.rootModules)
        module_.accept(collector);
    return collector.source;
}


// Cache inputs include imported source files: changing a dependency must
// invalidate its compiled template bodies even when their names stay the same.
public string[] imageInputs(imported!"snakebite.backends.backend".Program program) {
    import dmd.dmodule: Module;
    import std.algorithm: sort;
    import std.array: array;
    import std.file: exists;

    bool[Module] visited;
    bool[string] paths;
    void collect(Module module_) {
        if (module_ in visited)
            return;
        visited[module_] = true;
        const path = module_.srcfile.toString.idup;
        if (!program.isRootOwned(module_) && path.exists)
            paths[path] = true;
        foreach (dependency; module_.aimports)
            collect(dependency);
    }
    foreach (module_; program.rootModules)
        collect(module_);
    return paths.keys.sort.array;
}


private extern(C++) class Collector : imported!"dmd.visitor".SemanticTimeTransitiveVisitor {
    import dmd.visitor: SemanticTimeTransitiveVisitor;
    alias visit = SemanticTimeTransitiveVisitor.visit;

    import dmd.func: FuncDeclaration;
    import dmd.expression: CallExp, VarExp, DelegateExp, FuncExp;
    import dmd.dtemplate: TemplateDeclaration, TemplateInstance;
    import dmd.attrib: AttribDeclaration, ConditionalDeclaration;
    import dmd.dsymbolsem: include;
    import std.string: fromStringz;
    import std.conv: text;

    private imported!"snakebite.backends.backend".Program _program;
    private bool[FuncDeclaration] _visited;
    private bool[string] _imports;
    private struct Reference {
        string overloads;
        string arguments;
    }
    private Reference[string] _references;

    this(imported!"snakebite.backends.backend".Program program) {
        _program = program;
    }

    // Taking addresses emits the original D symbols. There is no forwarding
    // function and no ABI remapping. Each overload is instantiated separately
    // when taking their address directly is ambiguous. Prefer the original
    // name: recreating unambiguous instances through aliases can make LDC
    // emit duplicate definitions and reject a warning-as-error build.
    // Some instances mention guest-local types or private declarations. They
    // cannot be compiled independently and keep the normal guest fallback.
    private extern(D) string source() {
        if (!_references.length)
            return "";
        import std.algorithm: sort;
        import std.array: array;
        string result = "module snakebite_dependency_image;\n";
        foreach (name; _imports.keys.sort)
            result ~= "import " ~ name ~ ";\n";
        foreach (i, key; _references.keys.sort.array) {
            const reference = _references[key];
            result ~= text("static if (__traits(compiles, &", key, ")) {\n",
                "    export __gshared auto retained", i, " = &", key, ";\n",
                "} else static if (__traits(compiles, ", reference.overloads, ")) {\n",
                "static foreach (index, overload; ", reference.overloads, ") {\n",
                "    static if (__traits(compiles, &overload", reference.arguments, "))\n",
                "        mixin(\"export __gshared auto retained", i,
                "_\" ~ index.stringof ~ q{ = &overload", reference.arguments, ";});\n}\n}\n");
        }
        return result;
    }

    override void visit(TemplateDeclaration declaration) {}

    override void visit(TemplateInstance instance) {
        if (instance.members !is null)
            foreach (member; *instance.members)
                member.accept(this);
    }

    override void visit(AttribDeclaration declaration) {
        if (auto members = include(declaration, null))
            foreach (member; *members)
                member.accept(this);
    }

    override void visit(ConditionalDeclaration declaration) {
        visit(cast(AttribDeclaration) declaration);
    }

    override void visit(FuncDeclaration function_) {
        if (function_ in _visited || function_.fbody is null)
            return;
        _visited[function_] = true;
        if (auto instance = function_.parent.isTemplateInstance) {
            if (instance.tempdecl !is null
                    && !_program.isRootOwned(instance.tempdecl)
                    && !function_.needThis && !function_.isNested) {
                const name = instance.tempdecl.getModule.toPrettyChars.fromStringz.idup;
                _imports[name] = true;
                import std.string: indexOf;
                const spelling = instance.toChars.fromStringz;
                const arguments = spelling[spelling.indexOf('!') .. $].idup;
                const scopeName = instance.tempdecl.parent.toPrettyChars(true).fromStringz;
                const reference = text("__traits(getOverloads, ", scopeName,
                    ", \"", instance.tempdecl.ident.toString, "\", true)");
                _references[instance.toPrettyChars(true).fromStringz.idup] =
                    Reference(reference, arguments);
            }
        }
        function_.fbody.accept(this);
    }

    override void visit(CallExp expression) {
        if (expression.f !is null)
            expression.f.accept(this);
        super.visit(expression);
    }

    override void visit(VarExp expression) {
        if (auto function_ = expression.var.isFuncDeclaration)
            function_.accept(this);
    }

    override void visit(DelegateExp expression) {
        expression.func.accept(this);
        super.visit(expression);
    }

    override void visit(FuncExp expression) {
        expression.fd.accept(this);
    }
}
