module snakebite.backends.interpreter;


private:


// Walks dmd's AST directly. The one invariant: a result is never boxed
// into a host-side representation - every expression is evaluated
// straight into a caller-designated native address, in native layout.
public final class Interpreter: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;

    // The one evaluator this backend ever creates: it owns the frame
    // stack and the per-function layout cache, both of which must
    // outlive any single call to stay warm across calls. `call` is a
    // thin adapter onto it.
    private Evaluator _evaluator;

    public this() {
        _evaluator = new Evaluator;
    }

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        _evaluator.call(function_, returnPlace, args);
    }

    public override string eval(FuncDeclaration function_) {
        throw new Exception(
            "eval not implemented for the interpreter yet",
        );
    }
}

// One guest function's frame layout: each parameter's byte offset, and
// the total size and alignment one activation of the function needs on
// the frame stack. A pure function of the declaration, so it is computed
// once per function and cached, never per call.
private struct FrameLayout {
    import dmd.declaration: VarDeclaration;

    size_t size;
    uint alignment = 1;
    // Parallel to the function's parameter list, indexed positionally.
    // The argument-evaluation loop already has the positional index in
    // hand, so it never pays an AA hash lookup for the hottest path.
    size_t[] offsets;
    // Keyed by declaration instead of position: `visit(VarExp)` resolves
    // a parameter read from a `VarDeclaration` it found by name lookup,
    // not by position, so it still needs a hash lookup.
    size_t[VarDeclaration] offsetOf;
}

// The frame stack every guest call reserves its parameter frame from,
// bump-allocated and popped LIFO. `push` is the only way to get bytes from
// it, and the `Frame` it returns is the only way to give them back: a
// call site never marks a position and pops back to it by hand, so it can
// never forget to, on a throw or any other path out of scope.
//
// Built on `std.experimental.allocator`'s `Region` building block, which
// supplies the fixed backing buffer, a bump pointer with a bounds check
// (overflow throws; no growth strategy yet), and a `deallocate` that frees
// exactly the block most recently handed out. That is all `Region`
// contributes: alignment above one byte is computed entirely by hand in
// `push`, below - `Region` is built with `minAlign = 1`, so it never
// rounds a request up on its own.
private struct FrameStack {
    import std.experimental.allocator.building_blocks.region: Region;
    import std.experimental.allocator.mallocator: Mallocator;

    // A byte position: how many bytes of the backing buffer were in use
    // at some earlier point. Never exposed outside this struct - `Frame`
    // is what a call site holds instead.
    private alias Mark = size_t;

    private Region!(Mallocator, 1) _region;
    private size_t _capacity;
    // The backing buffer's own base address, learned once at construction
    // (`allocateAll` hands back the whole buffer; `deallocate` immediately
    // frees it again, leaving the region as empty as a fresh one) since no
    // `Region` member exposes it directly. `popTo` needs it to build the
    // synthetic block it hands back to `Region.deallocate`.
    private ubyte* _base;

    public this(size_t capacity) {
        _capacity = capacity;
        _region = typeof(_region)(capacity);

        auto whole = _region.allocateAll;
        _base = cast(ubyte*) whole.ptr;
        const freed = _region.deallocate(whole);
        assert(freed, "could not reclaim the frame stack's own buffer");
    }

    private Mark mark() const {
        return _capacity - _region.available;
    }

    // One `push` reservation: `base` is where its bytes start, `null` for
    // a zero-size reservation nothing will dereference. Pops itself, back
    // to the mark it was pushed at, the moment it goes out of scope -
    // copying it would let two handles pop the same bytes, so it can only
    // be moved.
    public struct Frame {
        private FrameStack* _stack;
        private Mark _mark;
        public ubyte* base;

        @disable this(this);

        ~this() {
            if (_stack !is null)
                _stack.popTo(_mark);
        }
    }

