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


// Named distinctly from `inlineasm.d`'s `InlineAsmCollector` and
// `InlineAsmVersionGate`, and from `DeclarationCollector`
// (`declarationcollector.d`), the shared base this class extends: all are
// plain `extern(C++) class`es with no explicit C++ namespace, so identical
// class names mangle to the identical C++ symbol and the linker keeps only
// one definition - silently routing calls meant for this class into
// another one's vtable instead of a link error.
private extern(C++) class Collector
        : imported!"snakebite.frontend.declarationcollector".DeclarationCollector {
    import snakebite.frontend.declarationcollector: DeclarationCollector;
    alias visit = DeclarationCollector.visit;

    import dmd.func: FuncDeclaration;
    import dmd.dmodule: Module;
    import dmd.expression: CallExp, VarExp, DelegateExp;
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
        FuncDeclaration[] functions;
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

    // Address references retain unambiguous instances. Calls in unused anchor
    // bodies select ambiguous overloads through their argument types. Aliasing
    // one template overload can change recursive lookup inside its body in LDC.
    // Both forms emit the original symbols that the backends call through FFI.
    // Inaccessible instances keep the normal guest fallback.
    private extern(D) string source() {
        if (!_references.length)
            return "";
        import std.algorithm: sort;
        import std.array: array;
        import dmd.mangle: mangleExact;
        import snakebite.dependencyimage: DependencyImage;
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
        string registry = "export extern(C) void* "
            ~ DependencyImage.registrySymbol ~ "(const(char)[] name) {\n";
        foreach (i, key; _references.keys.sort.array) {
            auto reference = _references[key]; // Function identities are mutable AST nodes.
            import std.algorithm: canFind;
            if (reference.functions.canFind!(function_ => function_ in _needsRoot))
                continue;
            // Diagnostic type spellings are not always valid D expressions.
            // Parse each candidate inside the guarded mixin so an inaccessible
            // instance can keep its normal guest fallback.
            result ~= text("static if (__traits(compiles, { auto pointer = mixin(q{&", key, "}); })) {\n",
                "    export __gshared auto retained", i, " = mixin(q{&", key, "});\n",
                "} else {\n");
            registry ~= text("    static if (__traits(compiles, { auto pointer = mixin(q{&", key,
                "}); })) { static if (!is(typeof(mixin(q{&", key,
                "})) == delegate)) {\n");
            // An eponymous template's .mangleof can name its template
            // instance rather than the function returned by its address.
            foreach (function_; reference.functions)
                registry ~= text("if (name == q{",
                    mangleExact(function_).fromStringz,
                    "}) return cast(void*) mixin(q{&", key, "});\n");
            registry ~= "}\n} else {\n";
            foreach (j, function_; reference.functions) {
                registry ~= overloadRegistry(function_, key);
                const anchor = overloadAnchor(function_, key, text("retained", i, "_", j));
                if (!anchor.length)
                    continue;
                result ~= text("static if (__traits(compiles, { mixin(q{", anchor,
                    "}); })) mixin(q{export ", anchor, "});\n");
            }
            registry ~= "}\n";
            result ~= "}\n";
        }
        registry ~= "    return null;\n}\n";
        result ~= registry;
        return result;
    }

    private extern(D) string overloadRegistry(
        FuncDeclaration function_, in string key,
    ) {
        import dmd.mangle: mangleExact;
        import dmd.typesem: pointerTo;

        if (function_.type.isTypeFunction is null)
            return "";
        auto pointerType = function_.type.pointerTo; // DMD caches mutable type nodes.
        const pointer = text(sourceSpelling(pointerType.toChars.fromStringz),
            " pointer = &", key, ";");
        const mangled = mangleExact(function_).fromStringz;
        const result = text("{\nstatic if (__traits(compiles, { mixin(q{", pointer,
            "}); })) {\nmixin(q{", pointer, "});\n",
            "if (name == q{", mangled,
            "}) return cast(void*) pointer;\n} else {\n");
        const selected = selectedOverload(
            function_, key, sourceSpelling(pointerType.toChars.fromStringz), mangled,
        );
        return result ~ selected ~ "}\n}\n";
    }

    // Empty when the function does not come from a module-scope template
    // whose overload can be selected by ordinal.
    private extern(D) string selectedOverload(
        FuncDeclaration function_, in string key, in const(char)[] pointerSpelling, in const(char)[] mangled,
    ) {
        import dmd.dsymbol: Dsymbol;
        import dmd.funcsem: overloadApply;
        import std.algorithm: startsWith;

        auto instance = function_.parent.isTemplateInstance; // AST queries require mutable nodes.
        auto declaration = instance.tempdecl; // AST queries require mutable nodes.
        if (declaration.parent.isModule is null)
            return "";
        const moduleName = declaration.getModule.toPrettyChars.fromStringz;
        const identifier = declaration.ident.toChars.fromStringz;
        const prefix = text(moduleName, ".", identifier);
        if (!key.startsWith(prefix ~ "!("))
            return "";
        auto head = declaration.getModule.symtab.lookup(declaration.ident); // Overload traversal requires mutable nodes.
        if (head is null)
            return "";
        if (auto template_ = head.isTemplateDeclaration) {
            if (template_.funcroot !is null)
                head = template_.funcroot;
        }
        size_t ordinal;
        bool found;
        overloadApply(head, (Dsymbol symbol) {
            if (symbol is declaration) {
                found = true;
                return 1;
            }
            if (symbol.isFuncDeclaration !is null || symbol.isTemplateDeclaration !is null)
                ++ordinal;
            return 0;
        });
        if (!found)
            return "";
        const candidate = "overload" ~ key[prefix.length .. $];
        // Selecting the template declaration first avoids ambiguous source
        // expressions. Distinct declarations can also share a mangled name,
        // so use the same traversal order as __traits(getOverloads).
        const selection = text("alias overload = __traits(getOverloads, ",
            moduleName, ", \"", identifier, "\", true)[", ordinal, "];\n");
        const selectedPointer = text("mixin(q{", pointerSpelling,
            " pointer = &", candidate, ";});\n");
        return text("static if (__traits(compiles, { ", selection,
            selectedPointer, "})) {\n", selection, selectedPointer,
            "if (name == q{", mangled,
            "}) return cast(void*) pointer;\n",
            "}\n");
    }

    private extern(D) string overloadAnchor(
        FuncDeclaration function_, in string key, in string name,
    ) {
        import dmd.astenums: STC;

        // Speculative template instances can retain an error type.
        auto type = function_.type.isTypeFunction; // DMD printers use mutable types.
        if (type is null)
            return "";
        string parameters;
        string arguments;
        const count = type.parameterList.length;
        foreach (i; 0 .. count) {
            auto parameter = type.parameterList[i]; // DMD printers use mutable types.
            if (i) {
                parameters ~= ", ";
                arguments ~= ", ";
            }
            if (parameter.storageClass & STC.ref_)
                parameters ~= "ref ";
            else if (parameter.storageClass & STC.out_)
                parameters ~= "out ";
            else if (parameter.storageClass & STC.lazy_)
                parameters ~= "lazy ";
            const argument = text("argument", i);
            parameters ~= sourceSpelling(parameter.type.toChars.fromStringz)
                ~ " " ~ argument;
            arguments ~= argument;
        }
        return text("void ", name, "(", parameters, ") { ",
            key, "(", arguments, "); }");
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
                    && !function_.needThis && !function_.isNested
                    && !hasFunctionLocalType(instance)) {
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
                const key = sourceSpelling(instance.toPrettyChars(true).fromStringz);
                if (key !in _references)
                    _references[key] = Reference.init;
                _references[key].functions ~= function_;
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
}


// Function-local types cannot be named from an independent module. Their
// enclosing dependency body can still instantiate them when it is compiled.
private bool hasFunctionLocalType(imported!"dmd.dtemplate".TemplateInstance instance) {
    import dmd.dtemplate: getType;
    import dmd.typesem: nextOf, toDsymbol;

    foreach (argument; *instance.tiargs) {
        for (auto type = getType(argument); type !is null; type = type.nextOf) {
            for (auto symbol = type.toDsymbol(null); symbol !is null; symbol = symbol.parent)
                if (symbol.isFuncDeclaration)
                    return true;
        }
    }
    return false;
}


// DMD's diagnostic printer abbreviates single integer template arguments,
// even when their type requires a cast. Such casts require parentheses in
// source. Token boundaries keep nested instances and string arguments intact.
private string sourceSpelling(in char[] spelling) {
    import dmd.lexer: Lexer;
    import dmd.globals: global;
    import dmd.tokens: TOK;

    const input = spelling ~ "\0";
    scope lexer = new Lexer(null, input.ptr, 0, spelling.length,
        false, false, global.errorSink, &global.compileEnv);
    string result;
    size_t copied;
    lexer.nextToken;
    while (lexer.token.value != TOK.endOfFile) {
        if (lexer.token.value != TOK.not) {
            lexer.nextToken;
            continue;
        }
        lexer.nextToken;
        if (lexer.token.value != TOK.cast_)
            continue;
        const start = lexer.token.ptr - input.ptr;
        // Folded pointer and enum values can have more than one cast.
        while (lexer.token.value == TOK.cast_) {
            lexer.nextToken;
            assert(lexer.token.value == TOK.leftParenthesis);
            size_t depth;
            do {
                if (lexer.token.value == TOK.leftParenthesis)
                    ++depth;
                else if (lexer.token.value == TOK.rightParenthesis)
                    --depth;
                assert(lexer.token.value != TOK.endOfFile);
                lexer.nextToken;
            } while (depth);
        }
        if (lexer.token.value == TOK.min || lexer.token.value == TOK.add)
            lexer.nextToken;
        lexer.nextToken;
        const end = lexer.token.ptr - input.ptr;
        result ~= spelling[copied .. start] ~ "(" ~ spelling[start .. end] ~ ")";
        copied = end;
    }
    result ~= spelling[copied .. $];
    return result;
}
