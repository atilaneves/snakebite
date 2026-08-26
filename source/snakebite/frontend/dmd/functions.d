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

// Every unittest in `module_`, in declaration order, as druntime's
// `__modtest` runs them: the ones nested in a struct or a class count too,
// so the search descends into aggregates as well as attributes.
public imported!"dmd.func".FuncDeclaration[] findUnittests(
    imported!"dmd.dmodule".Module module_,
) {
    imported!"dmd.func".FuncDeclaration[] unittests;
    appendUnittests(module_.members, unittests);
    return unittests;
}

private void appendUnittests(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref imported!"dmd.func".FuncDeclaration[] unittests,
) {
    if (symbols is null)
        return;

    foreach (member; *symbols) {
        if (auto unittest_ = member.isUnitTestDeclaration) {
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
    }

    return null;
}
