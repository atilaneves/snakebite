module snakebite.backends.interpreter.framelayout;


private:


// One guest function's frame layout: each parameter's byte offset, and
// the total size and alignment one activation of the function needs on
// the frame stack. A pure function of the declaration, so it is computed
// once per function and cached, never per call.
package struct FrameLayout {
    import snakebite.nativelayout: alignUp;
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
    // not by position, so it still needs a hash lookup. Reached only
    // through `offsetOf` below - never read or written directly outside
    // this module.
    private size_t[VarDeclaration] _offsetOf;

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
                layout._offsetOf[(*variables)[i]] = layout.offsets[i];
        }

        // Locals share the same frame as the parameters: each one gets a
        // slot appended after whatever came before it, keyed by its own
        // `VarDeclaration` since `visit(VarExp)` looks up both kinds of
        // read the same way. A body-less declaration has no `fbody` to
        // walk, so this is a no-op for it, the same as the `variables is
        // null` case above.
        if (function_.fbody !is null) {
            scope collector = new LocalsCollector(&layout);
            function_.fbody.accept(collector);
        }

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

    // Where `variable` lives in a frame built from this layout, as a byte
    // offset from the frame's base - the caller owns the frame's actual
    // address, so it is the one that turns this into a pointer. Throws,
    // naming `variable`, if this layout never reserved it a slot: the one
    // fault the evaluator can hit here, whether it is reading the
    // variable or running its declaration, so it gets the one message.
    package size_t offsetOf(VarDeclaration variable) const {
        import std.conv: text;

        auto offset = variable in _offsetOf;
        if (offset is null)
            throw new Exception(
                text("interpreter cannot reach `", variable.toString,
                    "`: not a parameter or local in the current frame"),
            );

        return *offset;
    }
}

import dmd.visitor: Visitor;

// Decides which locals get a frame slot by walking the statement kinds a
// function body is built from: `CompoundStatement` and `ScopeStatement`
// because they only introduce scope, `ForStatement` because its body runs
// like any other, and `ExpStatement` is where a `long sum = 0;` local
// declaration itself is found. `ReturnStatement` and `ImportStatement` can
// never contain a nested declaration of their own, so they are recognised
// and skipped rather than walked into.
//
// `visit(Statement)` is the fallback for any other kind, and it skips
// silently rather than throwing: this layout is computed once, eagerly,
// over the whole body, including statements dmd leaves in place but that
// never run - unreachable code after a `return`, or a loop body whose
// condition is never true. `Evaluator` only ever walks what actually
// executes, so a statement kind unrecognised here is either one
// `Evaluator` also refuses - and then `Evaluator.visit(Statement)` throws
// when it is reached, not before - or one that never runs at all, in
// which case refusing the whole function would be wrong. Any local
// declared directly inside a statement kind missing from this list
// simply gets no slot; if `Evaluator` ever learns to execute such a
// statement without this collector also learning to walk into it, the
// gap surfaces as `FrameLayout.offsetOf` failing to find that local, not
// as a wrong answer.
extern(C++) private final class LocalsCollector: Visitor {
    import dmd.statement:
        CompoundStatement, ExpStatement, ForStatement, ImportStatement,
        ReturnStatement, ScopeStatement, Statement;

    alias visit = Visitor.visit;

    private FrameLayout* _layout;

    public this(FrameLayout* layout) {
        _layout = layout;
    }

    override void visit(Statement statement) {
    }

    override void visit(ImportStatement statement) {
    }

    override void visit(ReturnStatement statement) {
    }

    override void visit(CompoundStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements)
            if (child !is null)
                child.accept(this);
    }

    override void visit(ScopeStatement statement) {
        if (statement.statement !is null)
            statement.statement.accept(this);
    }

    // dmd hoists a `for`'s own initialiser out into the enclosing
    // statement list before this interpreter ever sees the body, so only
    // the loop body itself is walked here - a local declared there runs
    // on every iteration, but it is the same one frame slot every time,
    // laid out once like any other local.
    override void visit(ForStatement statement) {
        if (statement._body !is null)
            statement._body.accept(this);
    }

    override void visit(ExpStatement statement) {
        if (statement.exp is null)
            return;

        auto declarationExp = statement.exp.isDeclarationExp;
        if (declarationExp is null)
            return;

        auto variable = declarationExp.declaration.isVarDeclaration;
        if (variable is null)
            return;

        _layout._offsetOf[variable] = _layout.reserveSlot(variable.type);
    }
}
