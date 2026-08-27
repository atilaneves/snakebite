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

    version(unittest)
    public size_t nameLookups() @safe @nogc nothrow pure const scope {
        return _evaluator.nameLookups();
    }

    version(unittest)
    public size_t typeLookups() @safe @nogc nothrow pure const scope {
        return _evaluator.typeLookups();
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
    import dmd.astenums: LINK, Tarray, Tnoreturn, Tpointer, Tvoid;
    import dmd.declaration: Declaration, VarDeclaration;
    import dmd.expression:
        AddAssignExp, AddExp, AddrExp, ArrayLengthExp, AndAssignExp, AndExp,
        AssertExp, AssignExp, BinAssignExp, BinExp, CallExp, CastExp, CmpExp,
        ComExp, CommaExp, CondExp, DeclarationExp, DivAssignExp, DivExp,
        EqualExp, Expression, IndexExp, IntegerExp, LogicalExp, MinAssignExp,
        MinExp, ModAssignExp, ModExp, MulAssignExp, MulExp, NegExp, NotExp,
        NullExp, OrAssignExp, OrExp, PostExp, PtrExp, RealExp, ShlAssignExp,
        ShlExp, ShrAssignExp, ShrExp, StringExp, SymOffExp, UnaExp,
        UshrAssignExp, UshrExp, VarExp, XorAssignExp, XorExp;
    import dmd.func: FuncDeclaration;
    import dmd.init: ExpInitializer;
    import dmd.mtype: Type;
    import dmd.statement:
        CompoundStatement, ExpStatement, ForStatement, IfStatement,
        ImportStatement, ReturnStatement, ScopeStatement, Statement;
    import dmd.tokens: EXP;

    alias visit = Visitor.visit;

    // Every guest frame lives in this one frame stack, bump-allocated on
    // call and popped on return. Frames never move; overflow throws
    // loudly.
    private FrameStack _frames;
    // Each guest function's frame layout, computed once on that
    // function's first call (the cold path) and reused by every call
    // after it.
    private Cache!(FuncDeclaration, FrameLayout) _layouts;
    // Storage for every data-segment variable the guest has reached so
    // far, keyed by its declaration. Such a variable is one variable per
    // program, not one per call, so a frame - popped on return - cannot
    // hold it. This outlives every call on this evaluator, which is the
    // guest state `Backend.call` promises persists across calls.
    private Cache!(VarDeclaration, ubyte[]) _statics;
    // dmd gives every `arr[... $ ...]` a `lengthVar` declaration for its
    // `$`, which no statement declares and which therefore has no frame
    // slot - and needs none, since the length is a value `visit(IndexExp)`
    // holds by the time it evaluates the index. This pairs that
    // declaration with that value so a `VarExp` naming it is answered
    // with it. `var` is null while no index is being evaluated.
    private static struct Dollar {
        VarDeclaration var;
        size_t length;
    }

    private Dollar _dollar;
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
    private Cache!(Type, TypeFacts) _typeFacts;
    // The most recently asked-about `Type` and its facts: dmd interns
    // basic types, so a loop revisiting the same `int` node hits this
    // every time - a pointer compare instead of an AA hash lookup - and
    // only falls through to `_typeFacts` on an actual change of type.
    private Type _cachedType;
    private TypeFacts _cachedFacts;
    // The hash lookups this evaluator makes through another type's
    // interface rather than through a `Cache` of its own: a frame
    // layout's `offsetOf`, and an FFI plan's `of`. Counted at the call
    // and by hand, so what is counted is what this evaluator asks for -
    // one query, one lookup. Whatever the callee does inside to answer is
    // its own, and is not counted here.
    version(unittest) private size_t _foreignNameLookups;

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
    // Whether the currently executing function returns `ref`, set by
    // `execute` from the function's own type. Checked by
    // `visit(ReturnStatement)`: a `ref` return's `_place` is the address a
    // `return` statement's lvalue names, not the value that lvalue holds,
    // so the two need different code, and this is what tells them apart.
    private bool _returnsRef;

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

    // Every hash lookup this evaluator has made to find where a name
    // lives: a variable's storage, or how to reach a called function.
    version(unittest)
    extern(D) final size_t nameLookups() @safe @nogc nothrow pure const scope {
        return _foreignNameLookups + _layouts.lookups + _statics.lookups;
    }

    // Every hash lookup this evaluator has made to find out what a `Type`
    // is - counted apart from the name lookups because the two regress
    // for unrelated reasons: a name lookup grows when the evaluator asks
    // a second question to find one variable, a type lookup when an
    // answer about a type stops being kept.
    version(unittest)
    extern(D) final size_t typeLookups() @safe @nogc nothrow pure const scope {
        return _typeFacts.lookups;
    }

    extern(D) private void countForeignNameLookup() @safe @nogc nothrow pure {
        version(unittest) ++_foreignNameLookups;
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
    // node with this type.
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
                countForeignNameLookup;
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
        auto savedReturnsRef = _returnsRef;
        scope(exit) {
            _type = savedType;
            _facts = savedFacts;
            _place = savedPlace;
            _frameBase = savedFrameBase;
            _layout = savedLayout;
            _returned = savedReturned;
            _returnsRef = savedReturnsRef;
        }

        _type = function_.type.nextOf;
        _facts = factsOf(_type);
        _place = returnPlace;
        _frameBase = frameBase;
        _layout = layout;
        _returned = false;
        _returnsRef = typeFunctionOf(function_).isRef;
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

        // A `ref` return hands the caller the address of `statement.exp`'s
        // storage, not a copy of its value - `_place` here is the small
        // scratch buffer `visit(CallExp)`/`refCallAddress` set up to hold
        // exactly that address, sized for a pointer regardless of what
        // `_facts.size` says the callee's own type is.
        if (_returnsRef) {
            import snakebite.nativelayout: storeIntegral;

            storeIntegral(
                _place, cast(size_t) addressOf(statement.exp), size_t.sizeof);
            return;
        }

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

    // Only the branch that runs is walked: the other one never executes,
    // so nothing in it is ever evaluated, not even to be discarded.
    override void visit(IfStatement statement) {
        auto taken = truthOf(statement.condition)
            ? statement.ifbody
            : statement.elsebody;

        if (taken !is null)
            taken.accept(this);
    }

    override void visit(ForStatement statement) {
        while (statement.condition is null || truthOf(statement.condition)) {
            if (statement._body !is null) {
                statement._body.accept(this);
                if (_returned)
                    return;
            }

            if (statement.increment !is null)
                runForEffect(statement.increment);
        }
    }

    private bool truthOf(Expression expression) {
        import std.conv: text;

        auto type = expression.type;
        const facts = factsOf(type);
        if (facts.isIntegral)
            return integralValueOf(expression, facts) != 0;

        // The pointer alone decides. dmd 2.112 and ldc2 1.42 disagree on
        // an array with a length but a null pointer - dmd calls it true,
        // ldc2 false - so that half is not something to assert as a
        // language rule. No guest program this interpreter can run builds
        // that value, so no test pins it either way; when one can, the
        // oracle the suite compares against settles it.
        if (type.ty == Tarray)
            return evaluateArray(expression, facts).elements !is null;

        throw new Exception(
            text("interpreter cannot evaluate `", expression.toString,
                "` as a condition: its type is `", type.toString, "`"),
        );
    }

    // A dynamic array's two fields, for a caller that reads them rather
    // than needing a destination to leave the whole value at. Reading them
    // out of the native layout happens here alone.
    private static struct ArrayValue {
        size_t length;
        ubyte* elements;
    }

    private ArrayValue evaluateArray(
        Expression expression,
        in TypeFacts facts,
    ) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, arrayValueSize,
            loadIntegral;
        import std.conv: text;

        auto type = expression.type;
        if (type.ty != Tarray)
            throw new Exception(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as a dynamic array: its type is `", type.toString,
                    "`"),
            );

        assert(facts.size == arrayValueSize && facts.alignment <= 8,
            "a dynamic array is not two words on this target");

        align(8) ubyte[arrayValueSize] value = void;
        evaluate(expression, type, facts, value.ptr);

        return ArrayValue(
            cast(size_t) loadIntegral(
                value.ptr + arrayLengthOffset, size_t.sizeof, false),
            *cast(ubyte**) (value.ptr + arrayPointerOffset),
        );
    }

    // Evaluates `expression` and hands back its value, for a caller that
    // needs the value itself rather than a destination to leave it at.
    private long integralValueOf(Expression expression) {
        return integralValueOf(expression, factsOf(expression.type));
    }

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
        assert(facts.size <= buffer.sizeof && facts.alignment <= buffer.alignof,
            "an integral wider than a register reached the scratch buffer");

        evaluate(expression, type, facts, buffer.ptr);

        return loadIntegral(buffer.ptr, facts.size, !facts.isUnsigned);
    }

    // As `integralValueOf`, for a pointer: `Type.isIntegral` is false for
    // `Tpointer` (a pointer is not an arithmetic type), so `integralValueOf`
    // itself refuses one. A dereference needs the address a pointer
    // expression evaluates to, not an integral value, hence the separate
    // path - though the bytes are read the same way either type is stored.
    private size_t pointerValueOf(Expression expression) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        auto type = expression.type;
        if (type.ty != Tpointer)
            throw new Exception(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as a pointer: its type is `", type.toString, "`"),
            );

        const facts = factsOf(type);
        align(8) ubyte[8] buffer = void;
        assert(facts.size <= buffer.sizeof && facts.alignment <= buffer.alignof,
            "a pointer wider than a register reached the scratch buffer");

        evaluate(expression, type, facts, buffer.ptr);

        return cast(size_t) loadIntegral(buffer.ptr, facts.size, false);
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

    override void visit(NullExp expression) {
        storeValue(_type, _facts, expression, _place);
    }

    override void visit(StringExp expression) {
        storeValue(_type, _facts, expression, _place);
    }

    override void visit(VarExp expression) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: storeIntegral;

        if (expression.var is _dollar.var) {
            storeIntegral(_place, _dollar.length, _facts.size);
            return;
        }

        // The slot already holds native bytes of the destination's exact
        // type (the variable's declared type), so this is a plain copy,
        // not a conversion - unlike a literal, which `storeValue` has
        // to convert from its dmd node first.
        memcpy(_place, slotOf(expression), _facts.size);
    }

    // Where the variable read or written by `expression` lives: the
    // current frame for a parameter or local, and storage of its own for
    // anything in the data segment. A read and a compound assignment
    // differ in what they do with the slot, not in how they find it, so
    // both come here.
    private ubyte* slotOf(VarExp expression) {
        return slotOf(expression, expression.var);
    }

    // As above, for a caller that already has the `Declaration` in hand
    // rather than a `VarExp` naming it - `SymOffExp`/`AddrExp` reach a
    // variable's storage the same way a read does, just to take its
    // address instead of copying its bytes, so this is the one place both
    // paths resolve a name to a slot. `original` is only for the error
    // message: it is the node the guest wrote, which may differ from
    // `declaration` itself (a `SymOffExp` names its variable directly, but
    // `original.toString` still renders the source expression).
    private ubyte* slotOf(Expression original, Declaration declaration) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        auto variable = declaration.isVarDeclaration;
        if (variable is null)
            throw new Exception(
                text("interpreter cannot reach `", original.toString,
                    "`: not a parameter or local in the current frame"),
            );

        if (variable.isDataseg)
            return staticSlotOf(variable);

        countForeignNameLookup;
        auto slot = _frameBase + _layout.offsetOf(variable);

        // A `ref` parameter's own slot holds the address of the
        // argument's storage, not the storage itself - reading through
        // it once more here, the one place every read, write and
        // address-of a variable resolves its slot, is what makes a
        // reach of the parameter reach the argument instead.
        if (_layout.isRef(variable))
            return cast(ubyte*) loadIntegral(slot, size_t.sizeof, false);

        return slot;
    }

    // Where `variable` lives outside any frame, created and initialised
    // the first time the guest reaches it and the same address for every
    // reach after that. Lazily rather than at layout time because the
    // initialiser is a compile-time constant - D requires one here - so
    // no guest code can observe the difference.
    extern(D) private ubyte* staticSlotOf(VarDeclaration variable) {
        import dmd.astenums: STC;
        import dmd.typesem: defaultInit;
        import std.conv: text;

        if (auto existing = variable in _statics)
            return existing.ptr;

        // An `extern` variable is defined elsewhere - in a library the
        // host already links, or in another object file. Storage made
        // here would be a second variable that only looks like it, so
        // this refuses rather than answering from a private copy.
        if (variable.storage_class & STC.extern_)
            throw new Exception(
                text("interpreter cannot reach `", variable.toString,
                    "`: it is `extern`, so its storage is not the ",
                    "interpreter's to make"),
            );

        // No initializer at all means the declaration left the variable at
        // its type's `.init`, which dmd renders as an expression like any
        // other - so both spellings reach `evaluate` the same way.
        Expression value;
        if (variable._init is null)
            value = defaultInit(variable.type, variable.loc);
        else if (auto expInitializer = variable._init.isExpInitializer)
            value = initializerValueOf(expInitializer);
        else
            throw new Exception(
                text("interpreter cannot initialize `", variable.toString,
                    "`: only a plain expression initializer is supported"),
            );

        // Over-allocated so the slot can start on the type's own
        // alignment: the guest reads and writes it in native layout, and
        // nothing in the GC's interface promises a block aligned for the
        // type that lands in it. Alignments are powers of two, so the
        // padding is the address masked into the block.
        const facts = factsOf(variable.type);
        auto block = new ubyte[facts.size + facts.alignment - 1];
        const start = -cast(size_t) block.ptr & (facts.alignment - 1);
        auto slot = block[start .. start + facts.size];

        // Registered only once the initialiser has run: a slot in
        // `_statics` means initialised, so a failed initialiser must not
        // leave one behind for a later reach to read as a value.
        evaluate(value, variable.type, facts, slot.ptr);
        _statics[variable] = slot;

        return slot.ptr;
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

        // A data-segment variable is initialised once, when the guest
        // first reaches it, not every time its declaration executes.
        if (variable.isDataseg)
            return;

        countForeignNameLookup;
        const offset = _layout.offsetOf(variable);

        auto expInitializer = variable._init.isExpInitializer;
        if (expInitializer is null)
            throw new Exception(
                text("interpreter cannot run the initializer for `",
                    expression.toString, "`: only a plain expression ",
                    "initializer is supported"),
            );

        evaluate(initializerValueOf(expInitializer), variable.type,
            _frameBase + offset);
    }

    // Assignment is an expression: it yields the value it assigned, so the
    // right side is evaluated straight into the target's slot and the
    // result is that slot's own bytes. `_facts` is the target's facts
    // here: dmd's semantic pass wraps an assignment feeding a wider
    // destination in a cast of its own, which is a node this interpreter
    // refuses rather than one it reaches this code with.
    override void visit(AssignExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        // `ConstructExp` and `BlitExp` arrive as this same node and are
        // refused: they fill storage that holds no value yet, where D
        // neither destroys nor copy-assigns over what was there, so
        // running them as a replacement would be a wrong answer rather
        // than a refusal.
        if (expression.op != EXP.assign)
            throw new Exception(
                text("interpreter cannot run a `", expression.op,
                    "` on `", expression.e1.toString, "`"),
            );

        // Naming `e1` rather than the whole expression: dmd lowers
        // `s.length = n` into a node whose `toString` is a bare `=`.
        auto target = addressOf(expression.e1);
        evaluate(expression.e2, _type, _facts, target);
        memcpy(_place, target, _facts.size);
    }

    // The address of the storage `target` names: a variable's own slot
    // (through a `ref` parameter's indirection, if it is one - see
    // `slotOf`), the address a pointer currently holds for `*p`, whichever
    // branch a `ref`-typed `cond ? a : b` took, or the address a `ref`-
    // returning call hands back. An assignment's left side and a `ref`
    // argument's binding both need exactly this - "where does this
    // lvalue live" - so both come here rather than each walking the same
    // handful of node kinds on their own.
    private void* addressOf(Expression target) {
        import std.conv: text;

        if (auto variable = target.isVarExp)
            return slotOf(variable);

        if (auto deref = target.isPtrExp)
            return cast(void*) pointerValueOf(deref.e1);

        // Only the branch taken is ever an lvalue this needs the address
        // of - the other one, like an `if`'s untaken branch, never runs,
        // so evaluating its address would be reaching into storage this
        // call was never given.
        if (auto cond = target.isCondExp)
            return addressOf(truthOf(cond.econd) ? cond.e1 : cond.e2);

        if (auto call = target.isCallExp)
            return refCallAddress(call);

        throw new Exception(
            text("interpreter cannot take the address of `",
                target.toString, "`: it is not an lvalue"),
        );
    }

    override void visit(AddAssignExp expression) {
        storeAssignExp!"+"(expression);
    }

    override void visit(MinAssignExp expression) {
        storeAssignExp!"-"(expression);
    }

    override void visit(MulAssignExp expression) {
        storeAssignExp!"*"(expression);
    }

    override void visit(DivAssignExp expression) {
        storeAssignExp!"/"(expression);
    }

    override void visit(ModAssignExp expression) {
        storeAssignExp!"%"(expression);
    }

    override void visit(AndAssignExp expression) {
        storeAssignExp!"&"(expression);
    }

    override void visit(OrAssignExp expression) {
        storeAssignExp!"|"(expression);
    }

    override void visit(XorAssignExp expression) {
        storeAssignExp!"^"(expression);
    }

    override void visit(ShlAssignExp expression) {
        storeAssignExp!"<<"(expression);
    }

    override void visit(ShrAssignExp expression) {
        storeAssignExp!">>"(expression);
    }

    override void visit(UshrAssignExp expression) {
        storeAssignExp!">>>"(expression);
    }

    // The target is looked up once, not once to read and again to write:
    // D evaluates the left side of a compound assignment a single time. The
    // right side runs before the target is read, since evaluating it can
    // change what the target holds.
    //
    // `extern(D)`: a string template parameter has no C++ mangling.
    private extern(D) void storeAssignExp(string op)(BinAssignExp expression) {
        import snakebite.nativelayout: loadIntegral, storeIntegral;
        import std.conv: text;

        auto variable = expression.e1.isVarExp;
        const targetFacts = factsOf(expression.e1.type);
        if (variable is null || !targetFacts.isIntegral)
            throw new Exception(
                text("interpreter cannot assign to `",
                    expression.e1.toString, "`: `", expression.toString,
                    "`"),
            );

        auto target = slotOf(variable);
        const stepFacts = factsOf(expression.e2.type);
        const step = integralValueOf(expression.e2, stepFacts);
        const current =
            loadIntegral(target, targetFacts.size, !targetFacts.isUnsigned);
        const result =
            combine!op(current, step, targetFacts, stepFacts, expression);

        storeIntegral(target, result, targetFacts.size);
        storeIntegral(
            _place,
            loadIntegral(target, targetFacts.size, !targetFacts.isUnsigned),
            _facts.size,
        );
    }

    override void visit(PostExp expression) {
        import snakebite.nativelayout: loadIntegral, storeIntegral;
        import std.conv: text;

        auto variable = expression.e1.isVarExp;
        const facts = factsOf(expression.e1.type);
        if (variable is null || !facts.isIntegral)
            throw new Exception(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: `", expression.e1.toString, "` is not an integral ",
                    "variable"),
            );

        auto target = slotOf(variable);
        const step = integralValueOf(expression.e2);
        const current = loadIntegral(target, facts.size, !facts.isUnsigned);
        const changed = expression.op == EXP.plusPlus
            ? current + step
            : current - step;

        storeIntegral(target, changed, facts.size);
        storeIntegral(_place, current, _facts.size);
    }

    override void visit(NotExp expression) {
        import snakebite.nativelayout: storeIntegral;

        storeIntegral(_place, truthOf(expression.e1) ? 0 : 1, _facts.size);
    }

    override void visit(CmpExp expression) {
        import std.conv: text;

        with (EXP) switch (expression.op) {
            case lessThan: return storeCmpExp!"<"(expression);
            case lessOrEqual: return storeCmpExp!"<="(expression);
            case greaterThan: return storeCmpExp!">"(expression);
            case greaterOrEqual: return storeCmpExp!">="(expression);
            default:
                throw new Exception(
                    text("interpreter cannot evaluate a `", expression.op,
                        "` expression: `", expression.toString, "`"),
                );
        }
    }

    // An ordering answers differently depending on how the operands were
    // read, so both are read with the signedness their own types give and
    // the comparison is then made in the one signedness they share.
    private extern(D) void storeCmpExp(string op)(CmpExp expression) {
        import snakebite.nativelayout: storeIntegral;

        const aFacts = factsOf(expression.e1.type);
        const bFacts = factsOf(expression.e2.type);
        const a = integralValueOf(expression.e1, aFacts);
        const b = integralValueOf(expression.e2, bFacts);
        const answer = sharedSignedness(aFacts, bFacts, expression)
            ? mixin("cast(ulong) a " ~ op ~ " cast(ulong) b")
            : mixin("a " ~ op ~ " b");

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    override void visit(LogicalExp expression) {
        import snakebite.nativelayout: storeIntegral;

        const left = integralValueOf(expression.e1) != 0;
        const answer = expression.op == EXP.andAnd
            ? left && integralValueOf(expression.e2) != 0
            : left || integralValueOf(expression.e2) != 0;

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    // Signedness does not change the answer here the way it does for `<`:
    // dmd's usual arithmetic conversions give both operands the same type,
    // so equal values have equal bit patterns either way.
    override void visit(EqualExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (expression.op != EXP.equal && expression.op != EXP.notEqual)
            throw new Exception(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        const a = integralValueOf(expression.e1);
        const b = integralValueOf(expression.e2);
        const answer = expression.op == EXP.equal ? a == b : a != b;

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    override void visit(AddExp expression) {
        storeBinaryExp!"+"(expression);
    }

    override void visit(MinExp expression) {
        storeBinaryExp!"-"(expression);
    }

    override void visit(MulExp expression) {
        storeBinaryExp!"*"(expression);
    }

    override void visit(DivExp expression) {
        storeBinaryExp!"/"(expression);
    }

    override void visit(ModExp expression) {
        storeBinaryExp!"%"(expression);
    }

    override void visit(AndExp expression) {
        storeBinaryExp!"&"(expression);
    }

    override void visit(OrExp expression) {
        storeBinaryExp!"|"(expression);
    }

    override void visit(XorExp expression) {
        storeBinaryExp!"^"(expression);
    }

    override void visit(ShlExp expression) {
        storeBinaryExp!"<<"(expression);
    }

    override void visit(ShrExp expression) {
        storeBinaryExp!">>"(expression);
    }

    override void visit(UshrExp expression) {
        storeBinaryExp!">>>"(expression);
    }

    override void visit(NegExp expression) {
        storeUnaryExp!"-"(expression);
    }

    override void visit(ComExp expression) {
        storeUnaryExp!"~"(expression);
    }

    // Each operand widens to 64 bits with the signedness its own type
    // gives, `combine` reduces the two to one 64-bit result, and the store
    // keeps only the bits the destination holds - which is what D promises
    // on overflow. The destination is as wide as the left operand because
    // any width change arrives as a `CastExp`, which the interpreter
    // refuses by name.
    //
    // `extern(D)`: a string template parameter has no C++ mangling.
    private extern(D) void storeBinaryExp(string op)(BinExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (!_facts.isIntegral)
            throw new Exception(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its type is `", expression.type.toString, "`"),
            );

        const aFacts = factsOf(expression.e1.type);
        const bFacts = factsOf(expression.e2.type);
        const a = integralValueOf(expression.e1, aFacts);
        const b = integralValueOf(expression.e2, bFacts);

        storeIntegral(
            _place, combine!op(a, b, aFacts, bFacts, expression), _facts.size);
    }

    // `-x` and `~x` leave the same low bits whether the operand was read as
    // signed or unsigned, so neither needs the operand's own facts.
    private extern(D) void storeUnaryExp(string op)(UnaExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (!_facts.isIntegral)
            throw new Exception(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its type is `", expression.type.toString, "`"),
            );

        const a = integralValueOf(expression.e1);

        storeIntegral(_place, cast(ulong) mixin(op ~ "a"), _facts.size);
    }

    // `integralValueOf` already sign- or zero-extends the operand to 64
    // bits per its own signedness, so storing the destination's low bytes
    // of that value is correct whichever way the width changes - the same
    // widen-then-truncate the `combine`d binary operators already rely on,
    // just with the two types differing instead of matching. A pointer
    // cast reinterprets the same bits at their native width instead: a
    // pointer's representation does not depend on its pointee, so no
    // conversion is needed, only a copy. Anything else this node could
    // mean - floating point, a class downcast, array reinterpretation - is
    // refused the same way an unhandled node already is.
    override void visit(CastExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        auto sourceType = expression.e1.type;

        if (sourceType.ty == Tpointer && _type.ty == Tpointer) {
            evaluate(expression.e1, sourceType, factsOf(sourceType), _place);
            return;
        }

        const sourceFacts = factsOf(sourceType);
        if (sourceFacts.isIntegral && _facts.isIntegral) {
            storeIntegral(
                _place,
                integralValueOf(expression.e1, sourceFacts),
                _facts.size,
            );
            return;
        }

        throw new Exception(
            text("interpreter cannot evaluate a `", expression.op,
                "` expression: `", expression.toString, "`"),
        );
    }

    // dmd folds `&variable` into this node directly rather than wrapping
    // it in an `AddrExp` - `offset` is normally zero, but exists for `&`
    // of a field reached through a pointer, which is out of scope here. A
    // frame slot's address is a real machine address for the life of the
    // frame - the frame stack never moves what it has already handed
    // out - so this is just that address, stored as a `size_t` the same
    // way any other pointer value is.
    override void visit(SymOffExp expression) {
        import snakebite.nativelayout: storeIntegral;

        const address =
            cast(size_t) slotOf(expression, expression.var) + expression.offset;
        storeIntegral(_place, address, _facts.size);
    }

    // The general `&expression` node, reached for an lvalue too complex to
    // fold straight into a `SymOffExp` - a variable is the only lvalue the
    // tests exercising this need, so anything else is refused the same way
    // an unhandled node already is.
    override void visit(AddrExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        auto variable = expression.e1.isVarExp;
        if (variable is null)
            throw new Exception(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        storeIntegral(_place, cast(size_t) slotOf(variable), _facts.size);
    }

    // `*p`: the address `p` evaluates to is not this expression's own
    // destination - `_place`/`_facts` here are the pointee's, `int` for an
    // `int*` - so the pointer itself is read into a scratch register first
    // (`pointerValueOf`), the same two-step `assignmentTargetOf` uses to
    // find where `*p = ...` writes.
    override void visit(PtrExp expression) {
        import core.stdc.string: memcpy;

        memcpy(_place, cast(void*) pointerValueOf(expression.e1), _facts.size);
    }

    // Only the branch the condition selects is evaluated, the same way
    // `if` only walks the branch it takes: D specifies the other one
    // never runs, so nothing in it can have an effect.
    override void visit(CondExp expression) {
        auto taken = truthOf(expression.econd)
            ? expression.e1
            : expression.e2;

        evaluate(taken, _type, _facts, _place);
    }

    // An assertion is a statement's whole expression, so it arrives via
    // `visit(ExpStatement)` -> `runForEffect` with nowhere to leave a
    // value: a passing assertion produces nothing, it only has to let the
    // walk continue.
    //
    // dmd gives `assert(0)`/`assert(false)` the type `noreturn` because
    // the spec makes it a halt rather than an assertion - it stays in the
    // program under `-release`, where every other assertion is gone. A
    // halt is not something this backend can produce, so it is refused by
    // name instead of being answered with the ordinary failure below,
    // which would be a different thing wearing the same words.
    override void visit(AssertExp expression) {
        import std.conv: text;

        if (expression.type !is null && expression.type.ty == Tnoreturn)
            throw new Exception(
                text("interpreter cannot execute the halt `",
                    expression.toString, "`"),
            );

        if (truthOf(expression.e1))
            return;

        // What D does here is throw an `AssertError` the guest can catch,
        // and the interpreter has no guest exceptions yet. Reporting the
        // failure to the host is the honest half of that: the assertion
        // is not passed over, and no guest-visible exception is faked.
        throw new Exception(
            text("interpreter: assertion failed: `", expression.toString,
                "`"),
        );
    }

    override void visit(ArrayLengthExp expression) {
        import snakebite.nativelayout: storeIntegral;

        auto array = expression.e1;
        const value = evaluateArray(array, factsOf(array.type));

        storeIntegral(_place, value.length, _facts.size);
    }

    // The array is evaluated before the index, the order D specifies.
    override void visit(IndexExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        auto array = expression.e1;
        const value = evaluateArray(array, factsOf(array.type));
        const index = indexOf(expression, value.length);

        // Compiled D throws a `RangeError` here, which needs guest
        // exceptions this interpreter does not have. The alternative is
        // not "no check": an unchecked read hands back a byte of the
        // host's own memory as a guest value, or faults the host process
        // outright, so this refuses instead.
        if (index < 0 || cast(size_t) index >= value.length)
            throw new Exception(
                text("interpreter cannot index `", array.toString,
                    "` at ", index, ": the array is ", value.length,
                    " long"),
            );

        // The array's own element width, not the destination's: they
        // agree only because dmd wraps this in a `CastExp` for any change
        // of width, and `cast` is refused.
        const stride = factsOf(array.type.nextOf).size;
        assert(stride == _facts.size, "an index changed width");

        memcpy(_place, value.elements + index * stride, stride);
    }

    private long indexOf(IndexExp expression, in size_t length) {
        auto lengthVar = expression.lengthVar;
        if (lengthVar is null)
            return integralValueOf(expression.e2);

        // An index nested in this one - or one a guest call from here
        // reaches - binds its own `$`, so this one's is put back rather
        // than cleared. `auto`, not `const`: a `const` copy of a struct
        // holding a reference cannot be assigned back.
        auto outer = _dollar;
        scope(exit) _dollar = outer;
        _dollar = Dollar(lengthVar, length);

        return integralValueOf(expression.e2);
    }

    override void visit(CommaExp expression) {
        runForEffect(expression.e1);
        expression.e2.accept(this);
    }

    // `expression.f` is already statically resolved (dmd resolves direct
    // calls during semantic analysis), so no name lookup or virtual
    // dispatch happens here. This caller reserves the callee's frame and
    // binds each argument into its slot - against its own frame, since
    // arguments are the caller's expressions - so the callee starts with
    // its frame ready-made and never builds one.
    //
    // A callee that returns `ref` hands back an address, not a value - the
    // caller reads through it here rather than everywhere a call result is
    // used, so this is the one place a `ref`-returning call is told apart
    // from an ordinary one when its value, not its address, is wanted (see
    // `addressOf` for the other one).
    override void visit(CallExp expression) {
        import core.stdc.string: memcpy;
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
        auto frame = bindFrame(expression, function_, layout);

        if (typeFunctionOf(function_).isRef) {
            memcpy(
                _place, resolvedRefAddress(function_, frame.base, layout),
                _facts.size);
            return;
        }

        execute(function_, _place, frame.base, layout);
    }

    // Reserves `function_`'s frame and binds every argument into it: a
    // `ref` parameter's slot gets the argument's address (`addressOf`),
    // everything else gets its value (`evaluate`), exactly as a compiled
    // frame would be filled. Shared between an ordinary call and one only
    // wanted for the address a `ref` return hands back (`refCallAddress`),
    // since both fill a frame the same way and differ only in what they
    // do with the callee once it has run.
    private FrameStack.Frame bindFrame(
        CallExp expression,
        FuncDeclaration function_,
        const(FrameLayout)* layout,
    ) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

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
        // has the positional index `i`, so it indexes `offsets`,
        // `offsetFacts` and `refs` directly instead of hashing a
        // declaration through `offsetOf` and a type through `factsOf` - a
        // parameter's type never changes between calls, so
        // `offsetFacts[i]` is already its facts.
        foreach (i; 0 .. parameterList.length) {
            auto argument = (*arguments)[i];
            auto slot = frame.base + layout.offsets[i];

            if (layout.refs[i])
                storeIntegral(
                    slot, cast(size_t) addressOf(argument), size_t.sizeof);
            else
                evaluate(
                    argument, parameterList[i].type, layout.offsetFacts[i],
                    slot);
        }

        return frame;
    }

    // Runs a `ref`-returning `function_` to completion and reads back the
    // address its `return` statement named: `execute` writes that address,
    // as a pointer, into a scratch buffer sized for exactly that,
    // regardless of what the callee's own return type's facts say.
    private void* resolvedRefAddress(
        FuncDeclaration function_,
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        import snakebite.nativelayout: loadIntegral;

        align(8) ubyte[8] resultAddress = void;
        execute(function_, resultAddress.ptr, frameBase, layout);
        return cast(void*)
            loadIntegral(resultAddress.ptr, size_t.sizeof, false);
    }

    // The address a `ref`-returning call hands back, for `addressOf` when
    // the call itself is the lvalue - `pick(a, b, true) = 5;`'s left side,
    // or a `ref` argument bound to another call's `ref` result. dmd only
    // ever types-checks a call as an lvalue when it does return `ref`, so
    // the check below is a defence against this interpreter reaching this
    // path some other way, not a guest mistake any test here can trigger.
    private void* refCallAddress(CallExp expression) {
        import std.conv: text;

        auto function_ = expression.f;
        if (function_ is null)
            throw new Exception(
                text("interpreter cannot call an unresolved function: `",
                    expression.toString, "`"),
            );

        if (!typeFunctionOf(function_).isRef)
            throw new Exception(
                text("interpreter cannot take the address of `",
                    expression.toString, "`: it does not return `ref`"),
            );

        auto layout = layoutOf(function_);
        auto frame = bindFrame(expression, function_, layout);
        return resolvedRefAddress(function_, frame.base, layout);
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

private ulong combine(string op)(
    in long a,
    in long b,
    in imported!"snakebite.nativelayout".TypeFacts aFacts,
    in imported!"snakebite.nativelayout".TypeFacts bFacts,
    imported!"dmd.expression".Expression expression,
) {
    static if (op == "<<" || op == ">>" || op == ">>>")
        return shifted!op(a, b, aFacts, expression);
    else static if (op == "/" || op == "%")
        return divided!op(
            a, b, sharedSignedness(aFacts, bFacts, expression), expression);
    else
        // `+`, `-`, `*`, `&`, `|` and `^` leave the same low bits
        // whichever way the operands were widened, so no signedness
        // question arises.
        return cast(ulong) mixin("a " ~ op ~ " b");
}

// The signedness that governs an operation whose answer depends on it.
// dmd's usual arithmetic conversions bring both operands to one common
// type before the interpreter sees the node - a narrower or differently
// signed operand arrives wrapped in a `CastExp` - so the two agree. If
// they ever do not, nothing here could pick between them, so this
// refuses instead of answering from one of them.
private bool sharedSignedness(
    in imported!"snakebite.nativelayout".TypeFacts a,
    in imported!"snakebite.nativelayout".TypeFacts b,
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;

    if (a.isUnsigned != b.isUnsigned)
        throw new Exception(
            text("interpreter cannot evaluate `", expression.toString,
                "`: its operands differ in signedness"),
        );

    return a.isUnsigned;
}

// D leaves a division by zero undefined, and the host's own divide
// instruction raises SIGFPE on it, which would take the host process
// down on guest input. The guest asked for something with no answer, so
// this reports that to the host the same way a failed guest assertion
// is reported: an exception the host survives, naming the expression.
private ulong divided(string op)(
    in long a,
    in long b,
    in bool unsigned,
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;

    if (b == 0)
        throw new Exception(
            text("interpreter: division by zero in `",
                expression.toString, "`"),
        );

    if (unsigned)
        return mixin("cast(ulong) a " ~ op ~ " cast(ulong) b");

    // The other input the host's divide instruction traps on:
    // `long.min / -1` has no representable quotient. Negation and a
    // zero remainder are the answers the instruction gives for every
    // other dividend, and the two's complement wrap `long.min` needs.
    if (b == -1) {
        static if (op == "/")
            return -cast(ulong) a;
        else
            return 0;
    }

    return cast(ulong) mixin("a " ~ op ~ " b");
}

// The left operand alone decides a shift: its width says how many bit
// positions there are, and its signedness says whether `>>` copies the
// sign bit down. The right operand is a count rather than a value in
// the same domain - dmd leaves it its own type, which can differ in
// signedness from the left one - so its facts say nothing here.
//
// A count outside `[0, width)` is undefined in D, and the host's shift
// instruction answers it by taking the count modulo the register width,
// which is a plausible wrong answer rather than the guest's own. It is
// refused instead.
private ulong shifted(string op)(
    in long a,
    in long b,
    in imported!"snakebite.nativelayout".TypeFacts aFacts,
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;

    const width = aFacts.size * 8;
    if (b < 0 || b >= width)
        throw new Exception(
            text("interpreter cannot shift by ", b, " in `",
                expression.toString, "`: the left operand has ", width,
                " bits"),
        );

    static if (op == "<<")
        return cast(ulong) a << b;
    else static if (op == ">>")
        return aFacts.isUnsigned
            ? cast(ulong) a >> b
            : cast(ulong) (a >> b);
    else {
        // `>>>` fills from the left with zeros within the operand's own
        // width. `a` is 64 bits here, so a signed operand's sign
        // extension above that width is cleared before the shift.
        const bits = width == 64
            ? cast(ulong) a
            : cast(ulong) a & ((1UL << width) - 1);
        return bits >> b;
    }
}
// One of the evaluator's caches: an answer worked out on a cold path,
// kept for the life of the evaluator, and read back by key on a hot one.
// A plain associative array, and the number of times it has been probed.
//
// The count is what makes it a type rather than an associative array
// declaration. Every probe of one of these is a hash of a pointer on a
// path the evaluator takes per node it visits, so how many of them a
// guest construct needs is a property worth asserting on, and a probe of
// a table that is already a `Cache` is counted without whoever adds it
// having to know the count exists.
//
// That is the whole of what the count covers: reads of the tables that
// are `Cache`s. A plain associative array declared beside them, a probe
// made inside `FrameLayout` or `PlanCache` to answer one query, and
// `opIndexAssign` below - itself a hash lookup, though only ever on a
// cold path - are all outside it, as is any read of `_entries` from
// elsewhere in this module, since `private` in D is module-scoped. What
// this feeds is a budget on the paths it does cover, not a fence around
// the evaluator.
//
// The count itself is `bin/ut` only: an unconditional increment here
// would be exactly the per-node cost it exists to measure.
private struct Cache(Key, Value) {
    private Value[Key] _entries;
    version(unittest) private size_t _lookups;

    public Value* opBinaryRight(string op: "in")(Key key) {
        version(unittest) ++_lookups;

        return key in _entries;
    }

    public void opIndexAssign(Value value, Key key) @safe nothrow pure {
        _entries[key] = value;
    }

    version(unittest)
    public size_t lookups() @safe @nogc nothrow pure const scope {
        return _lookups;
    }
}

// The value a declaration's initializer stores: dmd rewrites
// `long sum = 0;`'s initializer into a `ConstructExp` (`sum = 0`), and
// `int ret;`'s missing initializer into a `BlitExp` (`ret = 0`), so only
// `e2`, the actual value, needs evaluating.
private imported!"dmd.expression".Expression initializerValueOf(
    imported!"dmd.init".ExpInitializer initializer,
) {
    auto value = initializer.exp;
    if (auto construct = value.isConstructExp)
        return construct.e2;
    if (auto blit = value.isBlitExp)
        return blit.e2;

    return value;
}