    // Bump-allocates `size` bytes aligned to `alignment` and hands back a
    // handle that frees them again when it goes out of scope.
    public Frame push(in size_t size, in uint alignment) {
        import std.conv: text;

        const mark = this.mark;

        // `Region.allocate(0)` always returns `null` - it treats that as
        // a failed request, not a valid empty one - so a parameterless
        // function's zero-size frame would look like an overflow. There
        // is nothing to write into such a frame anyway, so this reserves
        // nothing for it and hands back a handle whose `base` no caller
        // will dereference.
        if (size == 0)
            return Frame(&this, mark, null);

        // The padding math below only lands a slot on its requested
        // alignment because the buffer's own base is aligned to at least
        // that much. `Mallocator` guarantees `platformAlignment`; a
        // request beyond that would be silently misaligned, so this
        // throws instead.
        if (alignment > Mallocator.alignment)
            throw new Exception(
                text("interpreter frame stack cannot honor a ", alignment,
                    "-byte alignment: the backing buffer is only aligned ",
                    "to ", Mallocator.alignment, " byte(s)"),
            );

        const alignedUsed = alignUp(mark, alignment);
        const padding = alignedUsed - mark;

        auto block = _region.allocate(padding + size);
        if (block is null)
            throw new Exception(
                text("interpreter frame stack overflow: need ", size,
                    " byte(s) at offset ", alignedUsed, " of ", _capacity),
            );

        return Frame(&this, mark, _base + alignedUsed);
    }

    // Frees every byte reserved since `mark`, in one `Region.deallocate`
    // call regardless of how many `push`es that covers - `Frame`'s
    // destructor is the only caller, and only ever with the mark it was
    // itself pushed at, so this always covers exactly the reservations
    // nested inside that one `Frame`, in the order they nested.
    private void popTo(in Mark mark) {
        const used = this.mark;
        // Nothing was reserved since `mark` - either this was a zero-size
        // reservation, or the reservations nested inside it already
        // popped themselves. `Region.deallocate` only accepts an empty
        // block when its pointer is `null`, and `_base + mark` is not
        // that, so this returns instead of handing it a block it would
        // reject.
        if (used == mark)
            return;

        auto block = _base[mark .. used];
        const popped = _region.deallocate(block);
        assert(popped, "frame stack popped out of LIFO order");
    }
}

import dmd.visitor: Visitor;

