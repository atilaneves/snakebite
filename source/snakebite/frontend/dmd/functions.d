module snakebite.frontend.dmd.functions;

private:

// The module-level function called `name`, or null if there is none.
public imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    return findFunction(module_.members, name);
}

// The member function of `struct_` called `name`, or null if there is none.
public imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.dstruct".StructDeclaration struct_,
    in string name,
) {
    return findFunction(struct_.members, name);
}

// The module-level struct called `name`, or null if there is none.
public imported!"dmd.dstruct".StructDeclaration findStruct(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    if (module_.members is null)
        return null;

    foreach (member; *module_.members) {
        auto struct_ = member.isStructDeclaration;
        if (struct_ !is null && struct_.ident.toString == name)
            return struct_;
    }

    return null;
}

// Whether `declaration` belongs to one of the modules in `rootModules`,
// rather than a module dmd only reached through an `import`.
// `Dsymbol.getModule` gives back the module that owns a declaration
// regardless of which template instance or mixin walked into it, so this
// is the one question every backend and frontend walk asks to tell
// root-owned guest code apart from a called dependency (docs/adr/0009).
//
// `rootModules` is a set the caller builds once, not the root module list
// itself: `Program.isInterpreted` asks this question again for every
// guest call the interpreter dispatches, so an `O(1)` lookup keyed by
// module beats a linear scan repeated that often. A one-time frontend
// walk, such as the inline-asm load check, pays the same small cost to
// build its own set once and gets the same shape, instead of a second,
// differently shaped predicate that can drift from this one.
public bool isRootOwned(
    imported!"dmd.dsymbol".Dsymbol declaration,
    in bool[imported!"dmd.dmodule".Module] rootModules,
) {
    return (declaration.getModule in rootModules) !is null;
}

// `function_`'s type as the function type it must be. A `FuncDeclaration`
// whose type is not a `TypeFunction` would be a malformed AST, not a guest
// construct a backend has chosen not to support, so this halts on it as
// the internal error it is rather than reporting a refusal. `assert(false)`
// rather than `assert(cond)`: the latter is elided by `-release`, leaving a
// null for the caller to dereference, and a silent null here is worse than
// a stop.
public imported!"dmd.mtype".TypeFunction typeFunctionOf(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    auto type = function_.type.isTypeFunction;
    if (type is null)
        assert(false,
            text("`", function_.toString, "` has non-function type `",
                function_.type.toString, "`"));

    return type;
}

public imported!"dmd.mtype".TypeFunction typeFunctionOf(
    imported!"dmd.expression".CallExp expression,
) {
    import dmd.astenums: Tdelegate, Tpointer;
    import dmd.typesem: nextOf;

    if (expression.f !is null)
        return typeFunctionOf(expression.f);
    auto type = expression.e1.type;
    if (type is null)
        return null;
    if (type.ty == Tdelegate || type.ty == Tpointer)
        type = type.nextOf;
    return type.isTypeFunction;
}

// The `FuncDeclaration` `expression.e1` already names directly, for a
// call dmd built by hand instead of running it through the usual
// semantic pass that would otherwise resolve `expression.f` itself.
// Two such calls reach here: a native aggregate method's own call
// (`e1` a `VarExp` naming the `FuncDeclaration` directly), and a
// struct or class invariant's entry/exit call, which `addInvariant`
// (dmd's `funcsem.d`) builds as `CallExp(DotVarExp(ThisExp, inv))`
// with the `expressionSemantic` call that would otherwise set `.f`
// commented out - bugzilla 13113 wants a virtual invariant call to
// bypass attribute enforcement rather than run through it.
// `DotVarExp.var` already names `inv` directly in that shape. Returns
// `null` for a call reached only through a runtime value, a delegate
// or a function pointer, which has no `FuncDeclaration` to name until
// that value itself is read.
public imported!"dmd.func".FuncDeclaration unresolvedCalleeOf(
    imported!"dmd.expression".CallExp expression,
) {
    if (auto variable = expression.e1.isVarExp)
        return variable.var.isFuncDeclaration;

    if (auto dot = expression.e1.isDotVarExp)
        return dot.var.isFuncDeclaration;

    return null;
}

