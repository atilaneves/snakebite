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
    import snakebite.backends.interpreter.framelayout: FrameLayout;
    import snakebite.framestack: FrameStack;
    import snakebite.ffi: PlanCache, maxArguments;
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import snakebite.nativelayout: storeValue, TypeFacts;
    import dmd.astenums: LINK, Tvoid;
    import dmd.expression:
        AddAssignExp, CallExp, CmpExp, DeclarationExp, Expression,
        IntegerExp, RealExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.init: ExpInitializer;
    import dmd.mtype: Type;
    import dmd.statement:
        CompoundStatement, ExpStatement, ForStatement, ImportStatement,
        ReturnStatement, ScopeStatement, Statement;
    import dmd.tokens: EXP;

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
    // Every dmd `Type` this evaluator has ever asked dmd about, keyed by
    // the `Type` node itself: `Type.size`/`alignsize`/`isIntegral`/
    // `isUnsigned` are pure functions of the type, re-entering dmd's
    // semantic-analysis machinery every call, so this asks each of them
    // once per distinct `Type` and every later visit of the same node
    // reads the answer back out instead. Not per-function like
    // `_layouts`: a `Type` such as `int` is dmd's own shared, interned
    // instance, so the same entry serves every function that mentions it.
    private TypeFacts[Type] _typeFacts;
    // The most recently asked-about `Type` and its facts: dmd interns
    // basic types, so a loop revisiting the same `int` node hits this
    // every time - a pointer compare instead of an AA hash lookup - and
    // only falls through to `_typeFacts` on an actual change of type.
    private Type _cachedType;
    private TypeFacts _cachedFacts;

    // The destination: while walking statements, the enclosing function's
    // return type and return place; `evaluate` narrows it to each
    // subexpression's own destination.
    private Type _type;
    // `_type`'s facts, narrowed alongside it by `evaluate` so a node
    // visiting its own destination type - the common case - reads `_facts`
    // directly instead of paying a `factsOf` lookup for a type it is
    // already sitting on.
    private TypeFacts _facts;
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

        _layouts[function_] = FrameLayout.of(function_);
        return function_ in _layouts;
    }

    // `type`'s facts, from the cache; computed on the first visit of any
    // node with this type. Returned by value, unlike `layoutOf`: a
    // `TypeFacts` is three small scalars, cheaper to copy than to chase a
    // pointer for, and nothing keeps a `TypeFacts` past the visit that
    // asked for it the way `_layout` outlives a whole call. `extern(D)`:
    // this class is `extern(C++)` for its `Visitor` overrides, and a
    // struct returned by value from a C++-linkage method is silently
    // corrupted - wrong values, no crash - since it does not use D's own
    // struct-return ABI. This method overrides nothing, so it is free to
    // opt back into D linkage.
    extern(D) private TypeFacts factsOf(Type type) {
        if (type is _cachedType)
            return _cachedFacts;

        if (auto cached = type in _typeFacts) {
            _cachedType = type;
            _cachedFacts = *cached;
            return _cachedFacts;
        }

        const facts = TypeFacts.of(type);
        _typeFacts[type] = facts;
        _cachedType = type;
        _cachedFacts = facts;
        return facts;
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
        auto savedFacts = _facts;
        auto savedPlace = _place;
        auto savedFrameBase = _frameBase;
        auto savedLayout = _layout;
        auto savedReturned = _returned;
        scope(exit) {
            _type = savedType;
            _facts = savedFacts;
            _place = savedPlace;
            _frameBase = savedFrameBase;
            _layout = savedLayout;
            _returned = savedReturned;
        }

        _type = function_.type.nextOf;
        _facts = factsOf(_type);
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
    // frame (see `LocalsCollector` in `framelayout`), so running it is
    // just running whatever it wraps, honouring `_returned` the same way
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

        // `_type`/`_facts` are already this function's return type and
        // its facts, set together on entry (`execute`) or by the last
        // `evaluate` - so both branches below hand them to `expression`
        // straight, with no fresh `factsOf` lookup.
        if (_place !is null) {
            evaluate(statement.exp, _type, _facts, _place);
            return;
        }

        // The caller discarded the result, but evaluating the expression
        // can have effects, so it still runs - into a reservation on the
        // frame stack, popped when it goes out of scope, not into a GC
        // allocation.
        auto frame = _frames.push(_facts.size, _facts.alignment);
        evaluate(statement.exp, _type, _facts, frame.base);
    }

    override void visit(ExpStatement statement) {
        if (statement.exp is null)
            return;

        runForEffect(statement.exp);
    }

    // Runs `expression` for its side effects, discarding whatever value it
    // produces: what an `ExpStatement` needs for its one expression, and
    // what a `ForStatement`'s `increment` needs too - dmd types `i++`/
    // `i += 1` no differently there than it would as a statement on its
    // own line, just with nowhere its result could go even if the
    // interpreter kept it.
    //
    // dmd hands this interpreter exactly one shape of a `void`-typed
    // expression so far: the call that a `void` function's `return f();`
    // desugars to, where `f()` is itself `void`. A `void` expression has
    // nowhere to write a result even if it had one, so this skips the
    // reservation outright rather than pushing dmd's one placeholder byte
    // for `Tvoid` (`Type.size` never returns zero) and evaluates straight
    // into a `null` place, the same convention `execute` already uses for
    // a discarded `void` return.
    private void runForEffect(Expression expression) {
        auto type = expression.type;
        if (type.ty == Tvoid) {
            evaluate(expression, type, null);
            return;
        }

        auto facts = factsOf(type);

        // The caller discarded the result, but evaluating the expression
        // can have effects, so it still runs. A destination this small
        // fits in a plain buffer on the host's own stack - reclaimed the
        // moment this returns, on every exit path, with no bump-allocator
        // bookkeeping and nothing to explicitly pop.
        if (facts.size <= 8 && facts.alignment <= 8) {
            align(8) ubyte[8] buffer = void;
            evaluate(expression, type, facts, buffer.ptr);
            return;
        }

        // A larger destination - a struct, say - still goes through the
        // frame stack, popped when it goes out of scope, not into a GC
        // allocation.
        auto frame = _frames.push(facts.size, facts.alignment);
        evaluate(expression, type, facts, frame.base);
    }

    override void visit(ForStatement statement) {
        while (statement.condition is null
                || integralValueOf(statement.condition) != 0) {
            if (statement._body !is null) {
                statement._body.accept(this);
                if (_returned)
                    return;
            }

            if (statement.increment !is null)
                runForEffect(statement.increment);
        }
    }

    // Evaluates `expression` and hands back its value. Every integral
    // type dmd hands the interpreter is 8 bytes or narrower, so the bytes
    // it is evaluated into fit a fixed buffer on the host's own stack -
    // reclaimed the moment this returns, no bump-allocator reservation
    // needed - because an expression is only ever evaluated into an
    // address and never handed back as a value, so anything that needs
    // the value itself, rather than a destination to leave it at, comes
    // here.
    private long integralValueOf(Expression expression) {
        return integralValueOf(expression, factsOf(expression.type));
    }

    // As above, but for a caller that already holds `expression.type`'s
    // facts - a `CmpExp` operand, whose facts its visit also needs for
    // signedness - so this does not pay a second `factsOf` lookup for the
    // same type.
    private long integralValueOf(Expression expression, in TypeFacts facts) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        auto type = expression.type;
        if (!facts.isIntegral)
            throw new Exception(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as an integral: its type is `", type.toString, "`"),
            );

        align(8) ubyte[8] buffer = void;
        evaluate(expression, type, facts, buffer.ptr);

        return loadIntegral(buffer.ptr, facts.size, !facts.isUnsigned);
    }

    override void visit(Expression expression) {
        import std.conv: text;

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toString, "`"),
        );
    }

    override void visit(IntegerExp expression) {
        storeValue(_type, _facts, expression, _place);
    }

    override void visit(RealExp expression) {
        storeValue(_type, _facts, expression, _place);
    }

    override void visit(VarExp expression) {
        import core.stdc.string: memcpy;

        // The slot already holds native bytes of the destination's exact
        // type (the variable's declared type), so this is a plain copy,
        // not a conversion - unlike a literal, which `storeValue` has
        // to convert from its dmd node first.
        memcpy(_place, slotOf(expression), _facts.size);
    }

    // Where a parameter or local read or written by `expression` lives in
    // the current frame. A read and a compound assignment differ in what
    // they do with the slot, not in how they find it, so both come here.
    private ubyte* slotOf(VarExp expression) {
        import std.conv: text;

        auto variable = expression.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(
                text("interpreter cannot reach `", expression.toString,
                    "`: not a parameter or local in the current frame"),
            );

        return _frameBase + _layout.offsetOf(variable);
    }

    // Runs a local's initializer into the frame slot `layoutOf` already
    // gave it. `long sum = 0;` is a `DeclarationExp` here.
    override void visit(DeclarationExp expression) {
        import std.conv: text;

        auto variable = expression.declaration.isVarDeclaration;
        if (variable is null)
            throw new Exception(
                text("interpreter cannot run declaration `",
                    expression.toString, "`: only a local variable is ",
                    "supported"),
            );

        const offset = _layout.offsetOf(variable);

        auto expInitializer = variable._init.isExpInitializer;
        if (expInitializer is null)
            throw new Exception(
                text("interpreter cannot run the initializer for `",
                    expression.toString, "`: only a plain expression ",
                    "initializer is supported"),
            );

        // dmd rewrites `long sum = 0;`'s initializer into a `ConstructExp`
        // (`sum = 0`); only `e2`, the actual value, needs evaluating.
        auto value = expInitializer.exp;
        if (auto construct = value.isConstructExp)
            value = construct.e2;

        evaluate(value, variable.type, _frameBase + offset);
    }

    // The target is looked up once, not once to read and again to write:
    // D evaluates the left side of a compound assignment a single time.
    override void visit(AddAssignExp expression) {
        import snakebite.nativelayout: loadIntegral, storeIntegral;
        import std.conv: text;

        auto variable = expression.e1.isVarExp;
        // dmd's semantic pass sets `exp.type = exp.e1.type` for every
        // `BinAssignExp` (`AddAssignExp` among them), so `_facts` -
        // `evaluate` already resolved for this node's own type - are
        // `expression.e1.type`'s facts too. One name for the one value,
        // used for both the target's slot and the write to `_place`; no
        // second `factsOf` lookup needed either way.
        auto facts = _facts;
        if (variable is null || !facts.isIntegral)
            throw new Exception(
                text("interpreter cannot add to `", expression.e1.toString,
                    "`: `", expression.toString, "`"),
            );

        auto target = slotOf(variable);
        const added = integralValueOf(expression.e2);
        const current = loadIntegral(target, facts.size, !facts.isUnsigned);
        const sum = cast(ulong) (current + added);

        storeIntegral(target, sum, facts.size);
        storeIntegral(_place, sum, facts.size);
    }

    // `<=`, `>` and `>=` arrive as this same node and are refused: nothing
    // needs them yet, and answering them with `<` would be a wrong answer
    // rather than a refusal.
    override void visit(CmpExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (expression.op != EXP.lessThan)
            throw new Exception(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        // `e1`'s facts, asked for once and handed to `integralValueOf`
        // below instead of let it ask again for the same type: this visit
        // also needs them itself, for signedness.
        auto e1Facts = factsOf(expression.e1.type);
        const a = integralValueOf(expression.e1, e1Facts);
        const b = integralValueOf(expression.e2);
        const less = e1Facts.isUnsigned
            ? cast(ulong) a < cast(ulong) b
            : a < b;

        // `expression` is the node `evaluate` was last called with, so
        // its type is `_type` and `_facts` is already its facts.
        storeIntegral(_place, less ? 1 : 0, _facts.size);
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
        // has the positional index `i`, so it indexes `offsets` and
        // `offsetFacts` directly instead of hashing a declaration through
        // `offsetOf` and a type through `factsOf` - a parameter's type
        // never changes between calls, so `offsetFacts[i]` is already its
        // facts.
        foreach (i; 0 .. parameterList.length)
            evaluate(
                (*arguments)[i],
                parameterList[i].type,
                layout.offsetFacts[i],
                frame.base + layout.offsets[i],
            );

        execute(function_, _place, frame.base, layout);
    }

    // Evaluates `expression` into `type.size` bytes at `place`, then
    // restores the surrounding destination.
    private void evaluate(Expression expression, Type type, void* place) {
        evaluate(expression, type, factsOf(type), place);
    }

    // As above, but for a caller that already holds `type`'s facts - from
    // a `FrameLayout` slot, or its own `factsOf` call a moment ago - so
    // this does not pay a second lookup for the same type.
    private void evaluate(
        Expression expression,
        Type type,
        in TypeFacts facts,
        void* place,
    ) {
        auto savedType = _type;
        auto savedFacts = _facts;
        auto savedPlace = _place;
        scope(exit) {
            _type = savedType;
            _facts = savedFacts;
            _place = savedPlace;
        }

        _type = type;
        _facts = facts;
        _place = place;
        expression.accept(this);
    }
}
