module snakebite.backends.interpreter.framelayout;


private:


// One guest function's frame layout: each parameter's byte offset, and
// the total size and alignment one activation of the function needs on
// the frame stack. A pure function of the declaration, so it is computed
// once per function and cached, never per call.
package struct FrameLayout {
    import snakebite.nativelayout: alignUp, TypeFacts;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;

    package size_t size;
    package uint alignment = 1;
    // Parallel to the function's parameter list, indexed positionally.
    // The argument-evaluation loop already has the positional index in
    // hand, so it never pays an AA hash lookup for the hottest path.
    package size_t[] offsets;
    // A parameter's facts, alongside its offset in `offsets` above and
    // decided at the same time, from the same `TypeFacts.of` call: the
    // argument-evaluation loop needs both to place a value, and a
    // parameter's type never changes between calls, so this is decided
    // once per function instead of once per call. For a `ref` parameter
    // these are a pointer's facts, not `parameter.type`'s - see `refs`.
    package TypeFacts[] offsetFacts;
    // Parallel to `offsets`/`offsetFacts`: whether that parameter is
    // `ref`, so the argument-evaluation loop knows, by position and
    // without a further lookup, whether to bind the argument's address
    // into the slot instead of evaluating its value there.
    package bool[] refs;
    // Keyed by declaration instead of position: `visit(VarExp)` resolves
    // a parameter read from a `VarDeclaration` it found by name lookup,
    // not by position, so it still needs a hash lookup. Reached only
    // through `offsetOf` below - never read or written directly outside
    // this module.
    private size_t[VarDeclaration] _offsetOf;
    // As `_offsetOf`, for whether that same variable is a `ref`
    // parameter - only ever populated for one, never for a local, so
    // `isRef` below answers `false` for anything else without having to
    // ask what kind of declaration it is. Reached only through `isRef`.
    private bool[VarDeclaration] _isRefOf;

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
        layout.offsetFacts.length = parameterList.length;
        layout.refs.length = parameterList.length;

        foreach (i; 0 .. parameterList.length) {
            auto parameter = parameterList[i];

            // `out` needs its own zero-before-call semantics on top of
            // the same pointer-slot shape `ref` gets below, and `lazy`
            // is a delegate, not a pointer at all - neither has a frame
            // layout this interpreter builds yet, so both still throw.
            if (parameter.storageClass & (STC.out_ | STC.lazy_))
                throw new Exception(
                    text("interpreter cannot pass `out`/`lazy` parameter ",
                        i, " of `", function_.toString, "` by value"),
                );

            const isRefParameter = (parameter.storageClass & STC.ref_) != 0;

            // A `ref` parameter occupies a pointer slot in a compiled
            // frame - the address of the argument's own storage, not a
            // copy of its value - so its facts are a pointer's, not
            // `parameter.type`'s.
            auto slot = isRefParameter
                ? layout.reserveSlot(
                    TypeFacts(size_t.sizeof, size_t.sizeof, false, false))
                : layout.reserveSlot(parameter.type);

            layout.offsets[i] = slot.offset;
            layout.offsetFacts[i] = slot.facts;
            layout.refs[i] = isRefParameter;

            if (variables !is null) {
                auto variable = (*variables)[i];
                layout._offsetOf[variable] = slot.offset;
                if (isRefParameter)
                    layout._isRefOf[variable] = true;
            }
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

    // One slot `reserveSlot` just reserved: its offset into the frame,
    // and the facts `TypeFacts.of` already had to compute to know how
    // big the slot was and how it had to be aligned - so a caller that
    // wants both, like a parameter's slot, gets them from the one call.
    package struct Slot {
        package size_t offset;
        package TypeFacts facts;
    }

    // Reserves one slot for a value of `type` and returns its offset and
    // facts. A parameter and a local differ in what they key the offset
    // by, not in how the frame grows to fit them, so both come here.
    private Slot reserveSlot(Type type) {
        return reserveSlot(TypeFacts.of(type));
    }

    // As above, for a caller that already knows the slot's facts rather
    // than a `Type` to derive them from - a `ref` parameter's slot is a
    // pointer's regardless of what it points to, so nothing about
    // `parameter.type` is involved in sizing it.
    private Slot reserveSlot(in TypeFacts facts) {
        const offset = alignUp(this.size, facts.alignment);
        this.size = offset + facts.size;
        if (facts.alignment > this.alignment)
            this.alignment = facts.alignment;

        return Slot(offset, facts);
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

    // Whether `variable` is a `ref` parameter: its own frame slot holds
    // the address of the argument's storage rather than the storage
    // itself, so `Evaluator.slotOf` - the one place every read, write and
    // address-of a variable goes through - reads through it once more
    // before handing back an address any of them can use directly.
    // `false` for anything this layout never marked as one, which covers
    // every local as well as a variable this layout never reserved a slot
    // for at all.
    package bool isRef(VarDeclaration variable) const {
        return (variable in _isRefOf) !is null;
    }
}

import dmd.visitor: Visitor;

// Decides which locals get a frame slot by walking the statement kinds a
// function body is built from: `CompoundStatement` and `ScopeStatement`
// because they only introduce scope, `ForStatement` and `IfStatement`
// because their branches run like any other statement, and `ExpStatement`
// is where a `long sum = 0;` local declaration itself is found. `ReturnStatement` and `ImportStatement` can
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
        CompoundStatement, ExpStatement, ForStatement, IfStatement,
        ImportStatement, ReturnStatement, ScopeStatement, Statement;

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

    // Both branches are walked even though at most one of them runs: this
    // layout is computed once for the whole body, before any condition is
    // known, and a local in the branch not taken this call is in the one
    // taken the next.
    override void visit(IfStatement statement) {
        if (statement.ifbody !is null)
            statement.ifbody.accept(this);

        if (statement.elsebody !is null)
            statement.elsebody.accept(this);
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

        // A `static` local is one variable per function, not one per call,
        // so a frame - popped on return - is the wrong storage for it.
        // `Evaluator` keeps it elsewhere; with no slot here, a reach that
        // looks in the frame instead is refused by `offsetOf` rather than
        // reading a variable reset on every call.
        if (variable.isDataseg)
            return;

        _layout._offsetOf[variable] = _layout.reserveSlot(variable.type).offset;
    }
}
