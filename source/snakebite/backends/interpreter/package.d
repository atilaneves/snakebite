module snakebite.backends.interpreter;


private:


// Walks dmd's AST directly. The one invariant: a result is never boxed
// into a host-side representation - every expression is evaluated
// straight into a caller-designated native address, in native layout.
public final class Interpreter: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;

    // Each guest function's frame layout, computed once on that
    // function's first call (the cold path) and reused by every call
    // after it.
    private FrameLayout[FuncDeclaration] _layouts;
    // Every guest frame lives in this one buffer, bump-allocated by
    // `reserve` and popped on return. The buffer is fixed-capacity and
    // never reallocates, so a live frame's addresses never move.
    private ubyte[] _frameStack;
    private size_t _frameTop;

    public this() {
        _frameStack = new ubyte[1024 * 1024];
    }

    public override void call(
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
        const mark = _frameTop;
        scope(exit) _frameTop = mark;
        auto frameBase = reserve(layout.size, layout.alignment);

        scope evaluator = new Evaluator(this);
        evaluator.execute(function_, returnPlace, frameBase, layout);
    }

    public override string eval(FuncDeclaration function_) {
        throw new Exception(
            "eval not implemented for the interpreter yet",
        );
    }

    // `function_`'s frame layout, from the cache; computed on its first
    // call. The returned pointer aims into the cache and stays valid: AA
    // entries do not move.
    private const(FrameLayout)* layoutOf(FuncDeclaration function_) {
        if (auto cached = function_ in _layouts)
            return cached;

        import dmd.astenums: STC;
        import dmd.typesem: size;
        import std.conv: text;

        FrameLayout layout;
        auto parameters = function_.parameters;
        if (parameters !is null) {
            foreach (parameter; *parameters) {
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
                layout.offsetOf[parameter] = layout.size;
                layout.size += parameter.type.size;
                if (alignment > layout.alignment)
                    layout.alignment = alignment;
            }
        }

        _layouts[function_] = layout;
        return function_ in _layouts;
    }

    // Bump-allocates one frame (or scratch block) on the frame stack and
    // returns its base. The caller pops by restoring `_frameTop` to the
    // value it saved beforehand. No growth strategy yet: overflow throws.
    private ubyte* reserve(in size_t size, in uint alignment) {
        import std.conv: text;

        _frameTop = alignUp(_frameTop, alignment);
        if (_frameTop + size > _frameStack.length)
            throw new Exception(
                text("interpreter frame stack overflow: need ", size,
                    " byte(s) at offset ", _frameTop, " of ",
                    _frameStack.length),
            );

        auto base = _frameStack.ptr + _frameTop;
        _frameTop += size;
        return base;
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
    size_t[VarDeclaration] offsetOf;
}

import dmd.visitor: Visitor;

// The evaluation context: executes statements and evaluates expressions,
// always into the current destination (`_type` bytes at `_place`),
// resolving parameter reads against the currently executing function's
// frame. One class covers statement and expression nodes both, so the
// (type, place, frame) context lives in one spot instead of being copied
// between visitor types. Any node kind it does not know throws, naming
// the node, instead of silently doing nothing.
extern(C++) private final class Evaluator: Visitor {
    import dmd.astenums: Tvoid;
    import dmd.expression: CallExp, Expression, IntegerExp, RealExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: CompoundStatement, ReturnStatement, Statement;
    import dmd.typesem: size;

    alias visit = Visitor.visit;

    private Interpreter _interpreter;
    // The destination: while walking statements, the enclosing function's
    // return type and return place; `evaluate` narrows it to each
    // subexpression's own destination.
    private Type _type;
    private void* _place;
    // The currently executing function's frame.
    private ubyte* _frameBase;
    private const(FrameLayout)* _layout;

    this(Interpreter interpreter) {
        _interpreter = interpreter;
    }

    // Runs `function_`'s body with its frame already reserved at
    // `frameBase` - and its parameter slots already filled by the caller
    // - evaluating its `return` expression into `returnPlace`.
    final void execute(
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
        scope(exit) {
            _type = savedType;
            _place = savedPlace;
            _frameBase = savedFrameBase;
            _layout = savedLayout;
        }

        _type = function_.type.nextOf;
        _place = returnPlace;
        _frameBase = frameBase;
        _layout = layout;
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
            if (child !is null)
                child.accept(this);
        }
    }

    override void visit(ReturnStatement statement) {
        import std.conv: text;

        if (statement.exp is null)
            return;

        // A `void` function has no native destination for a `return`
        // expression to evaluate into; unimplemented, so it throws.
        if (_type.ty == Tvoid)
            throw new Exception(
                text("interpreter cannot evaluate a `void`-typed ",
                    "`return` expression: `", statement.exp.toString, "`"),
            );

        if (_place !is null) {
            evaluate(statement.exp, _type, _place);
            return;
        }

        // The caller discarded the result, but evaluating the expression
        // can have effects, so it still runs - into a reservation on the
        // frame stack, popped straight after, not into a GC allocation.
        const mark = _interpreter._frameTop;
        scope(exit) _interpreter._frameTop = mark;
        auto scratch = _interpreter.reserve(_type.size, _type.alignsize);
        evaluate(statement.exp, _type, scratch);
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

        auto layout = _interpreter.layoutOf(function_);

        auto arguments = expression.arguments;
        const argCount = arguments is null ? 0 : arguments.length;
        auto parameters = function_.parameters;
        const paramCount = parameters is null ? 0 : parameters.length;
        if (argCount != paramCount)
            throw new Exception(
                text("interpreter: `", function_.toString, "` expects ",
                    paramCount, " argument(s), got ", argCount),
            );

        const mark = _interpreter._frameTop;
        scope(exit) _interpreter._frameTop = mark;
        auto calleeBase =
            _interpreter.reserve(layout.size, layout.alignment);

        if (parameters !is null) {
            // Every argument is evaluated, even one the callee never
            // reads, since evaluating an argument can have effects.
            foreach (i, parameter; *parameters)
                evaluate(
                    (*arguments)[i],
                    parameter.type,
                    calleeBase + layout.offsetOf[parameter],
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

// Rounds `offset` up so a value of `alignment`'s natural alignment can
// start there. Delegates to dmd's own default field-alignment rule
// (`aggregate.alignmember`, the same one dmd uses to lay out a struct's
// fields) rather than reimplementing it.
private size_t alignUp(in size_t offset, in uint alignment) {
    import dmd.aggregate: alignmember;
    import dmd.astenums: structalign_t;

    structalign_t defaultAlignment;
    defaultAlignment.setDefault;

    return alignmember(defaultAlignment, alignment, cast(uint) offset);
}
