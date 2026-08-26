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
// bump-allocated and popped LIFO. Built on `std.experimental.allocator`'s
// `Region` building block, which supplies the fixed backing buffer,
// alignment-respecting bump allocation, bounds checking (overflow throws;
// no growth strategy yet), and freeing of the one block it most recently
// handed out.
//
// `Region.deallocate` only ever frees that single last block, and neither
// it nor any other public member exposes or restores the bump position
// directly - `alignedAllocate` plus `deallocate` loses the alignment
// padding forever, since `deallocate` rewinds only to the aligned start
// it returned, not to the unaligned position before the padding. Reusing
// that lost padding on every future call would exhaust the fixed buffer
// over a long-running interpretation even though the frame stack is
// logically empty between calls. So this computes the padding itself
// (`available` is the only position `Region` exposes) and allocates
// padding and frame together as one block, which `popTo` hands whole
// back to `deallocate` - and remembers each pushed block on a small LIFO
// stack of its own, since popping back through several reservations to
// one mark needs to walk them off in that same order, one `Region`
// deallocation per reservation. `Region` was checked for this; no
// composition of it exposes an arbitrary-position restore, so this stays
// the thinnest wrapper that reclaims the padding and supports popping to
// an earlier mark.
private struct FrameStack {
    import std.experimental.allocator.building_blocks.region: Region;
    import std.experimental.allocator.mallocator: Mallocator;

    // How many reservations were live when the mark was taken; `popTo`
    // walks the reservation stack back down to this depth.
    public alias Mark = size_t;

    // `minAlign = 1`: every alignment is handled by hand above, so the
    // region must never round a request up on its own - that would make
    // the remembered block shorter than what `popTo` hands to
    // `deallocate`, and `deallocate` would then refuse it as not the
    // last-allocated block.
    private Region!(Mallocator, 1) _region;
    private size_t _capacity;
    private void[][] _pushed;

    public this(size_t capacity) {
        _capacity = capacity;
        _region = typeof(_region)(capacity);
    }

    public Mark mark() const {
        return _pushed.length;
    }

    // Bump-allocates `size` bytes aligned to `alignment` and returns its
    // base.
    public ubyte* push(in size_t size, in uint alignment) {
        import std.conv: text;

        // `Region.allocate(0)` always returns `null` - it treats that as
        // a failed request, not a valid empty one - so a parameterless
        // function's zero-size frame would look like an overflow. There
        // is nothing to write into such a frame anyway, so this reserves
        // and tracks nothing for it and returns a base no caller will
        // dereference.
        if (size == 0)
            return null;

        const used = _capacity - _region.available;
        const alignedUsed = alignUp(used, alignment);
        const padding = alignedUsed - used;

        auto block = _region.allocate(padding + size);
        if (block is null)
            throw new Exception(
                text("interpreter frame stack overflow: need ", size,
                    " byte(s) at offset ", alignedUsed, " of ", _capacity),
            );

        _pushed ~= block;
        return cast(ubyte*) block.ptr + padding;
    }

    // Pops every reservation pushed since `mark`, most recent first - the
    // only order `Region.deallocate` accepts.
    public void popTo(in Mark mark) {
        while (_pushed.length > mark) {
            const popped = _region.deallocate(_pushed[$ - 1]);
            assert(popped, "frame stack reservations popped out of order");
            _pushed = _pushed[0 .. $ - 1];
        }
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
    import dmd.astenums: STC;
    import dmd.expression: CallExp, Expression, IntegerExp, RealExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement:
        CompoundStatement, ExpStatement, ReturnStatement, Statement;
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
        const mark = _frames.mark;
        scope(exit) _frames.popTo(mark);
        auto frameBase = _frames.push(layout.size, layout.alignment);

        execute(function_, returnPlace, frameBase, layout);
    }

    // `function_`'s frame layout, from the cache; computed on its first
    // call. The returned pointer aims into the cache and stays valid: AA
    // entries do not move.
    private const(FrameLayout)* layoutOf(FuncDeclaration function_) {
        if (auto cached = function_ in _layouts)
            return cached;

        import std.conv: text;

        FrameLayout layout;
        auto parameters = function_.parameters;
        if (parameters !is null) {
            layout.offsets.length = parameters.length;
            foreach (i, parameter; *parameters) {
                // A `ref`/`out` parameter occupies a pointer slot in a
                // compiled frame, and `lazy` a delegate; `parameter.type`
                // is still the pointed-to/lazily-evaluated type either
                // way, so a value slot of that type's size would be the
                // wrong layout. Not supported, so this throws.
                if (parameter.storage_class &
                        (STC.ref_ | STC.out_ | STC.lazy_))
                    throw new Exception(
                        text("interpreter cannot pass `ref`/`out`/`lazy` ",
                            "parameter `", parameter.toString,
                            "` by value"),
                    );

                const alignment = parameter.type.alignsize;
                layout.size = alignUp(layout.size, alignment);
                layout.offsets[i] = layout.size;
                layout.offsetOf[parameter] = layout.size;
                layout.size += parameter.type.size;
                if (alignment > layout.alignment)
                    layout.alignment = alignment;
            }
        }

        _layouts[function_] = layout;
        return function_ in _layouts;
    }