// Every unittest in `module_`, in declaration order, as druntime's
// `__modtest` runs them: the ones nested in a struct or a class count too,
// so the search descends into aggregates as well as attributes.
public imported!"dmd.func".FuncDeclaration[] findUnittests(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.func: FuncDeclaration;

    FuncDeclaration[] unittests;
    appendUnittests(module_.members, unittests);
    return unittests;
}

// Every module constructor in `module_` that belongs to the root package.
// Constructors in instantiated templates are members of the template
// instance, not the module, so the search descends into those instances. An
// uninstantiated template is not part of the build and is not visited.
// Shared constructors run before ordinary constructors, as druntime does.
public imported!"dmd.func".FuncDeclaration[] findModuleConstructors(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.func: FuncDeclaration;

    FuncDeclaration[] sharedCtors;
    FuncDeclaration[] ordinary;
    appendModuleConstructors(module_.members, sharedCtors, ordinary);
    return sharedCtors ~ ordinary;
}

private void appendModuleConstructors(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref imported!"dmd.func".FuncDeclaration[] sharedCtors,
    ref imported!"dmd.func".FuncDeclaration[] ordinary,
) {
    if (symbols is null)
        return;

    foreach (member; *symbols) {
        if (auto constructor = member.isSharedStaticCtorDeclaration()) {
            sharedCtors ~= constructor;
            continue;
        }

        if (auto constructor = member.isStaticCtorDeclaration()) {
            ordinary ~= constructor;
            continue;
        }

        // `.decl` is the syntactic "then" branch even when the condition
        // resolved otherwise; `include` gives the branch a real build
        // compiles in.
        if (auto attributes = member.isAttribDeclaration()) {
            import dmd.dsymbolsem: include;

            appendModuleConstructors(
                include(attributes, null), sharedCtors, ordinary);
            continue;
        }

        // Only instantiated templates contribute declarations to this root
        // package. Aggregate constructors are type constructors, not module
        // constructors, so do not descend into arbitrary scope symbols.
        if (auto instance = member.isTemplateInstance())
            appendModuleConstructors(instance.members, sharedCtors, ordinary);
    }
}

private void appendUnittests(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref imported!"dmd.func".FuncDeclaration[] unittests,
) {
    if (symbols is null)
        return;

    foreach (member; *symbols) {
        if (auto unittest_ = member.isUnitTestDeclaration) {
            // DMD's parser skips the unittest blocks of a non-root module
            // but still declares an empty placeholder for each one, so a
            // scope's symbol count does not depend on `-unittest`. An
            // instance of a Phobos template in a root module carries those
            // placeholders. Compiled D never emits a function without a
            // body, so `__modtest` never calls one; neither does this.
            if (unittest_.fbody !is null)
                unittests ~= unittest_;
            continue;
        }

        // `.decl` is the syntactic "then" branch even when the condition
        // resolved otherwise; `include` gives the branch a real build
        // compiles in. See `findFunction` below.
        if (auto attributes = member.isAttribDeclaration) {
            import dmd.dsymbolsem: include;

            appendUnittests(include(attributes, null), unittests);
        }

        if (auto aggregate = member.isAggregateDeclaration)
            appendUnittests(aggregate.members, unittests);

        if (auto instance = member.isTemplateInstance)
            appendUnittests(instance.members, unittests);
    }
}

// Attribute declarations (`static:`, `private:`, ...) wrap the symbols they
// apply to, so the search descends into them.
private imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    in string name,
) {
    if (symbols is null)
        return null;

    foreach (member; *symbols) {
        auto function_ = member.isFuncDeclaration;
        if (function_ !is null && function_.ident.toString == name)
            return function_;

        // `AttribDeclaration.decl` is always the syntactic "then" branch,
        // even for a `version`/`debug`/`static if` declaration whose
        // condition resolved to the "else" branch - the resolved branch
        // lives behind `dsymbolsem.include`, dmd's own accessor for this.
        // Descending into `.decl` unconditionally here would walk dead code
        // a real build never compiles in.
        if (auto attributes = member.isAttribDeclaration) {
            import dmd.dsymbolsem: include;

            if (auto found = findFunction(include(attributes, null), name))
                return found;
        }

        // An instantiated template contributes its expanded declarations to
        // this module. An uninstantiated template is not part of the build.
        if (auto instance = member.isTemplateInstance) {
            if (auto found = findFunction(instance.members, name))
                return found;
        }
    }

    return null;
}
