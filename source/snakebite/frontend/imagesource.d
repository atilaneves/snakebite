module snakebite.frontend.imagesource;


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
    import dmd.dsymbol: Dsymbol;
    import dmd.expression: CallExp, VarExp, DelegateExp;
    import dmd.mtype: Type;
    import snakebite.backends.backend: Program;
    import std.string: fromStringz;
    import std.conv: text;

    private Program _program;
    private bool[FuncDeclaration] _visited;
    private FuncDeclaration _current;
    private FuncDeclaration[][FuncDeclaration] _callees;
    private bool[FuncDeclaration] _needsRoot;
    private bool[FuncDeclaration] _rootTyped;
    private Instance[FuncDeclaration] _opaque;
    private Type[Dsymbol] _opaqueTypes;
    private string _opaqueDeclarations;
    private bool[string] _imports;
    private bool[Module] _modules;
    private struct Reference {
        FuncDeclaration[] functions;
    }

    // What the image compiles for an instance whose root types it names with
    // opaque stand-ins: the template spelling and the stand-in signature.
    private struct Instance {
        string key;
        imported!"dmd.mtype".TypeFunction type;
    }
    private Reference[string] _references;

    this(Program program) {
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
        import snakebite.dependencyimage: DependencyImage;
        import snakebite.frontend.dmd.mangle: completeFunctionType, mangledNameOf;
        // A dependency template can import a root module internally, even
        // when its template arguments contain no root-owned declarations.
        // Propagate through cycles before deciding which bodies can be linked.
        foreach (key; _references.keys.sort)
            foreach (function_; _references[key].functions)
                if (function_ in _rootTyped && function_ !in _needsRoot
                        && !opaqueInstance(function_))
                    _needsRoot[function_] = true;
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
        result ~= _opaqueDeclarations;
        string registry = "export extern(C) void* "
            ~ DependencyImage.registrySymbol ~ "(const(char)[] name) {\n";
        foreach (i, guestKey; _references.keys.sort.array) {
            auto reference = _references[guestKey]; // Function identities are mutable AST nodes.
            import std.algorithm: canFind;
            if (reference.functions.canFind!(function_ => function_ in _needsRoot))
                continue;
            const key = reference.functions[0] in _opaque
                ? _opaque[reference.functions[0]].key : guestKey;
            // `addressGuard` below prints each function's own declared
            // signature (its pointer type's `toChars`), so its type must
            // already be complete the same way `mangledNameOf` needs it -
            // forced here, once, for every use in this reference's own
            // `guard`/`registry`/`result` text.
            foreach (function_; reference.functions)
                completeFunctionType(function_);
            // Diagnostic type spellings are not always valid D expressions.
            // Parse each candidate inside the guarded mixin so an inaccessible
            // instance can keep its normal guest fallback.
            const guard = addressGuard(reference, key);
            result ~= text("static if (", guard, ") {\n",
                "    export __gshared auto retained", i, " = mixin(q{&", key, "});\n",
                "} else {\n");
            registry ~= text("    static if (", guard,
                ") { static if (!is(typeof(mixin(q{&", key,
                "})) == delegate)) {\n");
            // An eponymous template's .mangleof can name its template
            // instance rather than the function returned by its address.
            foreach (function_; reference.functions)
                registry ~= text("if (name == q{",
                    mangledNameOf(function_),
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

    // The signature that the image source spells: the stand-in one for an
    // instance that the image compiles over opaque types.
    private extern(D) imported!"dmd.mtype".TypeFunction signatureOf(
        FuncDeclaration function_,
    ) {
        if (auto instance = function_ in _opaque)
            return instance.type;
        return function_.type.isTypeFunction; // DMD printers use mutable types.
    }

    // dmd can home another program's instances on a root module. Their
    // types are not dependencies of the program being compiled into an image.
    private extern(D) bool isRootSymbol(Dsymbol symbol) {
        auto module_ = symbol.getModule; // DMD symbol queries are mutable.
        return module_ !is null
            && (_program.isRootOwned(module_) || module_ !in _modules);
    }

    private extern(D) bool mentionsRoot(Type type) {
        bool[Type] visited;
        return eachTemplateArgumentSymbol(type, visited, &isRootSymbol);
    }

    // An instance over a root type is native code that the dependency's
    // compiler can build over a stand-in whenever it handles that type only
    // as a pointer, a class reference or an enum value: the generated code
    // moves the same bits whichever type it is told. The stand-in is an
    // opaque aggregate for a pointee or a class, and the base type for an
    // enum. The result is the instance's own template spelling, its
    // signature and body over stand-ins, or false when the instance needs the
    // root type itself.
    private extern(D) bool opaqueInstance(FuncDeclaration function_) {
        import dmd.dtemplate: isDsymbol, isExpression, isType;
        import dmd.mtype: Parameter, ParameterList, TypeFunction;
        import snakebite.frontend.compiler: newInFrontend;
        import snakebite.frontend.dmd.mangle: completeFunctionType;

        completeFunctionType(function_);
        auto instance = function_.parent.isTemplateInstance;
        auto original = function_.type.isTypeFunction;
        if (instance is null || original is null || instance.tiargs is null
                || original.next is null
                || instance.tempdecl.parent.isModule is null)
            return false;

        // dmd prints an instance from its own template arguments, so print
        // it with the stand-ins in place of the root types.
        string spelling;
        {
            auto originalArguments = (*instance.tiargs)[].dup; // The AST keeps its own arguments.
            scope(exit)
                foreach (i, argument; originalArguments)
                    (*instance.tiargs)[i] = argument;
            foreach (i, argument; originalArguments) {
                if (auto type = isType(argument)) {
                    auto standIn = opaqueType(type, false);
                    if (standIn is null)
                        return false;
                    (*instance.tiargs)[i] = standIn;
                } else if (auto expression = isExpression(argument)) {
                    if (expression.type is null || mentionsRoot(expression.type))
                        return false;
                } else if (isDsymbol(argument) !is null) {
                    bool[Type] visited;
                    if (eachTemplateArgument(argument, visited, &isRootSymbol))
                        return false;
                } else {
                    return false;
                }
            }
            spelling = sourceSpelling(instance.toPrettyChars(true).fromStringz);
        }

        auto next = opaqueType(original.next, false);
        if (next is null)
            return false;
        auto parameters = original.parameterList.parameters is null
            ? null
            : newInFrontend!(Parameter.arraySyntaxCopy)(original.parameterList.parameters);
        const count = original.parameterList.length;
        if (parameters !is null && parameters.length != count)
            return false;
        foreach (i; 0 .. count) {
            auto parameter = (*parameters)[i]; // DMD declarations take mutable parameters.
            auto standIn = opaqueType(parameter.type, false);
            if (standIn is null)
                return false;
            parameter.type = standIn;
        }
        if (!bodyNeedsOnlyStandIns(function_))
            return false;

        auto type = newInFrontend!TypeFunction(
            ParameterList(parameters, original.parameterList.varargs, original.parameterList.stc),
            next, original.linkage,
        );
        type.mod = original.mod;
        type.isNothrow = original.isNothrow;
        type.isNogc = original.isNogc;
        type.isLive = original.isLive;
        type.purity = original.purity;
        type.isProperty = original.isProperty;
        type.isRef = original.isRef;
        type.isReturn = original.isReturn;
        type.isReturnScope = original.isReturnScope;
        type.isScopeQual = original.isScopeQual;
        type.isRvalue = original.isRvalue;
        type.trust = original.trust;
        _opaque[function_] = Instance(spelling, type);
        return true;
    }

    // The stand-in for `type`, with the qualifiers of `type`, or null when
    // `type` holds a root type in any way but as a pointee, a class reference
    // or an enum.
    private extern(D) Type opaqueType(Type type, in bool pointee) {
        import dmd.typesem: addMod, pointerTo;
        import snakebite.frontend.compiler: newInFrontend;

        if (!mentionsRoot(type))
            return type;
        Type standIn;
        if (auto enumType = type.isTypeEnum) {
            if (!isRootSymbol(enumType.sym) || enumType.sym.memtype is null)
                return null;
            standIn = opaqueType(enumType.sym.memtype, false);
        } else if (auto structType = type.isTypeStruct) {
            if (pointee && isRootSymbol(structType.sym))
                standIn = opaqueAggregate(structType.sym, "struct");
        } else if (auto classType = type.isTypeClass) {
            import dmd.aggregate: ClassKind;
            if (classType.sym.classKind == ClassKind.d && isRootSymbol(classType.sym))
                standIn = opaqueAggregate(classType.sym,
                    classType.sym.isInterfaceDeclaration ? "interface" : "class");
        } else if (auto pointerType = type.isTypePointer) {
            if (auto next = opaqueType(pointerType.next, true))
                standIn = newInFrontend!pointerTo(next);
        }
        if (standIn is null)
            return null;
        return type.mod ? newInFrontend!addMod(standIn, type.mod) : standIn;
    }

    // One aggregate without members per root symbol, named after the order in
    // which the sorted references first use it.
    private extern(D) Type opaqueAggregate(Dsymbol symbol, in string keyword) {
        import dmd.dclass: ClassDeclaration, InterfaceDeclaration;
        import dmd.dstruct: StructDeclaration;
        import dmd.identifier: Identifier;
        import dmd.location: Loc;
        import snakebite.frontend.compiler: newInFrontend;

        if (auto known = symbol in _opaqueTypes)
            return *known;
        const name = text("SnakebiteOpaque", _opaqueTypes.length);
        auto identifier = newInFrontend!(Identifier.idPool)(name); // DMD takes a mutable identifier.
        Type type;
        string body_ = ";";
        switch (keyword) {
            case "struct":
                type = newInFrontend!StructDeclaration(Loc.initial, identifier, false).type;
                break;
            case "interface":
                type = newInFrontend!InterfaceDeclaration(Loc.initial, identifier, null).type;
                break;
            default:
                // A class without members still has a size, which
                // `core.atomic` reads when it exchanges a class reference.
                type = newInFrontend!ClassDeclaration(Loc.initial, identifier, null, null, false).type;
                body_ = " {}";
        }
        _opaqueDeclarations ~= text(keyword, " ", name, body_, "\n");
        _opaqueTypes[symbol] = type;
        return type;
    }

    // Whether the body of `function_` moves root values only as pointers,
    // class references and enums: no expression or variable has a root
    // struct, union or other aggregate type, and none reads a member that the
    // root declares.
    private extern(D) bool bodyNeedsOnlyStandIns(FuncDeclaration function_) {
        import dmd.declaration: VarDeclaration;
        import dmd.expression: Expression;
        import dmd.visitor: StoppableVisitor;
        import dmd.visitor.foreachvar: foreachExpAndVar;
        import dmd.visitor.postorder: walkPostorder;

        extern(C++) static final class Finder: StoppableVisitor {
            alias visit = StoppableVisitor.visit;
            Collector collector;

            this(Collector collector) {
                this.collector = collector;
            }

            // A stand-in answers none of what a real class or root symbol
            // answers at run time: its identity, its allocation and what
            // the root declares.
            override void visit(Expression expression) {
                import dmd.astenums: Tclass;
                import dmd.typesem: toBasetype;

                if (expression.type !is null
                        && collector.opaqueType(expression.type, false) is null)
                    stop = true;
                if (expression.isNewExp || expression.isTypeidExp)
                    stop = true;
                if (auto conversion = expression.isCastExp)
                    if (conversion.to.toBasetype.ty == Tclass
                            || conversion.e1.type.toBasetype.ty == Tclass)
                        stop = true;
                if (auto member = expression.isDotVarExp)
                    if (collector._program.isRootOwned(member.var))
                        stop = true;
                if (auto offset = expression.isSymOffExp)
                    if (collector._program.isRootOwned(offset.var))
                        stop = true;
            }
        }

        scope finder = new Finder(this);
        if (function_.fbody is null)
            return true;
        function_.fbody.foreachExpAndVar(
            (expression) { walkPostorder(expression, finder); },
            (variable) {
                if (opaqueType(variable.type, false) is null)
                    finder.stop = true;
            },
        );
        return !finder.stop;
    }

    // `mixin(q{&key})` takes the address of a diagnostic instantiation
    // spelling, not of a specific `FuncDeclaration`: when `key` names one
    // member of an eponymous template, two sibling overloads share the
    // exact same spelling and the plain `auto pointer = mixin(q{&key})`
    // check already fails on that ambiguity alone. When `key` instead names
    // one of several distinct, separately declared function templates (e.g.
    // `std.regex.regex`'s single-pattern and array-of-patterns overloads),
    // dmd's template partial ordering can pick a *different* overload than
    // the one this `key` was recorded for, with no ambiguity error at all:
    // `auto pointer = mixin(q{&key})` happily accepts whichever declaration
    // dmd silently settled on. Assigning that same, freshly re-resolved
    // `pointer` value into a variable of each referenced function's own
    // pointer type forces an exact type match, closing that hole the same
    // way `overloadRegistry`'s typed selection already does, and sends a
    // mismatch to the safe, ordinal-selected fallback instead. The typed
    // declaration is parsed through a nested `mixin(q{...})`, the same
    // deferral `overloadRegistry` below relies on: a printed pointer type
    // can carry a linkage attribute (`extern(C) ... function(...)`), and
    // `__traits(compiles, ...)` only gags a semantic error, not a parse
    // error from source sitting directly in its block - deferring the
    // parse into a nested mixin makes it happen speculatively too.
    private extern(D) string addressGuard(Reference reference, in string key) {
        import dmd.typesem: pointerTo;
        import snakebite.frontend.compiler: newInFrontend;

        const untyped = text("mixin(q{&", key, "})");
        string guard = text("__traits(compiles, { auto pointer = ", untyped, "; })");
        foreach (function_; reference.functions) {
            auto type = signatureOf(function_);
            if (type is null)
                continue;
            auto pointerType = newInFrontend!pointerTo(type);
            const declaration = text(sourceSpelling(pointerType.toChars.fromStringz),
                " matched = pointer;");
            guard ~= text(" && __traits(compiles, { auto pointer = ", untyped,
                "; mixin(q{", declaration, "}); })");
        }
        return guard;
    }

    private extern(D) string overloadRegistry(
        FuncDeclaration function_, in string key,
    ) {
        import dmd.typesem: pointerTo;
        import snakebite.frontend.compiler: newInFrontend;
        import snakebite.frontend.dmd.mangle: mangledNameOf;

        auto type = signatureOf(function_);
        if (type is null)
            return "";
        // Forces `function_`'s type complete first (`mangledNameOf`'s own
        // doc): `pointerTo`/`toChars` below print its declared signature,
        // an inferred return type or attribute set dmd has not resolved
        // yet would otherwise print incomplete.
        const mangled = mangledNameOf(function_);
        auto pointerType = newInFrontend!pointerTo(type);
        const pointer = text(sourceSpelling(pointerType.toChars.fromStringz),
            " pointer = &", key, ";");
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
        auto type = signatureOf(function_);
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
                    && !isImportCBuiltins(instance.tempdecl.getModule)
                    && !function_.needThis && !function_.isNested
                    && !hasFunctionLocalType(instance)) {
                const name = instance.tempdecl.getModule.toPrettyChars.fromStringz.idup;
                _imports[name] = true;
                import dmd.mtype: Type;
                bool[Type] visited;
                // Pointer, array, delegate parameter, associative array
                // key, tuple element, and nested template instance
                // arguments can all also name dependency types.
                bool rooted;
                eachTemplateArgument(instance, visited, (symbol) {
                    if (isRootSymbol(symbol))
                        rooted = true;
                    else if (auto module_ = symbol.getModule) // DMD symbol queries are mutable.
                        _imports[module_.toPrettyChars.fromStringz.idup] = true;
                    return false;
                });
                if (rooted)
                    _rootTyped[function_] = true;
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


// The module that dmd imports into every C file for the `__builtin_*`
// functions. Its file is `__importc_builtins.di`, not `__builtins.d`, so no
// `import` of it from another module finds it; its functions run from their
// bodies.
private bool isImportCBuiltins(imported!"dmd.dmodule".Module module_) {
    return module_.ident.toString == "__builtins";
}


// Function-local types cannot be named from an independent module. Their
// enclosing dependency body can still instantiate them when it is compiled.
private bool hasFunctionLocalType(imported!"dmd.dtemplate".TemplateInstance instance) {
    import dmd.mtype: Type;

    bool[Type] visited;
    return eachTemplateArgument(instance, visited, (symbol) {
        for (auto ancestor = symbol.parent; ancestor !is null; ancestor = ancestor.parent)
            if (ancestor.isFuncDeclaration)
                return true;
        return false;
    });
}


// A template argument's type can hide a dependency-relevant symbol several
// levels deep: through a pointer/array/delegate return type (dmd's own
// `nextOf` chain), through a function or delegate parameter type, through an
// associative array's key type, through a tuple's element types, or through
// the arguments of a nested template instance (e.g. `Outer!(Inner!Deep)`,
// or a member such as `Appender!Deep.Appender.Data`). Visit every symbol
// reachable this way and hand it to `each`; returning `true` from `each`
// stops the walk early. A previously-seen type also stops the walk, guarding
// against cycles through self-referential template instances.
private bool eachTemplateArgumentSymbol(
    imported!"dmd.mtype".Type type,
    ref bool[imported!"dmd.mtype".Type] visited,
    scope bool delegate(imported!"dmd.dsymbol".Dsymbol) each,
) {
    import dmd.typesem: nextOf, toDsymbol;

    while (type !is null) {
        if (type in visited)
            return false;
        visited[type] = true;

        if (auto function_ = type.isTypeFunction) {
            foreach (i; 0 .. function_.parameterList.length)
                if (eachTemplateArgumentSymbol(function_.parameterList[i].type, visited, each))
                    return true;
        } else if (auto associativeArray = type.isTypeAArray) {
            if (eachTemplateArgumentSymbol(associativeArray.index, visited, each))
                return true;
        } else if (auto tuple = type.isTypeTuple) {
            if (tuple.arguments !is null)
                foreach (parameter; *tuple.arguments)
                    if (eachTemplateArgumentSymbol(parameter.type, visited, each))
                        return true;
        }

        if (auto symbol = type.toDsymbol(null)) {
            if (eachFoundSymbol(symbol, visited, each))
                return true;
        }

        type = type.nextOf;
    }
    return false;
}


// A found symbol (whether named by a type or directly by an alias argument)
// is handed to `each`, then it and its ancestors are climbed: any enclosing
// `TemplateInstance` (or the symbol itself, when it is one) can carry
// tiargs that name further dependency-relevant symbols (e.g.
// `Bucket!(string, X)` found through a type reaches here for `Bucket`,
// whose enclosing instance's tiargs still need inspecting for `X`; an alias
// argument such as `apply!(pick!Thing)` for a single-member eponymous
// `pick` reaches here for `pick`, whose enclosing instance's tiargs still
// need inspecting for `Thing` - but for a multi-member `pick`, dmd does not
// collapse the argument to a member: it reaches here as the `pick!Thing`
// `TemplateInstance` itself, so the climb must inspect its own tiargs too,
// not just an enclosing instance's). One rule, shared by both callers below.
private bool eachFoundSymbol(
    imported!"dmd.dsymbol".Dsymbol symbol,
    ref bool[imported!"dmd.mtype".Type] visited,
    scope bool delegate(imported!"dmd.dsymbol".Dsymbol) each,
) {
    if (each(symbol))
        return true;
    for (auto ancestor = symbol; ancestor !is null; ancestor = ancestor.parent)
        if (auto instance = ancestor.isTemplateInstance)
            if (eachTemplateArgument(instance, visited, each))
                return true;
    return false;
}


// An alias argument names a symbol directly, with no type to recurse through.
private bool eachTemplateArgument(
    imported!"dmd.rootobject".RootObject argument,
    ref bool[imported!"dmd.mtype".Type] visited,
    scope bool delegate(imported!"dmd.dsymbol".Dsymbol) each,
) {
    import dmd.dtemplate: getType, isDsymbol;

    if (auto type = getType(argument))
        return eachTemplateArgumentSymbol(type, visited, each);
    if (auto symbol = isDsymbol(argument))
        return eachFoundSymbol(symbol, visited, each);
    return false;
}


// Walks every one of a `TemplateInstance`'s own tiargs, stopping early when
// `each` (reached through `eachTemplateArgument` above) returns `true`. The
// three sites that inspect a `TemplateInstance`'s tiargs share this loop.
private bool eachTemplateArgument(
    imported!"dmd.dtemplate".TemplateInstance instance,
    ref bool[imported!"dmd.mtype".Type] visited,
    scope bool delegate(imported!"dmd.dsymbol".Dsymbol) each,
) {
    if (instance.tiargs is null)
        return false;
    foreach (argument; *instance.tiargs)
        if (eachTemplateArgument(argument, visited, each))
            return true;
    return false;
}


// DMD's diagnostic printer abbreviates single integer template arguments,
// even when their type requires a cast. Such casts require parentheses in
// source. Token boundaries keep nested instances and string arguments intact.
private string sourceSpelling(in char[] spelling) {
    import dmd.tokens: TOK;
    import snakebite.frontend.compiler: lex;

    const tokens = lex(spelling);
    string result;
    size_t copied;
    size_t next;
    TOK value() => tokens[next].value;

    while (value != TOK.endOfFile) {
        if (value != TOK.not) {
            ++next;
            continue;
        }
        ++next;
        if (value != TOK.cast_)
            continue;
        const start = tokens[next].offset;
        // Folded pointer and enum values can have more than one cast.
        while (value == TOK.cast_) {
            ++next;
            assert(value == TOK.leftParenthesis);
            size_t depth;
            do {
                if (value == TOK.leftParenthesis)
                    ++depth;
                else if (value == TOK.rightParenthesis)
                    --depth;
                assert(value != TOK.endOfFile);
                ++next;
            } while (depth);
        }
        if (value == TOK.min || value == TOK.add)
            ++next;
        ++next;
        const end = tokens[next].offset;
        result ~= spelling[copied .. start] ~ "(" ~ spelling[start .. end] ~ ")";
        copied = end;
    }
    result ~= spelling[copied .. $];
    return result;
}
