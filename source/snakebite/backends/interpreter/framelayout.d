module snakebite.backends.interpreter.framelayout;


private:


// One guest function's frame layout: each parameter's byte offset, and
// the total size and alignment one activation of the function needs on
// the frame stack. A pure function of the declaration, so it is computed
// once per function and cached, never per call.
package struct FrameLayout {
    import snakebite.backends.interpreter.alignment: alignUp;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;

    package size_t size;
    package uint alignment = 1;
    // Parallel to the function's parameter list, indexed positionally.
    // The argument-evaluation loop already has the positional index in
    // hand, so it never pays an AA hash lookup for the hottest path.
    package size_t[] offsets;
    // Keyed by declaration instead of position: `visit(VarExp)` resolves
    // a parameter read from a `VarDeclaration` it found by name lookup,
    // not by position, so it still needs a hash lookup.
    package size_t[VarDeclaration] offsetOf;

    package static FrameLayout of(FuncDeclaration function_) {
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import dmd.astenums: STC;
        import std.conv: text;

        FrameLayout layout;

        // The parameter *types* are part of the function's own type, and
        // are there whether or not it has a body. `parameters` - the
        // declarations a body reads its arguments through - only exist
        // when there is a body to read them, so a body-less `extern(C)`
        // declaration still gets a frame laid out here, and simply has no
        // declaration to key `offsetOf` by.
        auto parameterList = typeFunctionOf(function_).parameterList;
        auto variables = function_.parameters;
        layout.offsets.length = parameterList.length;

        foreach (i; 0 .. parameterList.length) {
            auto parameter = parameterList[i];

            // A `ref`/`out` parameter occupies a pointer slot in a
            // compiled frame, and `lazy` a delegate; `parameter.type`
            // is still the pointed-to/lazily-evaluated type either
            // way, so a value slot of that type's size would be the
            // wrong layout. Not supported, so this throws.
            if (parameter.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
                throw new Exception(
                    text("interpreter cannot pass `ref`/`out`/`lazy` ",
                        "parameter ", i, " of `", function_.toString,
                        "` by value"),
                );

            layout.offsets[i] = layout.reserveSlot(parameter.type);
            if (variables !is null)
                layout.offsetOf[(*variables)[i]] = layout.offsets[i];
        }

        // Locals share the same frame as the parameters: each one gets a
        // slot appended after whatever came before it, keyed by its own
        // `VarDeclaration` since `visit(VarExp)` looks up both kinds of
        // read the same way. A body-less declaration has no `fbody` to
        // walk, so this is a no-op for it, the same as the `variables is
        // null` case above.
        collectLocals(function_.fbody, layout);

        return layout;
    }

    // Reserves one slot for a value of `type` and returns its offset. A
    // parameter and a local differ in what they key the offset by, not in
    // how the frame grows to fit them, so both come here.
    private size_t reserveSlot(Type type) {
        import dmd.typesem: size;

        const alignment = type.alignsize;
        const offset = alignUp(this.size, alignment);
        this.size = offset + type.size;
        if (alignment > this.alignment)
            this.alignment = alignment;

        return offset;
    }
}

// Appends a frame slot for every local `statement` declares. Only
// statement lists and nested blocks are walked into, so a local declared
// anywhere else - a loop or conditional body - gets no slot, and running
// its declaration throws rather than writing to one that does not exist.
private void collectLocals(
    imported!"dmd.statement".Statement statement,
    ref FrameLayout layout,
) {
    if (statement is null)
        return;

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null)
            return;

        foreach (child; *compound.statements)
            collectLocals(child, layout);
        return;
    }

    if (auto scope_ = statement.isScopeStatement) {
        collectLocals(scope_.statement, layout);
        return;
    }

    auto expStatement = statement.isExpStatement;
    if (expStatement is null || expStatement.exp is null)
        return;

    auto declarationExp = expStatement.exp.isDeclarationExp;
    if (declarationExp is null)
        return;

    auto variable = declarationExp.declaration.isVarDeclaration;
    if (variable is null)
        return;

    layout.offsetOf[variable] = layout.reserveSlot(variable.type);
}