    // Runs `function_`'s body with its frame already reserved at
    // `frameBase` - and its parameter slots already filled by the caller
    // - evaluating its `return` expression into `returnPlace`.
    private void execute(
        FuncDeclaration function_,
        void* returnPlace,
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        import std.conv: text;

        auto body_ = function_.fbody;
        if (body_ is null)
            throw new Exception(
                text("interpreter cannot call a function with no body: `",
                    function_.toString, "`"),
            );

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

    override void visit(Statement statement) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot execute a `", statement.stmt,
                "` statement: `", statement.toString, "`"),
        );
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
        // frame stack, popped straight after, not into a GC allocation.
        const mark = _frames.mark;
        scope(exit) _frames.popTo(mark);
        auto scratch = _frames.push(_type.size, _type.alignsize);
        evaluate(statement.exp, _type, scratch);
    }

    override void visit(ExpStatement statement) {
        if (statement.exp is null)
            return;

        // A statement-position expression's value, if any, has no
        // destination - only its effects matter. dmd hands this
        // interpreter exactly one shape of it so far: the call that a
        // `void` function's `return f();` desugars to, where `f()` is
        // itself `void` and there is nothing to reserve. The same
        // discard-into-a-scratch-reservation handling as a discarded
        // `return` covers a non-`void` expression the same way, since
        // `push` already treats a zero-size request as a no-op.
        auto type = statement.exp.type;
        const mark = _frames.mark;
        scope(exit) _frames.popTo(mark);
        auto scratch = _frames.push(type.size, type.alignsize);
        evaluate(statement.exp, type, scratch);
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

        // `expression.f` being resolved only means dmd found one
        // candidate declaration; it does not mean this call is safe to
        // run directly. For `obj.method(...)`, dmd still sets `f` to the
        // statically known method - running it here would silently
        // devirtualize a virtual call and drop `this`, and a nested
        // function's static chain is dropped the same way. Both are
        // unsupported constructs this interpreter has no representation
        // for, so this throws loudly instead of running with a missing
        // context and returning a plausible-looking wrong answer.
        if (function_.isThis() !is null || function_.isNested())
            throw new Exception(
                text("interpreter cannot call `", function_.toString,
                    "`: it needs a `this` or a static chain, which the ",
                    "interpreter does not provide"),
            );

        auto layout = layoutOf(function_);

        auto arguments = expression.arguments;
        const argCount = arguments is null ? 0 : arguments.length;
        auto parameters = function_.parameters;
        const paramCount = parameters is null ? 0 : parameters.length;
        if (argCount != paramCount)
            throw new Exception(
                text("interpreter: `", function_.toString, "` expects ",
                    paramCount, " argument(s), got ", argCount),
            );

        const mark = _frames.mark;
        scope(exit) _frames.popTo(mark);
        auto calleeBase = _frames.push(layout.size, layout.alignment);

        if (parameters !is null) {
            // Every argument is evaluated, even one the callee never
            // reads, since evaluating an argument can have effects. The
            // loop already has the positional index `i`, so it indexes
            // `offsets` directly instead of hashing `parameter` through
            // `offsetOf`.
            foreach (i, parameter; *parameters)
                evaluate(
                    (*arguments)[i],
                    parameter.type,
                    calleeBase + layout.offsets[i],
                );
        }

        execute(function_, _place, calleeBase, layout);
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
        const integer = value.toInteger;
        switch (type.size) {
            case 1: *cast(ubyte*) place = cast(ubyte) integer; return;
            case 2: *cast(ushort*) place = cast(ushort) integer; return;
            case 4: *cast(uint*) place = cast(uint) integer; return;
            case 8: *cast(ulong*) place = integer; return;
            default:
                throw new Exception(
                    text("interpreter cannot write an integral of size ",
                        type.size, ": `", type.toString, "`"),
                );
        }
    }

    throw new Exception(
        text("interpreter cannot write a value of type `",
            type.toString, "`"),
    );
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
