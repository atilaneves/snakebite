module snakebite.backends.layout;


private:


import snakebite.exception: SnakebiteException;

// One guest function's declared-storage layout: each parameter's byte
// offset, each local's byte offset, and the total size and alignment one
// activation of the function needs on a frame. A pure function of the
// declaration, so it is computed once per function and cached, never per
// call.
//
// Shared between backends (`package` here reaches every module under
// `snakebite.backends`, not just this one): a tree-walking interpreter and
// a bytecode compiler both need the same answer to "where does this
// parameter or local live in the frame" for a given declaration. What
// differs between them - the bytecode compiler's own temporary slots, for
// instance - is not this type's concern; a caller that needs those grows
// its own frame past `size` on top of what this type already reserved.
package struct FrameLayout {
    import snakebite.nativelayout: alignUp, TypeFacts;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;

    package size_t size;
    package uint alignment = 1;

    // One parameter's slot: its offset into the frame, the facts needed
    // to place a value there, and whether it is `ref` - decided together,
    // from the same `TypeFacts.of` call, since a parameter's type never
    // changes between calls. For a `ref` parameter, `facts` are a
    // pointer's, not the parameter's own type's: a `ref` parameter
    // occupies a pointer slot in a compiled frame, the address of the
    // argument's own storage rather than a copy of its value.
    package struct Parameter {
        package size_t offset;
        package TypeFacts facts;
        package bool isRef;
    }

    // Parallel to the function's parameter list, indexed positionally.
    // The argument-evaluation loop already has the positional index in
    // hand, so it never pays an AA hash lookup for the hottest path.
    package Parameter[] parameters;

    // A struct method's hidden `this`, together in one place: the slot
    // and the declaration that owns it always exist - or not - as a
    // pair. The hidden `this` is a `ref` parameter: its slot, before
    // the explicit parameters as in the native calling layout, holds
    // the receiver's address, the same shape every other `ref`
    // parameter's slot has above.
    package struct HiddenThis {
        package Parameter parameter;

        // dmd resolves a `this` the guest wrote to this same
        // declaration, but a constructor's implicit `return this;` is a
        // `ThisExp` dmd synthesises with no `var` at all, so the
        // evaluator reaches the slot through this instead for that
        // node. Null for a function with no `this`.
        package VarDeclaration variable;
    }
    package HiddenThis hiddenThis;

    // Keyed by declaration instead of position: `visit(VarExp)` resolves
    // a parameter or local read from a `VarDeclaration` it found by name
    // lookup, not by position, so it still needs a hash lookup. A `ref`
    // parameter or local occupies a pointer slot, which `Evaluator.slotOf`
    // reads through. Reached only through `offsetOf` and `isRef` below.
    private struct VariableSlot {
        size_t offset;
        bool isRef;
    }
    private VariableSlot[VarDeclaration] _slotOf;

    package static FrameLayout of(FuncDeclaration function_) {
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import dmd.astenums: STC;
        import std.conv: text;

        FrameLayout layout;

        if (function_.vthis !is null) {
            const isRefThis = (function_.vthis.storage_class & STC.ref_) != 0;
            auto slot = isRefThis
                ? layout.reserveSlot(
                    TypeFacts(size_t.sizeof, size_t.sizeof, false, false))
                : layout.reserveSlot(function_.vthis.type);

            layout.hiddenThis = HiddenThis(
                Parameter(slot.offset, slot.facts, isRefThis),
                function_.vthis,
            );
            layout._slotOf[function_.vthis] =
                VariableSlot(slot.offset, isRefThis);
        }

        // The parameter *types* are part of the function's own type, and
        // are there whether or not it has a body. `parameters` - the
        // declarations a body reads its arguments through - only exist
        // when there is a body to read them, so a body-less `extern(C)`
        // declaration still gets a frame laid out here, and simply has no
        // declaration to key `offsetOf` by.
        auto parameterList = typeFunctionOf(function_).parameterList;
        auto variables = function_.parameters;
        layout.parameters.length = parameterList.length;

        foreach (i; 0 .. parameterList.length) {
            auto parameter = parameterList[i];

            // `out` needs its own zero-before-call semantics on top of
            // the same pointer-slot shape `ref` gets below, and `lazy`
            // is a delegate, not a pointer at all - neither has a frame
            // layout this interpreter builds yet, so both still throw.
            if (parameter.storageClass & (STC.out_ | STC.lazy_))
                throw new SnakebiteException(
                    text("interpreter cannot pass `out`/`lazy` parameter ",
                        i, " of `", function_.toString, "` by value"),
                );

            const isRefParameter = (parameter.storageClass & STC.ref_) != 0;

            auto slot = isRefParameter
                ? layout.reserveSlot(
                    TypeFacts(size_t.sizeof, size_t.sizeof, false, false))
                : layout.reserveSlot(parameter.type);

            layout.parameters[i] =
                Parameter(slot.offset, slot.facts, isRefParameter);

            if (variables !is null) {
                auto variable = (*variables)[i];
                layout._slotOf[variable] =
                    VariableSlot(slot.offset, isRefParameter);
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
    // Whether `variable` has a slot in this layout at all - checked before
    // `offsetOf`/`isRef` by a reach that must tell "not here, try the
    // static chain" apart from "not here, and nowhere else either", which
    // `offsetOf`'s own throw cannot do without exceptions doing double
    // duty as control flow.
    package bool hasSlot(VarDeclaration variable) const {
        return (variable in _slotOf) !is null;
    }

    package size_t offsetOf(VarDeclaration variable) const {
        import std.conv: text;

        auto slot = variable in _slotOf;
        if (slot is null)
            throw new SnakebiteException(
                text("interpreter cannot reach `", variable.toString,
                    "`: not a parameter or local in the current frame"),
            );

        return slot.offset;
    }

    // Whether `variable` is a `ref` parameter or local: its own frame slot
    // holds the address of the referenced storage rather than the storage
    // itself, so `Evaluator.slotOf` - the one place every read, write and
    // address-of a variable goes through - reads through it once more before
    // handing back an address any of them can use directly. `false` for a
    // value variable or one this layout never reserved a slot for.
    package bool isRef(VarDeclaration variable) const {
        auto slot = variable in _slotOf;
        return slot !is null && slot.isRef;
    }
}

import dmd.visitor: Visitor;

// Decides which locals get a frame slot by walking the statement kinds a
// function body is built from: `CompoundStatement` and `ScopeStatement`
// because they only introduce scope, `ForStatement` and `IfStatement`
// because their branches run like any other statement, and `ExpStatement`
// is where a `long sum = 0;` local declaration itself is found.
// `ReturnStatement` is walked the same way `ExpStatement` is: dmd's own
// rvalue-AA-index lowering (`return aa[key];`) can leave a compiler
// temporary (`__aaget`, a `DeclarationExp` inside the returned
// expression's own `CommaExp`) there, the same shape `~=`'s lowering
// leaves inside an `ExpStatement`. `ImportStatement` still needs no walk:
// an `import` binds a name, never a nested declaration of its own.
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
    import dmd.expression: Expression;
    import dmd.statement:
        Catch, CompoundStatement, ExpStatement, ForStatement, IfStatement,
        ImportStatement, ReturnStatement, ScopeStatement, Statement,
        TryCatchStatement, TryFinallyStatement, UnrolledLoopStatement;

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
        if (statement.exp !is null)
            collectDeclarations(statement.exp);
    }

    override void visit(CompoundStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements)
            if (child !is null)
                child.accept(this);
    }

    override void visit(UnrolledLoopStatement statement) {
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

    // A catch variable is a local of its handler, so its slot is reserved
    // here with every other local: the layout is computed once for the
    // whole body, before any throw is known, the same reasoning as both
    // branches of an `if`. `Evaluator` only stores the caught object into
    // the already reserved slot at run time.
    override void visit(TryCatchStatement statement) {
        if (statement._body !is null)
            statement._body.accept(this);

        foreach (catch_; *statement.catches) {
            if (catch_.var !is null)
                collectCatchVariable(catch_);

            if (catch_.handler !is null)
                catch_.handler.accept(this);
        }
    }

    override void visit(TryFinallyStatement statement) {
        if (statement._body !is null)
            statement._body.accept(this);

        if (statement.finalbody !is null)
            statement.finalbody.accept(this);
    }

    private void collectCatchVariable(Catch catch_) {
        const slot = _layout.reserveSlot(catch_.var.type);
        _layout._slotOf[catch_.var] =
            FrameLayout.VariableSlot(slot.offset, false);
    }

    override void visit(ExpStatement statement) {
        if (statement.exp !is null)
            collectDeclarations(statement.exp);
    }

    // A declaration this collector needs to find is not always the whole
    // of a statement's expression, the way `long sum = 0;` is: dmd's own
    // `~=` lowering (`CatAssignExp.lowering`) can introduce a compiler
    // temporary - `__appendtmp*`, holding a right side too complex to
    // evaluate twice - as a `DeclarationExp` buried inside a `CommaExp`
    // chain, not the statement's own top-level expression. Walking into
    // both is what finds it: a `CommaExp` runs both of its operands, so a
    // declaration in either needs a slot the same as one at the top, and
    // `lowering` is where `Evaluator` itself goes looking for a `~=`'s
    // real work, so this follows it there too rather than missing
    // whatever `Evaluator` will actually run.
    private void collectDeclarations(Expression expression) {
        import dmd.expression: CatAssignExp;
        import snakebite.nativelayout: TypeFacts;

        if (auto declarationExp = expression.isDeclarationExp) {
            auto variable = declarationExp.declaration.isVarDeclaration;
            if (variable is null)
                return;

            // A `static` local is one variable per function, not one per
            // call, so a frame - popped on return - is the wrong storage
            // for it. `Evaluator` keeps it elsewhere; with no slot here,
            // a reach that looks in the frame instead is refused by
            // `offsetOf` rather than reading a variable reset on every
            // call.
            if (variable.isDataseg)
                return;

            import dmd.astenums: STC;

            const isRef = (variable.storage_class & STC.ref_) != 0;
            const slot = isRef
                ? _layout.reserveSlot(
                    TypeFacts(size_t.sizeof, size_t.sizeof, false, false))
                : _layout.reserveSlot(variable.type);
            _layout._slotOf[variable] =
                FrameLayout.VariableSlot(slot.offset, isRef);

            // DMD can place another compiler-generated declaration inside
            // this variable's initializer. The evaluator strips a
            // construct or blit wrapper and runs its right side, so collect
            // declarations from that same expression here.
            if (auto initializer = variable._init.isExpInitializer) {
                auto value = initializer.exp;
                if (auto construct = value.isConstructExp)
                    value = construct.e2;
                else if (auto blit = value.isBlitExp)
                    value = blit.e2;
                collectDeclarations(value);
            }
            return;
        }

        if (auto comma = expression.isCommaExp) {
            collectDeclarations(comma.e1);
            collectDeclarations(comma.e2);
            return;
        }

        if (auto call = expression.isCallExp) {
            collectDeclarations(call.e1);
            if (call.arguments !is null)
                foreach (argument; *call.arguments)
                    collectDeclarations(argument);
            return;
        }

        if (auto dot = expression.isDotVarExp) {
            collectDeclarations(dot.e1);
            return;
        }

        // dmd's rvalue-AA-index lowering (`lowerAAIndexRead` in
        // `expressionsem.d`) replaces `aa[key]` itself with
        // `IndexExp(CommaExp(__aaget declaration, ...), 0)` - the
        // `CommaExp` this recurses into through `e1` is where the
        // compiler temporary actually is; `e2` is a plain literal `0`
        // for that lowering, but a guest-written `arr[f()]` can put a
        // declaration in its own index expression too, so both sides are
        // walked the same way `~=`'s lowering chain already is above.
        if (auto index = expression.isIndexExp) {
            collectDeclarations(index.e1);
            collectDeclarations(index.e2);
            return;
        }

        // dmd's parser always builds a `CatAssignExp` for `~=`, then
        // semantic() narrows it in place to whichever of the two `final`
        // subclasses fits - `CatElemAssignExp` for appending one element
        // (`arr ~= x;`, the common case) or `CatDcharAssignExp` for a
        // `dchar` - and leaves it a plain `CatAssignExp` only for the
        // third case, appending a whole slice. `lowering` lives on the
        // base class, so all three carry it; matching only
        // `isCatAssignExp` here would miss the element and dchar cases,
        // which is where a compiler temp (`__appendtmp*`) actually
        // appears. Each `isXxxExp` compares `Expression.op` and hands
        // back a reference to `this` at its own static type - a widening
        // upcast to `CatAssignExp` from there is a plain pointer
        // conversion, not a class-to-class downcast, so it stays sound.
        CatAssignExp catAssign = expression.isCatAssignExp;
        if (catAssign is null)
            catAssign = expression.isCatElemAssignExp;
        if (catAssign is null)
            catAssign = expression.isCatDcharAssignExp;

        if (catAssign !is null && catAssign.lowering !is null)
            collectDeclarations(catAssign.lowering);
    }
}
