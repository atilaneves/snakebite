module snakebite.frontend.dmd.functions;

private:


import snakebite.failure.report: internalFailure;

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

// Whether `function_` has C linkage.
public bool hasCLinkage(imported!"dmd.func".FuncDeclaration function_) {
    import dmd.astenums: LINK;

    return function_.resolvedLinkage == LINK.c;
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
// itself: `Program.isRootOwned` asks this question again for every
// guest call the interpreter dispatches, so an `O(1)` lookup keyed by
// module beats a linear scan repeated that often. A one-time frontend
// walk, such as the inline-asm load check, pays the same small cost to
// build its own set once and gets the same shape, instead of a second,
// differently shaped predicate that can drift from this one.
public bool isRootOwned(
    imported!"dmd.dsymbol".Dsymbol declaration,
    in bool[imported!"dmd.dmodule".Module] rootModules,
) {
    return (moduleOf(declaration) in rootModules) !is null;
}

// Where a declaration is defined, as the linker of a native build sees it
// (ADR-0009). "Here" is the compile of the root modules.
public enum Defined {
    // Only this compile defines it: what a root module declares.
    onlyHere,
    // This compile defines it, and another object can define it too: what a
    // template instance holds, because a native build emits an instance into
    // each object that uses it. One copy is kept.
    hereAndPossiblyElsewhere,
    // Another object defines it: a declaration with no body or an `extern`
    // one, and each declaration of a dependency module that its archive
    // defines. A missing symbol for it is a link error, never a reason to use
    // the body.
    notHere,
}

// The one decision of where `declaration` is defined. A function literal and
// what a template instance holds are defined here. The exception is an
// instance whose body no backend executes: the dependency image holds it
// (ADR-0009, decision 1). What is nested in a function (its static locals and
// nested functions) is defined where that function is: in the archive for a
// function of a dependency that is not in a template instance. The answer
// comes from the declaration alone, never from a loaded image, so a compile
// with no image gives the same answer.
public Defined whereDefined(
    imported!"dmd.dsymbol".Dsymbol declaration,
    in bool[imported!"dmd.dmodule".Module] rootModules,
) {
    import dmd.astenums: STC;

    auto function_ = declaration.isFuncDeclaration;
    if (function_ !is null && function_.fbody is null)
        return Defined.notHere;
    if (auto named = declaration.isDeclaration)
        if (named.storage_class & STC.extern_)
            return Defined.notHere;
    if (isRootOwned(declaration, rootModules))
        return Defined.onlyHere;

    auto owner = function_ is null ? ownerOf(declaration)
        : Owner(contextOf(function_).outerFunction,
            contextOf(function_).instantiated);
    if (owner.outer !is null)
        return whereDefined(owner.outer, rootModules);
    if (function_ !is null && function_.isFuncLiteralDeclaration !is null)
        return Defined.hereAndPossiblyElsewhere;
    if (!owner.instantiated)
        return Defined.notHere;
    return function_ is null || backendExecutes(function_)
        ? Defined.hereAndPossiblyElsewhere : Defined.notHere;
}

private struct Owner {
    imported!"dmd.func".FuncDeclaration outer;
    bool instantiated;
}

// As `contextOf`, for a declaration that is not a function.
private Owner ownerOf(imported!"dmd.dsymbol".Dsymbol declaration) {
    import snakebite.frontend.lock: withCompilerQuery;
    import snakebite.memory.gc: insideFrontend;

    Owner owner() {
        return Owner(outerFunctionOf(declaration),
            declaration.isInstantiated !is null);
    }

    if (insideFrontend)
        return owner;

    Owner result;
    withCompilerQuery({ result = owner; });
    return result;
}

// Arena lifetime does not make parent links immutable. scopeCreateGlobal
// temporarily reparents a shared top-level package during semantic work.
// A thread inside the frontend already holds the lock, and a query would
// leave it: the answer would be kept in the GC, and a walk over thousands
// of declarations would grow that cache of the thread, outside the arena.
// It asks dmd, as the rest of the walk does.
public imported!"dmd.dmodule".Module moduleOf(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    import snakebite.frontend.lock: withCompilerQuery;
    import snakebite.memory.gc: insideFrontend;

    if (insideFrontend)
        return declaration.getModule;

    if (auto found = declaration in metadata.modules)
        return *found;

    imported!"dmd.dmodule".Module result;
    withCompilerQuery({
        result = declaration.getModule;
        if (result !is null)
            metadata.modules[declaration] = result;
    });
    return result;
}

// The pretty name `toPrettyChars` gives, walking the parent chain under the
// query lock once. The result outlives the lock; a thread keeps it for the
// declaration's lifetime. The string is a copy that the caller can keep.
public string prettyNameOf(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    import snakebite.frontend.lock: withCompilerQuery;
    import std.string: fromStringz;

    if (auto found = declaration in metadata.prettyNames)
        return *found;

    string result;
    withCompilerQuery({
        result = declaration.toPrettyChars.fromStringz.idup;
        metadata.prettyNames[declaration] = result;
    });
    return result;
}

public struct FunctionContext {
    public imported!"dmd.dmodule".Module module_;
    public imported!"dmd.func".FuncDeclaration outerFunction;
    public bool instantiated;
    public bool templateParent;
}

// The nearest enclosing function `symbol` (a captured variable or a nested
// function) is declared in, or `null` if it is declared at module scope -
// `toParent2` already walks past any block or `Catch` scope that is not a
// `Dsymbol` of its own, straight to the nearest enclosing function or
// aggregate. Shared because a captured variable's owner (`VarDeclaration.
// toParent2`) and a delegate's own target's parent (`FuncDeclaration.
// toParent2`, see `delegateTargetOf` in `delegates.d`) are both resolved the same way.
public imported!"dmd.func".FuncDeclaration outerFunctionOf(
    imported!"dmd.dsymbol".Dsymbol symbol,
) {
    auto parent = symbol.toParent2();
    while (parent !is null) {
        if (auto function_ = parent.isFuncDeclaration)
            return function_;
        // A module cannot nest in a function. Do not read package parents:
        // scopeCreateGlobal can change them during another module's semantic.
        if (parent.isModule !is null)
            return null;
        parent = parent.toParent2();
    }
    return null;
}

// Call selection keeps these answers, not a chain to traverse after unlock.
public FunctionContext contextOf(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import snakebite.frontend.lock: withCompilerQuery;

    if (auto found = function_ in metadata.contexts)
        return *found;

    FunctionContext result;
    withCompilerQuery({
        result.module_ = function_.getModule;
        result.outerFunction = outerFunctionOf(function_);
        result.instantiated = function_.isInstantiated !is null;
        const parent = function_.toParent;
        result.templateParent = parent !is null
            && parent.isTemplateInstance !is null;
        if (result.module_ !is null) {
            metadata.contexts[function_] = result;
            metadata.modules[function_] = result.module_;
        }
    });
    return result;
}

// Whether a backend can compile and execute the body of `function_`, nested
// functions and function literals in it included (ADR-0009, decision 1). The
// call selection, the call plans and the dependency image source all ask this
// one question, here, and the walk of the body runs once for a function and
// thread. A walk inside the frontend answers without keeping the result, as
// `moduleOf` does.
public bool backendExecutes(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import snakebite.frontend.lock: withCompilerQuery;
    import snakebite.language.call.selection: bodyIsExecutedByBackend;
    import snakebite.memory.gc: insideFrontend;

    if (insideFrontend)
        return bodyIsExecutedByBackend(function_);

    if (auto found = function_ in metadata.executed)
        return *found;

    bool result;
    withCompilerQuery({
        result = bodyIsExecutedByBackend(function_);
        metadata.executed[function_] = result;
    });
    return result;
}

// DMD temporarily reparents packages during semantic work. A snapshot taken
// under the query lock sees the settled owner. Each thread keeps that value
// for the declaration's lifetime, as call decisions already do, so unrelated
// semantic work cannot delay repeated runtime ownership queries.
private struct ThreadMetadata {
    size_t generation;
    imported!"dmd.dmodule".Module[imported!"dmd.dsymbol".Dsymbol] modules;
    FunctionContext[imported!"dmd.func".FuncDeclaration] contexts;
    string[imported!"dmd.dsymbol".Dsymbol] prettyNames;
    bool[imported!"dmd.func".FuncDeclaration] executed;
}

// Ordinary module storage is TLS in D; the maps need no shared lock.
private ThreadMetadata _metadata;

private ref ThreadMetadata metadata() {
    import snakebite.frontend.lock: metadataGeneration;

    const generation = metadataGeneration;
    if (_metadata.generation != generation)
        _metadata = ThreadMetadata(generation);
    return _metadata;
}

// `function_`'s type as the function type it must be. A `FuncDeclaration`
// whose type is not a `TypeFunction` would be a malformed AST, not a guest
// construct a backend has chosen not to support, so this halts on it as
// the internal error it is rather than reporting a refusal. `internalFailure()`
// rather than `assert(cond)`: the latter is elided by `-release`, leaving a
// null for the caller to dereference, and a silent null here is worse than
// a stop.
public imported!"dmd.mtype".TypeFunction typeFunctionOf(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    auto type = function_.type.isTypeFunction;
    if (type is null)
        internalFailure(text("`", function_.toString, "` has non-function type `",
                function_.type.toString, "`"));

    return type;
}

public imported!"dmd.mtype".TypeFunction typeFunctionOf(
    imported!"dmd.expression".CallExp expression,
) {
    import dmd.astenums: Tdelegate, Tpointer;
    import dmd.typesem: nextOf;
    import snakebite.frontend.typefacts: baseType;

    if (expression.f !is null)
        return typeFunctionOf(expression.f);
    auto type = expression.e1.type;
    if (type is null)
        return null;
    type = type.baseType;
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
// `__modtest` runs them. See `appendFromScope` for the scopes the search
// descends into.
public imported!"dmd.func".FuncDeclaration[] findUnittests(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.func: FuncDeclaration;

    FuncDeclaration[] unittests;
    appendUnittests(module_.members, unittests);
    return unittests;
}

// Every module constructor in `module_` that belongs to the root package.
// See `appendFromScope` for the scopes the search descends into. Shared
// constructors run before ordinary constructors, as druntime does.
public imported!"dmd.func".FuncDeclaration[] findModuleConstructors(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.func: FuncDeclaration;

    FuncDeclaration[] sharedCtors;
    FuncDeclaration[] ordinary;
    appendModuleConstructors(module_.members, sharedCtors, ordinary);
    return sharedCtors ~ ordinary;
}

// The module-level functions dmd's glue layer calls from a module's
// `ModuleInfo`, in declaration order, found in one walk the way
// `findModuleConstructors` finds the constructors and `findUnittests` the
// unit tests. A `@standalone` shared constructor is run by druntime before
// every other shared one, so it is kept apart.
public struct ModuleFunctions {
    imported!"dmd.func".FuncDeclaration[] independentConstructors;
    imported!"dmd.func".FuncDeclaration[] sharedConstructors;
    imported!"dmd.func".FuncDeclaration[] threadConstructors;
    imported!"dmd.func".FuncDeclaration[] sharedDestructors;
    imported!"dmd.func".FuncDeclaration[] threadDestructors;
    // The functions of `pragma(crt_constructor)` and
    // `pragma(crt_destructor)`, in declaration order.
    imported!"dmd.func".FuncDeclaration[] crtConstructors;
    imported!"dmd.func".FuncDeclaration[] crtDestructors;
    imported!"dmd.func".FuncDeclaration[] unittests;
}

public ModuleFunctions findModuleFunctions(
    imported!"dmd.dmodule".Module module_,
) {
    ModuleFunctions functions;
    appendFromScope(module_.members, (member) {
        if (appendUnittest(member, functions.unittests))
            return true;

        if (auto constructor = member.isSharedStaticCtorDeclaration) {
            if (constructor.standalone)
                functions.independentConstructors ~= constructor;
            else
                functions.sharedConstructors ~= constructor;
            return true;
        }

        if (auto constructor = member.isStaticCtorDeclaration) {
            functions.threadConstructors ~= constructor;
            return true;
        }

        if (auto destructor = member.isSharedStaticDtorDeclaration) {
            functions.sharedDestructors ~= destructor;
            return true;
        }

        if (auto destructor = member.isStaticDtorDeclaration) {
            functions.threadDestructors ~= destructor;
            return true;
        }

        if (auto function_ = member.isFuncDeclaration) {
            // A declaration with no body has nothing to run. One function can
            // have both pragmas, and then is in both lists.
            if (function_.fbody is null
                || !(function_.isCrtCtor || function_.isCrtDtor))
                return false;

            if (function_.isCrtCtor)
                functions.crtConstructors ~= function_;
            if (function_.isCrtDtor)
                functions.crtDestructors ~= function_;
            return true;
        }

        return false;
    });
    return functions;
}

private void appendModuleConstructors(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref imported!"dmd.func".FuncDeclaration[] sharedCtors,
    ref imported!"dmd.func".FuncDeclaration[] ordinary,
) {
    appendFromScope(symbols, (member) {
        if (auto constructor = member.isSharedStaticCtorDeclaration()) {
            sharedCtors ~= constructor;
            return true;
        }

        if (auto constructor = member.isStaticCtorDeclaration()) {
            ordinary ~= constructor;
            return true;
        }

        return false;
    });
}

private void appendUnittests(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref imported!"dmd.func".FuncDeclaration[] unittests,
) {
    appendFromScope(symbols, (member) => appendUnittest(member, unittests));
}

// Whether `member` is a unittest block, which is then a leaf of the walk.
private bool appendUnittest(
    imported!"dmd.dsymbol".Dsymbol member,
    ref imported!"dmd.func".FuncDeclaration[] unittests,
) {
    auto unittest_ = member.isUnitTestDeclaration;
    if (unittest_ is null)
        return false;

    // DMD's parser skips the unittest blocks of a non-root module but still
    // declares an empty placeholder for each one, so a scope's symbol count
    // does not depend on `-unittest`. An instance of a Phobos template in a
    // root module carries those placeholders. Compiled D never emits a
    // function without a body, so `__modtest` never calls one; neither does
    // this.
    if (unittest_.fbody !is null)
        unittests ~= unittest_;
    return true;
}

// This is the traversal every walk over a module's symbol tree needs. It
// finds the nested scopes that contribute compiled-in declarations.
// `action` runs on each member first. It returns true when it consumed the
// member as a leaf. A member `action` did not consume can still be a
// scope. Every walk descends into these scopes:
//   - an `AttribDeclaration` (`static:`, `version(...)`, ...). Its `.decl`
//     is the syntactic "then" branch. This holds even when the condition
//     resolved otherwise. `include` gives the branch a real build compiles
//     in;
//   - an aggregate's members. A `static this()`, `shared static this()` or
//     `unittest` declared inside a struct or class still belongs to the
//     enclosing module, not the aggregate. dmd's glue layer visits struct
//     and class members for the same reason (glue/toobj.d: "There might be
//     static ctors in the members"). The aggregate's own `this()` is a
//     distinct kind, `CtorDeclaration`. `action` never matches it by
//     descending here;
//   - a template mixin's members. `mixin decl!(...)` inlines `decl`'s body
//     into its own scope, so dmd's glue layer never gates it: it descends
//     into a `TemplateMixin` the same way it descends into any other scope
//     (glue/toobj.d, `visit(TemplateMixin)`), with no `needsCodegen()`
//     check;
//   - an instantiated template's members, when dmd would emit that
//     instance. These belong to the instance, not the uninstantiated
//     template. `needsCodegen()` tells apart an instance the build uses
//     from one dmd only checked speculatively, the same test dmd's glue
//     layer runs before it descends into an instance
//     (glue/toobj.d, `visit(TemplateInstance)`). A `TemplateMixin` also
//     matches `isTemplateInstance`, so this check comes after the mixin
//     check above, not instead of it;
//   - an `Nspace`'s (`extern(C++, ns) { ... }`) members. dmd's glue layer
//     visits its members for the same reason: it looks for static ctors
//     too (glue/toobj.d, `visit(Nspace ns)`).
private void appendFromScope(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    scope bool delegate(imported!"dmd.dsymbol".Dsymbol member) action,
) {
    if (symbols is null)
        return;

    foreach (member; *symbols) {
        if (action(member))
            continue;

        if (auto attributes = member.isAttribDeclaration()) {
            import dmd.dsymbolsem: include;

            appendFromScope(include(attributes, null), action);
            continue;
        }

        if (auto aggregate = member.isAggregateDeclaration()) {
            appendFromScope(aggregate.members, action);
            continue;
        }

        if (auto mixin_ = member.isTemplateMixin()) {
            appendFromScope(mixin_.members, action);
            continue;
        }

        if (auto instance = member.isTemplateInstance()) {
            import snakebite.frontend.declarationcollector: compilesIntoBuild;

            // See `appendFromScope` above for why this check is here.
            if (instance.compilesIntoBuild)
                appendFromScope(instance.members, action);
            continue;
        }

        if (auto namespace = member.isNspace())
            appendFromScope(namespace.members, action);
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
        // A failed speculative instance can remain after a gagged error.
        if (auto instance = member.isTemplateInstance) {
            if (instance.errors)
                continue;
            if (auto found = findFunction(instance.members, name))
                return found;
        }
    }

    return null;
}