// The evaluation context: executes statements and evaluates expressions,
// always into the current destination (`_type` bytes at `_place`),
// resolving parameter reads against the currently executing function's
// frame. One class covers statement and expression nodes both, so the
// (type, place, frame) context lives in one spot instead of being copied
// between visitor types. Any node kind it does not know throws, naming
// the node, instead of silently doing nothing. It also owns the frame
// stack and the per-function layout cache: both need to outlive any one
// call to stay warm across calls, and this is the only place that ever
// walks a call's frames, so there is nothing left for a separate
// `Interpreter`-side cache to hold.
extern(C++) private final class Evaluator: Visitor {
    import snakebite.ffi: PlanCache, maxArguments;
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import dmd.astenums: LINK, STC, Tvoid;
    import dmd.expression:
        CallExp, DeclarationExp, Expression, IntegerExp, RealExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.init: ExpInitializer;
    import dmd.mtype: Type;
    import dmd.statement:
        CompoundStatement, ExpStatement, ImportStatement, ReturnStatement,
        ScopeStatement, Statement;
    import dmd.typesem: size;

    alias visit = Visitor.visit;

    // Every guest frame lives in this one frame stack, bump-allocated on
    // call and popped on return. Frames never move; overflow throws
    // loudly.
    private FrameStack _frames;
    // Each guest function's frame layout, computed once on that
    // function's first call (the cold path) and reused by every call
    // after it.
    private FrameLayout[FuncDeclaration] _layouts;
    // How to reach each already-compiled function this guest calls,
    // worked out on that function's first call and reused by every call
    // after it - the same cold-path-once shape as `_layouts`.
    private PlanCache _plans;

    // The destination: while walking statements, the enclosing function's
    // return type and return place; `evaluate` narrows it to each
    // subexpression's own destination.
    private Type _type;
    private void* _place;
    // The currently executing function's frame.
    private ubyte* _frameBase;
    private const(FrameLayout)* _layout;
    // Set by `visit(ReturnStatement)`; checked by `visit(CompoundStatement)`
    // to stop walking sibling statements once one has run. dmd accepts
    // unreachable statements after a `return` (it only warns with `-w`),
    // so without this flag a statement after `return` would still
    // execute and silently overwrite an already-computed result.
    private bool _returned;

    public this() {
        _frames = FrameStack(1024 * 1024);
    }

    // Runs `function_` against a fresh top-level frame, mirroring the
    // `Backend.call` contract: `returnPlace` is where the result goes
    // (`null` if the caller does not want it), `args` are host-to-guest
    // arguments (not yet supported). `extern(D)`: a dynamic array
    // parameter is not valid on an `extern(C++)` method, and this one is
    // never called from C++ - only `Visitor`'s `visit` overloads need
    // that linkage.
    extern(D) final void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        const parameterCount =
            function_.parameters is null ? 0 : function_.parameters.length;
        if (args.length != 0 || parameterCount != 0)
            throw new Exception(
                "host-to-guest arguments not yet supported by the " ~
                    "interpreter backend",
            );

        auto layout = layoutOf(function_);
        auto frame = _frames.push(layout.size, layout.alignment);

        execute(function_, returnPlace, frame.base, layout);
    }

    // `function_`'s frame layout, from the cache; computed on its first
    // call. The returned pointer aims into the cache and stays valid: AA
    // entries do not move.
    private const(FrameLayout)* layoutOf(FuncDeclaration function_) {
        if (auto cached = function_ in _layouts)
            return cached;

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

            const alignment = parameter.type.alignsize;
            layout.size = alignUp(layout.size, alignment);
            layout.offsets[i] = layout.size;
            if (variables !is null)
                layout.offsetOf[(*variables)[i]] = layout.size;
            layout.size += parameter.type.size;
            if (alignment > layout.alignment)
                layout.alignment = alignment;
        }

        // Locals share the same frame as the parameters: each one gets a
        // slot appended after whatever came before it, keyed by its own
        // `VarDeclaration` since `visit(VarExp)` looks up both kinds of
        // read the same way. A body-less declaration has no `fbody` to
        // walk, so this is a no-op for it, the same as the `variables is
        // null` case above.
        collectLocals(function_.fbody, layout);

        _layouts[function_] = layout;
        return function_ in _layouts;
    }

    // Runs `function_`'s body with its frame already reserved at
    // `frameBase` - and its parameter slots already filled by the caller
    // - evaluating its `return` expression into `returnPlace`. Every call
    // this backend ever makes, whether the host called in directly or a
    // guest `CallExp` reached it, passes through here exactly once, so
    // this is where a call unsafe to run gets rejected.
    private void execute(
        FuncDeclaration function_,
        void* returnPlace,
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        import std.conv: text;

        // `function_` being resolved only means a declaration was found;
        // it does not mean this call is safe to run directly. For
        // `obj.method(...)`, dmd sets the resolved declaration to the
        // statically known method even though the call needs `this` -
        // running it here would silently devirtualize it and drop the
        // context, and a nested function's static chain is dropped the
        // same way. A zero-parameter method or nested function has no
        // parameter to give it away either, so this check cannot be
        // folded into the parameter-count check below. Both are
        // unsupported constructs this interpreter has no representation
        // for, so this throws loudly instead of running with a missing
        // context and returning a plausible-looking wrong answer.
        if (function_.isThis() !is null || function_.isNested())
            throw new Exception(
                text("interpreter cannot call `", function_.toString,
                    "`: it needs a `this` or a static chain, which the ",
                    "interpreter does not provide"),
            );

        // A declaration with no body is not a program this interpreter can
        // walk: the body is machine code in a library the host process
        // already links. druntime is not reimplemented here, so calling
        // that code is how such a declaration runs.
        //
        // Only a non-D linkage, though. `extern(D)` has its own calling
        // convention, which the FFI does not implement, and a body-less
        // `extern(D)` declaration is more likely a function whose body
        // this interpreter simply never saw than one it should go looking
        // for in the process image.
        auto body_ = function_.fbody;
        if (body_ is null) {
            const linkage = function_.resolvedLinkage;
            if (linkage != LINK.d && linkage != LINK.default_) {
                const(void)*[maxArguments] slots;
                _plans.of(function_).call(
                    returnPlace, argumentSlots(slots, frameBase, layout));
                return;
            }

            throw new Exception(
                text("interpreter cannot call a function with no body: `",
                    function_.toString, "`"),
            );
        }

        auto savedType = _type;
        auto savedPlace = _place;
        auto savedFrameBase = _frameBase;
        auto savedLayout = _layout;
        auto savedReturned = _returned;
        scope(exit) {
            _type = savedType;
            _place = savedPlace;
            _frameBase = savedFrameBase;
            _layout = savedLayout;
            _returned = savedReturned;
        }

        _type = function_.type.nextOf;
        _place = returnPlace;
        _frameBase = frameBase;
        _layout = layout;
        _returned = false;
        body_.accept(this);
    }

    // Where each parameter's bytes sit in the frame the caller just
    // filled, in declaration order: what the FFI needs to hand them over,
    // built from the layout this interpreter already computed.
    //
    // Filled into the caller's own storage rather than a fresh array: this
    // runs on every call through the FFI, and the slots are read and done
    // with before the call returns, so there is nothing for an allocation
    // to outlive.
    extern(D) private const(void*)[] argumentSlots(
        return scope ref const(void)*[maxArguments] slots,
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        foreach (i, offset; layout.offsets)
            slots[i] = frameBase + offset;

        return slots[0 .. layout.offsets.length];
    }

    override void visit(Statement statement) {
        import std.conv: text;
        import std.string: fromStringz;
        import dmd.hdrgen: toChars;

        // `Statement` does not override the virtual `toChars()` that
        // `RootObject.toString()` calls, so `statement.toString()` hits
        // `RootObject`'s base implementation, `assert(0)`. Rendering
        // statements back to source text is instead a free function - and
        // it renders a statement as a line, trailing newline included, so
        // the message strips it to stay on one line.
        import std.string: strip;

        throw new Exception(
            text("interpreter cannot execute a `", statement.stmt,
                "` statement: `", toChars(statement).fromStringz.strip, "`"),
        );
    }

    // An `import` inside a function body binds names, and dmd's semantic
    // pass has already bound them: every `CallExp` this interpreter sees
    // arrives with its callee resolved. Nothing is left to execute, so
    // this runs no code rather than refusing the statement.
    override void visit(ImportStatement statement) {
    }

    override void visit(CompoundStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements) {
            if (child !is null) {
                child.accept(this);
                if (_returned)
                    return;
            }
        }
    }

    // `{ ... }` is a `ScopeStatement` wrapping the `CompoundStatement` (or
    // any other single statement) it braces - dmd gives every such block
    // its own scope this way, even one with no `if`/`while`/loop
    // introducing it. There is no separate scope to enter here: `layoutOf`
    // already gave every local inside it a slot in the function's one
    // frame (see `collectLocals` below), so running it is just running
    // whatever it wraps, honouring `_returned` the same way
    // `visit(CompoundStatement)` does for its own children.
    override void visit(ScopeStatement statement) {
        if (statement.statement is null)
            return;

        statement.statement.accept(this);
    }

    override void visit(ReturnStatement statement) {
        _returned = true;

        // `return f();` in a `void` function never reaches here with
        // `statement.exp` set to `f()`: dmd's own semantic pass desugars
        // it into `f(); return;` (an `ExpStatement` ahead of this now
        // exp-less `ReturnStatement`) before the interpreter ever sees
        // the body, precisely because a `void` return has no destination
        // to write into. `visit(ExpStatement)` is where that call runs.
        if (statement.exp is null)
            return;

        if (_place !is null) {
            evaluate(statement.exp, _type, _place);
            return;
        }

        // The caller discarded the result, but evaluating the expression
        // can have effects, so it still runs - into a reservation on the
        // frame stack, popped when it goes out of scope, not into a GC
        // allocation.
        auto frame = _frames.push(_type.size, _type.alignsize);
        evaluate(statement.exp, _type, frame.base);
    }

    override void visit(ExpStatement statement) {
        if (statement.exp is null)
            return;

        // A statement-position expression's value, if any, has no
        // destination - only its effects matter. dmd hands this
        // interpreter exactly one shape of it so far: the call that a
        // `void` function's `return f();` desugars to, where `f()` is
        // itself `void`. A `void` expression has nowhere to write a
        // result even if it had one, so this skips the reservation
        // outright rather than pushing dmd's one placeholder byte for
        // `Tvoid` (`Type.size` never returns zero) and evaluates straight
        // into a `null` place, the same convention `execute` already uses
        // for a discarded `void` return.
        auto type = statement.exp.type;
        if (type.ty == Tvoid) {
            evaluate(statement.exp, type, null);
            return;
        }

        // The caller discarded the result, but evaluating the expression
        // can have effects, so it still runs - into a reservation on the
        // frame stack, popped when it goes out of scope, not into a GC
        // allocation.
        auto frame = _frames.push(type.size, type.alignsize);
        evaluate(statement.exp, type, frame.base);
    }

    override void visit(Expression expression) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toString, "`"),
        );
    }

    override void visit(IntegerExp expression) {
        writeLiteral(_type, expression, _place);
    }

    override void visit(RealExp expression) {
        writeLiteral(_type, expression, _place);
    }

    override void visit(VarExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        auto variable = expression.var.isVarDeclaration;
        auto offset =
            variable is null ? null : variable in _layout.offsetOf;
        if (offset is null)
            throw new Exception(
                text("interpreter cannot read `", expression.toString,
                    "`: not a parameter in the current frame"),
            );

        // The slot already holds native bytes of the destination's exact
        // type (the parameter's declared type), so this is a plain copy,
        // not a conversion - unlike a literal, which `writeLiteral` has
        // to convert from its dmd node first.
        memcpy(_place, _frameBase + *offset, _type.size);
    }

    // `long sum = 0;` inside a function body is a `VarDeclaration` wrapped
    // in a `DeclarationExp`, which dmd's semantic pass hands back as the
    // sole expression of an `ExpStatement` - the same shape any local
    // declaration takes as a statement, so this is the only place a local
    // gets initialized. `layoutOf` already gave `variable` a slot in the
    // current frame; this only has to run its initializer expression into
    // that slot. dmd types a `DeclarationExp` itself `void` (there is no
    // value to hand a caller), so `visit(ExpStatement)` always reaches
    // this with `_place is null`, never mind that below.
    override void visit(DeclarationExp expression) {
        import std.conv: text;

        auto variable = expression.declaration.isVarDeclaration();
        if (variable is null)
            throw new Exception(
                text("interpreter cannot run declaration `",
                    expression.toString, "`: only a local variable is ",
                    "supported"),
            );

        auto offset = variable in _layout.offsetOf;
        if (offset is null)
            throw new Exception(
                text("interpreter cannot run declaration `",
                    expression.toString, "`: no frame slot was laid out ",
                    "for it"),
            );

        // No initializer at all (e.g. `long sum;`) leaves the slot as
        // whatever bytes were already there, matching a compiled frame's
        // uninitialized storage - nothing to run.
        if (variable._init is null)
            return;

        auto expInitializer = variable._init.isExpInitializer();
        if (expInitializer is null)
            throw new Exception(
                text("interpreter cannot run the initializer for `",
                    expression.toString, "`: only a plain expression ",
                    "initializer is supported"),
            );

        // dmd's semantic pass rewrites `long sum = 0;`'s initializer into
        // a `ConstructExp` (`sum = 0`, `e1` the just-declared `sum`, `e2`
        // the actual value) rather than handing back the bare value
        // expression - the same rewrite it uses for a plain assignment,
        // but tagged `construct` instead of `assign` since this is the
        // variable's first write, not a later one. Only `e2` is a
        // subexpression this interpreter has to evaluate: `e1` is `sum`
        // itself, already the destination `offset` names.
        auto value = expInitializer.exp;
        if (auto construct = value.isConstructExp())
            value = construct.e2;

        evaluate(value, variable.type, _frameBase + *offset);
    }

    // `expression.f` is already statically resolved (dmd resolves direct
    // calls during semantic analysis), so no name lookup or virtual
    // dispatch happens here. This caller reserves the callee's frame and
    // evaluates each argument expression straight into its slot - against
    // its own frame, since arguments are the caller's expressions - so
    // the callee starts with its frame ready-made and never builds one.
    // The callee's `return` value lands straight in `_place`, the same
    // destination this call itself was asked to evaluate into.
    override void visit(CallExp expression) {
        import std.conv: text;

        auto function_ = expression.f;
        if (function_ is null)
            throw new Exception(
                text("interpreter cannot call an unresolved function: `",
                    expression.toString, "`"),
            );

        // Whether this call needs a `this` or a static chain it cannot
        // provide is `execute`'s check, not this one - it runs there for
        // every call this backend makes, not only ones that arrive as a
        // guest `CallExp`.
        auto layout = layoutOf(function_);

        // The callee's parameter types, which a body-less declaration has
        // just as much as one with a body - unlike `parameters`, which
        // only a body has.
        auto parameterList = typeFunctionOf(function_).parameterList;
        auto arguments = expression.arguments;
        const argCount = arguments is null ? 0 : arguments.length;
        if (argCount != parameterList.length)
            throw new Exception(
                text("interpreter: `", function_.toString, "` expects ",
                    parameterList.length, " argument(s), got ", argCount),
            );

        auto frame = _frames.push(layout.size, layout.alignment);

        // Every argument is evaluated, even one the callee never reads,
        // since evaluating an argument can have effects. The loop already
        // has the positional index `i`, so it indexes `offsets` directly
        // instead of hashing a declaration through `offsetOf`.
        foreach (i; 0 .. parameterList.length)
            evaluate(
                (*arguments)[i],
                parameterList[i].type,
                frame.base + layout.offsets[i],
            );

        execute(function_, _place, frame.base, layout);
    }

    // Evaluates `expression` into `type.size` bytes at `place`, then
    // restores the surrounding destination.
    private void evaluate(Expression expression, Type type, void* place) {
        auto savedType = _type;
        auto savedPlace = _place;
        scope(exit) {
            _type = savedType;
            _place = savedPlace;
        }

        _type = type;
        _place = place;
        expression.accept(this);
    }
}

