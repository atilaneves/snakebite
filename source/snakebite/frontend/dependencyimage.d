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
    import dmd.dmodule: Module;
    import dmd.expression: CallExp, VarExp, DelegateExp, FuncExp;
    import dmd.dtemplate: TemplateDeclaration, TemplateInstance;
    import dmd.attrib: AttribDeclaration, ConditionalDeclaration;
    import dmd.dsymbolsem: include;
    import std.string: fromStringz;
    import std.conv: text;

    private imported!"snakebite.backends.backend".Program _program;
    private bool[FuncDeclaration] _visited;
    private FuncDeclaration _current;
    private FuncDeclaration[][FuncDeclaration] _callees;
    private bool[FuncDeclaration] _needsRoot;
    private bool[string] _imports;
    private bool[Module] _modules;
    private struct Reference {
        string overloads;
        string arguments;
        FuncDeclaration[] functions;
        string selected = "false";
    }
    private Reference[string] _references;

    this(imported!"snakebite.backends.backend".Program program) {
        _program = program;
        foreach (module_; program.rootModules)
            collectModules(module_);
    }

    private extern(D) void collectModules(Module module_) {
        if (module_ in _modules)
            return;
        _modules[module_] = true;
        foreach (dependency; module_.aimports)
            collectModules(dependency);
    }

    // Taking addresses emits the original D symbols. There is no forwarding
    // function and no ABI remapping. Each overload is instantiated separately
    // when taking their address directly is ambiguous. Prefer the original
    // name: recreating unambiguous instances through aliases can make LDC
    // emit duplicate definitions and reject a warning-as-error build. If
    // template selection is ambiguous before the cast, use the alias.
    // Some instances mention guest-local types or private declarations. They
    // cannot be compiled independently and keep the normal guest fallback.
    private extern(D) string source() {
        if (!_references.length)
            return "";
        import std.algorithm: sort;
        import std.array: array;
        // A dependency template can import a root module internally, even
        // when its template arguments contain no root-owned declarations.
        // Propagate through cycles before deciding which bodies can be linked.
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (caller, callees; _callees) {
                if (caller in _needsRoot)
                    continue;
                foreach (callee; callees) {
                    if (_program.isRootOwned(callee) || callee in _needsRoot) {
                        _needsRoot[caller] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }
        string result = "module snakebite_dependency_image;\n";
        foreach (name; _imports.keys.sort)
            result ~= "import " ~ name ~ ";\n";
        foreach (i, key; _references.keys.sort.array) {
            auto reference = _references[key]; // Function identities are mutable AST nodes.
            import std.algorithm: canFind;
            if (reference.functions.canFind!(function_ => function_ in _needsRoot))
                continue;
            result ~= text("static if (__traits(compiles, { auto pointer = &", key, "; })) {\n",
                "    export __gshared auto retained", i, " = &", key, ";\n",
                "} else static if (__traits(compiles, ", reference.overloads, ")) {\n",
                "static foreach (index, overload; ", reference.overloads, ") {\n",
                "    static if (", reference.selected, ") {\n",
                "    static if (__traits(compiles, { auto pointer = cast(typeof(&overload", reference.arguments, ")) &", key, "; }))\n",
                "        mixin(\"export __gshared auto retained", i,
                "_\" ~ index.stringof ~ q{ = cast(typeof(&overload", reference.arguments, ")) &", key, ";});\n",
                "    else static if (__traits(compiles, { auto pointer = &overload", reference.arguments, "; }))\n",
                "        mixin(\"export __gshared auto retained", i,
                "_\" ~ index.stringof ~ q{ = &overload", reference.arguments, ";});\n}\n}\n}\n");
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
        if (_current !is null)
            _callees[_current] ~= function_;
        if (function_ in _visited || function_.fbody is null
                || function_.parent is null)
            return;
        _visited[function_] = true;
        auto previous = _current; // DMD visitors require mutable declarations.
        _current = function_;
        scope(exit) _current = previous;
        if (auto instance = function_.parent.isTemplateInstance) {
            if (instance.tempdecl !is null
                    && !_program.isRootOwned(instance.tempdecl)
                    && !function_.needThis && !function_.isNested) {
                const name = instance.tempdecl.getModule.toPrettyChars.fromStringz.idup;
                _imports[name] = true;
                import dmd.dtemplate: getType;
                import dmd.typesem: nextOf, toDsymbol;
                foreach (argument; *instance.tiargs) {
                    // Pointer and array arguments can also name dependency types.
                    for (auto type = getType(argument); type !is null; type = type.nextOf) {
                        if (auto symbol = type.toDsymbol(null)) {
                            auto module_ = symbol.getModule; // DMD symbol queries are mutable.
                            if (module_ !is null) {
                                // DMD can home another program's instances on
                                // this root. Their types are not dependencies
                                // of the program being compiled into an image.
                                if (_program.isRootOwned(module_) || module_ !in _modules)
                                    _needsRoot[function_] = true;
                                else
                                    _imports[module_.toPrettyChars.fromStringz.idup] = true;
                            }
                        }
                    }
                }
                import std.string: indexOf;
                const spelling = instance.toChars.fromStringz;
                const arguments = spelling[spelling.indexOf('!') .. $].idup;
                const scopeName = instance.tempdecl.parent.toPrettyChars(true).fromStringz;
                const reference = text("__traits(getOverloads, ", scopeName,
                    ", \"", instance.tempdecl.ident.toString, "\", true)");
                const key = instance.toPrettyChars(true).fromStringz.idup;
                if (key !in _references)
                    _references[key] = Reference(reference, arguments);
                _references[key].functions ~= function_;
                // Reinstantiating unselected overloads can emit distinct bodies
                // with the same mangled name after template aliases expand.
                import dmd.dsymbol: Dsymbol;
                import dmd.funcsem: overloadApply;
                Dsymbol first = instance.tempdecl;
                if (auto declaration = instance.tempdecl.isTemplateDeclaration) {
                    if (declaration.funcroot !is null)
                        first = declaration.funcroot;
                    else if (declaration.overroot !is null)
                        first = declaration.overroot;
                }
                size_t index;
                overloadApply(first, (symbol) {
                    if (symbol is instance.tempdecl)
                        _references[key].selected ~= text(" || index == ", index);
                    if (symbol.isFuncDeclaration || symbol.isTemplateDeclaration)
                        ++index;
                    return 0;
                });
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
        if (_current !is null && _program.isRootOwned(expression.var))
            _needsRoot[_current] = true;
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