// Converts one dmd literal node (`IntegerExp`/`RealExp`) to native
// bytes: writes its value into `place` in native layout, exactly
// `type`'s size.
private void writeLiteral(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    import dmd.astenums: Tfloat32, Tfloat64;
    import dmd.typesem: size;
    import std.conv: text;

    if (type.ty == Tfloat32) {
        *cast(float*) place = cast(float) value.toReal;
        return;
    }

    if (type.ty == Tfloat64) {
        *cast(double*) place = cast(double) value.toReal;
        return;
    }

    if (type.isIntegral) {
        import snakebite.native: storeIntegral;

        storeIntegral(place, value.toInteger, type.size);
        return;
    }

    throw new Exception(
        text("interpreter cannot write a value of type `",
            type.toString, "`"),
    );
}

// Walks `statement` looking for a local variable declaration - dmd
// represents `long sum = 0;` as an `ExpStatement` whose sole expression is
// a `DeclarationExp` wrapping the `VarDeclaration` - and appends a frame
// slot for every one it finds, the same way the parameter loop in
// `layoutOf` appends one for every parameter. `CompoundStatement` and
// `ScopeStatement` are the only statement kinds walked into: a
// `CompoundStatement` is a statement list, and a `ScopeStatement` is the
// node dmd wraps every `{ ... }` block in (even one with no `if`/`while`
// introducing it), so a local declared inside a bare nested block still
// needs a slot in the same frame `visit(ScopeStatement)` runs it against.
// A declaration inside any other kind (a loop or conditional body, once
// those exist) will need this walk extended further to reach it.
private void collectLocals(
    imported!"dmd.statement".Statement statement,
    ref FrameLayout layout,
) {
    import dmd.typesem: size;

    if (statement is null)
        return;

    if (auto compound = statement.isCompoundStatement()) {
        if (compound.statements is null)
            return;

        foreach (child; *compound.statements)
            collectLocals(child, layout);
        return;
    }

    if (auto scope_ = statement.isScopeStatement()) {
        collectLocals(scope_.statement, layout);
        return;
    }

    auto expStatement = statement.isExpStatement();
    if (expStatement is null || expStatement.exp is null)
        return;

    auto declarationExp = expStatement.exp.isDeclarationExp();
    if (declarationExp is null)
        return;

    auto variable = declarationExp.declaration.isVarDeclaration();
    if (variable is null)
        return;

    const alignment = variable.type.alignsize;
    layout.size = alignUp(layout.size, alignment);
    layout.offsetOf[variable] = layout.size;
    layout.size += variable.type.size;
    if (alignment > layout.alignment)
        layout.alignment = alignment;
}

// dmd's default field-alignment rule (`aggregate.alignmember`, the same
// one it uses to lay out a struct's fields), rather than reimplementing
// it: no generic round-up-to-alignment helper exists anywhere else in the
// dmd frontend sources. Parameter frame offsets are ordinarily assigned
// far downstream of this, in dmd's machine-code backend, which this
// project does not use - laying out frames here is unavoidable, not a
// case of redoing work dmd already did for us at this stage.
//
// `alignmember` takes a `structalign_t` for cases with an explicit
// `align(N)`; there is none here, so `defaultAlignment` is always the
// type's own natural alignment - and it is built once at module load,
// not on every call, since this runs on every parameter offset and every
// frame stack push.
private imported!"dmd.astenums".structalign_t defaultAlignment;

shared static this() {
    defaultAlignment.setDefault;
}

private size_t alignUp(in size_t offset, in uint alignment) {
    import dmd.aggregate: alignmember;

    return alignmember(defaultAlignment, alignment, cast(uint) offset);
}
