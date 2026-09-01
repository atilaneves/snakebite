module snakebite.backends.interpreter.walker;


private:


// Walks dmd's AST directly. The one invariant: a result is never boxed
// into a host-side representation - every expression is evaluated
// straight into a caller-designated native address, in native layout.
public final class Interpreter: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;

    // The one evaluator this backend ever creates: it owns the frame
    // stack and the per-function layout cache, both of which must
    // outlive any single call to stay warm across calls. `call` is a
    // thin adapter onto it.
    private Evaluator _evaluator;

    public this(const Program program) {
        super(program);
        _evaluator = new Evaluator(program);
    }

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        _evaluator.call(function_, returnPlace, args);
    }

    public override string eval(FuncDeclaration function_) {
        string result;
        call(function_, &result, []);
        return result;
    }

    version(unittest)
    public size_t nameLookups() @safe @nogc nothrow pure const scope {
        return _evaluator.nameLookups();
    }

    version(unittest)
    public size_t typeLookups() @safe @nogc nothrow pure const scope {
        return _evaluator.typeLookups();
    }

    version(unittest)
    public size_t symbolLookups() @safe @nogc nothrow pure const scope {
        return _evaluator.symbolLookups();
    }

}

import snakebite.exception: SnakebiteException;

// A guest throw must remain distinguishable from a refusal to interpret a
// guest construct. The runner catches this wrapper, while interpreter
// failures travel as `SnakebiteException` and continue through the host
// unchanged.
private final class GuestException: Exception {
    private Throwable _guest;
    private imported!"dmd.dclass".ClassDeclaration _class;

    public this(
        Throwable guest,
        imported!"dmd.dclass".ClassDeclaration class_ = null,
    ) {
        super(guest.msg);
        _guest = guest;
        _class = class_;
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
    import snakebite.backends.backend: Program;
    import snakebite.backends.layout: FrameLayout;
    import dmd.dclass: ClassDeclaration;
    import snakebite.framestack: FrameStack, defaultFrameCapacity;
    import snakebite.ffi: CallPlan, PlanCache, maxArguments;
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import snakebite.nativelayout:
        isIntegralSize, storeValue, TypeFacts;
    import object: Error, Exception, Throwable, TypeInfo_Class;
    import dmd.root.string: toDString;
    import dmd.astenums:
        Tarray, Tbool, Tclass, Tdelegate, Tfloat32, Tfloat64, Tnoreturn,
        Tint64, Tpointer, Tsarray, Tuns32, Tuns8, Tvoid;
    import dmd.declaration: Declaration, VarDeclaration;
    import dmd.expression;
    import dmd.func: FuncDeclaration;
    import dmd.identifier: Identifier;
    import dmd.init: ExpInitializer;
    import dmd.location: Loc;
    import dmd.mtype: Type;
    import dmd.statement:
        BreakStatement, CaseStatement, Catch, CompoundStatement,
        ContinueStatement, DefaultStatement, DoStatement, ExpStatement,
        ForStatement, GotoCaseStatement, GotoDefaultStatement, IfStatement,
        ImportStatement, LabelStatement, ReturnStatement, ScopeStatement,
        Statement, SwitchStatement, ThrowStatement, TryCatchStatement,
        TryFinallyStatement, UnrolledLoopStatement;
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
    private Cache!(VarDeclaration, void[]) _statics;
    // A guest pointer can live in an unscanned frame, so the evaluator keeps
    // each backing allocation reachable for as long as guest state can be.
    private ubyte[][] _allocations;
    // Guest class references point into these allocations. Keep the
    // declaration beside each object so a catch can match the actual
    // derived class after the reference has been widened.
    private ClassDeclaration[void*] _classes;
    private struct GuestClassRuntime {
        ClassDeclaration declaration;
        TypeInfo_Class typeInfo;
        void*[] vtable;
    }

    private GuestClassRuntime[] _classRuntime;
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
    // The program being run: its `isInterpreted` is the one decision for
    // whether a callee is walked here or called natively, made on every
    // call this evaluator makes.
    private const Program _program;
    // How to reach each already-compiled function this guest calls,
    // worked out on that function's first call and reused by every call
    // after it - the same cold-path-once shape as `_layouts`.
    private PlanCache _plans;
    // A call expression is one call site, even when a loop visits it many
    // times. The plan cache remains the cold path; this side cache keeps
    // the prepared plan with the AST call site that uses it.
    private struct CallSitePlan {
        private CallExp _callSite;
        private FuncDeclaration _function;
        private const(CallPlan)* _plan;
    }

    private CallSitePlan[] _callPlans;
    private CallSitePlan _lastCallSitePlan;
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
    // The currently executing function's own declaration - `frameOf`'s
    // starting point for walking the static chain up from wherever
    // execution currently is, one hop of `outerVars`' own reasoning per
    // level of nesting.
    private FuncDeclaration _function;
    // Set by `visit(ReturnStatement)`; checked by `visit(CompoundStatement)`
    // to stop walking sibling statements once one has run. dmd accepts
    // unreachable statements after a `return` (it only warns with `-w`),
    // so without this flag a statement after `return` would still
    // execute and silently overwrite an already-computed result.
    private bool _returned;
    // Set until the nearest loop consumes it, so enclosing compounds stop
    // before they execute the statements that `continue` skips.
    private bool _continued;
    // The label named by the pending continue, or null for an unlabelled
    // continue. A labelled continue stays set while it crosses loops until
    // the loop with that label consumes it.
    private Identifier _continueLabel;
    // Set until the nearest loop or switch consumes it. A switch needs the
    // same transfer as a loop because `break` exits either construct.
    private bool _break;
    // The label named by the pending break, or null for an unlabelled break.
    // Labelled breaks stay set until their LabelStatement consumes them.
    private Identifier _breakLabel;
    // A label stays pending while its wrapped statement is entered. The
    // wrapped loop takes it, even when dmd put a scope block between them.
    private Identifier _pendingLoopLabel;
    // A `goto case` or `goto default` leaves the current statement sequence
    // before the switch resumes it at its resolved target.
    private Statement _gotoTarget;
    // While a switch walks its body, this skips statements before the case
    // selected by its condition or by a `goto case` transfer.
    private Statement _switchStart;
    // Whether the currently executing function returns `ref`, set by
    // `execute` from the function's own type. Checked by
    // `visit(ReturnStatement)`: a `ref` return's `_place` is the address a
    // `return` statement's lvalue names, not the value that lvalue holds,
    // so the two need different code, and this is what tells them apart.
    private bool _returnsRef;

    // `extern(D)`: `Program` holds a dynamic array, which is not a valid
    // member of an `extern(C++)` signature, and only `Visitor`'s `visit`
    // overloads need that linkage.
    extern(D) public this(const Program program) {
        _program = program;
        _frames = FrameStack(defaultFrameCapacity);
    }

    // Runs `function_` against a fresh top-level frame, mirroring the
    // `Backend.call` contract: `returnPlace` is where the result goes
    // (`null` if the caller does not want it), `args` are host-to-guest
    // arguments (not yet supported). `extern(D)`: a dynamic array
    // parameter is not valid on an `extern(C++)` method, and this one is
    // never called from C++ - only `Visitor`'s `visit` overloads need
    // that linkage.
    //
    // Held for the whole call, not just the parts that reach into dmd's
    // own state directly: a guest call can walk into a druntime hook
    // (`~=`'s lowering, among others) whose body dmd has not finished
    // analysing yet, and forcing that analysis (`layoutOf`) mutates
    // `FuncDeclaration`/`Type` nodes another interpreter running on
    // another thread can be reading at the very same moment, since those
    // nodes are shared process-wide, not copied per snippet. The
    // frontend has exactly one lock for exactly this reason - every
    // other reach into it already goes through this same one - so a
    // guest call, once it can reach dmd's own forward-reference
    // machinery, joins that same one lock rather than adding a second
    // one dmd's other callers do not know to take.
    //
    // This serialises every interpreted call in the process against
    // every other one - accepted for now, not measured away: `bench/`
    // runs one backend on one thread, so it cannot see the cost of two
    // `Interpreter`s contending for this lock, only an uncontended
    // mutex round trip per top-level call. The place this cost is real
    // is concurrent guest execution - the test suite's own parallel
    // runner is already that today, and a program's unittests running
    // in parallel would be more of it. What would lift it: a pre-pass
    // that walks the callee graph reachable from `function_` and forces
    // `functionSemantic3` on all of it once, under the lock, before
    // `execute` runs the body unlocked - not attempted here, since nothing
    // has measured whether it is worth the surgery.
    extern(D) final void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        import snakebite.frontend.compiler: withCompilerLock;
        import std.conv: text;

        const parameterCount =
            function_.parameters is null ? 0 : function_.parameters.length;
        if (args.length != 0 || parameterCount != 0)
            throw new SnakebiteException(
                "host-to-guest arguments not yet supported by the " ~
                    "interpreter backend",
            );

        // A `ref` return hands the caller the *address* of the result, in
        // a scratch buffer `visit(ReturnStatement)` always sizes for a
        // pointer (`resolvedRefAddress` is where a guest `CallExp` reads
        // that address back and copies through it). This is the host
        // entry point, not a guest `CallExp`: `returnPlace` is storage
        // the host itself owns, sized for the callee's return type -
        // `int`, say - and `execute` would still write `size_t.sizeof`
        // bytes of an address into it. `ffi/plan.d`'s `prepare` refuses a
        // `ref` return for exactly this reason; this is the interpreter's
        // own entry point, so it gets the same refusal.
        if (typeFunctionOf(function_).isRef)
            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "` from the host: it returns by `ref`"),
            );

        withCompilerLock({
            auto layout = layoutOf(function_);
            auto frame = _frames.push(layout.size, layout.alignment);

            execute(function_, returnPlace, frame.base, layout);
        });
    }

    // Every hash lookup this evaluator has made to find where a name
    // lives: a variable's storage, or how to reach a called function.
    version(unittest)
    extern(D) final size_t nameLookups() @safe @nogc nothrow pure const scope {
        return _foreignNameLookups + _layouts.lookups + _statics.lookups
            + _plans.nativeSymbolLookups;
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

    version(unittest)
    extern(D) final size_t symbolLookups()
        @safe @nogc nothrow pure const scope
    {
        return _plans.symbolLookups;
    }

    extern(D) private void countForeignNameLookup() @safe @nogc nothrow pure {
        version(unittest) ++_foreignNameLookups;
    }

    private bool hasNativeSymbol(FuncDeclaration function_) {
        return _plans.hasNativeSymbol(function_);
    }

    // `function_`'s frame layout, from the cache; computed on its first
    // call. The returned pointer aims into the cache and stays valid: AA
    // entries do not move.
    private const(FrameLayout)* layoutOf(FuncDeclaration function_) {
        if (auto cached = function_ in _layouts)
            return cached;

        // dmd only runs semantic3 - the pass that resolves a function
        // body's own locals, `newCapacity` and the rest of druntime's
        // append hooks among them - on a module passed to it as a *root*
        // module, the ones actually being built; parsing a module dmd
        // reaches only through an `import`, as every druntime module
        // here is, does not run semantic3 over it. A non-template
        // function reached only by being called from one of those
        // hooks, never itself instantiated or written by the guest, has
        // a body dmd parsed but never finished analysing: its locals'
        // `Type`s are still the unresolved placeholder dmd starts them
        // at. dmd's own CTFE engine forces this same forward reference
        // before interpreting such a body (`dinterpret.d`'s call to this
        // same function) - which is why `Ctfe`, this interpreter's
        // sibling backend, does not need this forcing of its own: it
        // walks no body itself, `dinterpret.d` does, and already forces
        // it there. Walking a body here without first forcing it would
        // read those placeholders as real facts.
        //
        // `function_` here can be a druntime declaration many guest
        // programs share the very same `FuncDeclaration` for - dmd's
        // frontend is one process-global mutable structure, not one
        // instance per snippet. Mutating its semantic state this way is
        // safe only because `call` holds the frontend-wide compiler lock
        // for the whole of a top-level call, the same lock every other
        // reach into that structure already goes through - without it, a
        // second interpreter forcing the same forward reference on
        // another thread would race this one.
        import dmd.funcsem: functionSemantic3;
        functionSemantic3(function_);

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
        CallExp callSite = null,
        bool classConstructor = false,
    ) {
        import std.conv: text;

        // A template instance used only by interpreted guest code has no
        // machine-code symbol for FFI to find. DMD has already synthesized
        // and analyzed its exact body, so walk that body. This is semantic:
        // no function name, package, or template argument gets a vote.
        // Other non-root declarations still run as native code already
        // linked into the process.
        const isGuest = _program.isInterpreted(function_);
        const interpretsTemplate = !isGuest
            && function_.isInstantiated() !is null
            && function_.fbody !is null && !hasNativeSymbol(function_);
        if (!isGuest && !interpretsTemplate) {
            const(void)*[maxArguments] slots;
            const plan = callSite is null
                ? &_plans.of(function_)
                : callPlanOf(callSite, function_);
            plan.call(
                returnPlace, argumentSlots(slots, frameBase, layout),
            );
            return;
        }

        // `function_` being resolved only means a declaration was found;
        // it does not mean this call is safe to run directly. Only a
        // struct method's hidden context is covered: `bindFrame` fills
        // its `this` slot with the receiver lvalue's address. A class
        // method is resolved by dmd to the statically known declaration
        // even though the call is virtual, so running it here would
        // silently devirtualize the call and answer from the wrong
        // declaration. Constructors are the one class method this backend
        // executes directly: construction has selected that declaration,
        // and the object is not yet available through a virtual reference.
        auto aggregate = function_.isThis();
        if (aggregate !is null && aggregate.isStructDeclaration is null
                && !classConstructor)
            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "`: its class `this` is not bound"),
            );

        // A nested function's static chain - the enclosing function's
        // frame - is covered when the callee's frame outlives no longer
        // than the call that made it: `bindFrame` passes the caller's own
        // frame (reached by walking `frameOf`, if the callee is nested
        // more than one level deep) as `vthis`, and `slotOf` reads an
        // outer variable back through that same link. What is not
        // covered is a callee dmd's `needsClosure()` says escapes its
        // enclosing call - one whose captured locals must outlive the
        // frame stack pops them from, which this interpreter's frame
        // stack, unlike a heap-allocated closure, cannot provide - so
        // that one case alone still throws loudly instead of running
        // with a dangling context.
        import dmd.funcsem: needsClosure;

        if (function_.isNested() && function_.needsClosure())
            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "`: it captures an outer variable that must outlive ",
                    "the enclosing call, which the interpreter's frame ",
                    "stack does not support"),
            );

        // A root-owned declaration with no body has no code anywhere: the
        // program owns it, so no library can be expected to implement it.
        auto body_ = function_.fbody;
        if (body_ is null)
            throw new SnakebiteException(
                text("interpreter cannot call a function with no body: `",
                    function_.toString, "`"),
            );

        const guard = CallStateGuard(this);

        _type = function_.type.nextOf;
        _facts = factsOf(_type);
        _place = returnPlace;
        _frameBase = frameBase;
        _layout = layout;
        _function = function_;
        _returned = false;
        _continued = false;
        _continueLabel = null;
        _break = false;
        _breakLabel = null;
        _pendingLoopLabel = null;
        _gotoTarget = null;
        _switchStart = null;
        _returnsRef = typeFunctionOf(function_).isRef;
        body_.accept(this);
    }

    private const(CallPlan)* callPlanOf(
        CallExp callSite,
        FuncDeclaration function_,
    ) {
        if (_lastCallSitePlan._callSite is callSite
                && _lastCallSitePlan._function is function_)
            return _lastCallSitePlan._plan;

        foreach (i; 0 .. _callPlans.length) {
            CallSitePlan* cached = &_callPlans[i];
            if (cached._callSite is callSite
                && cached._function is function_) {
                _lastCallSitePlan = *cached;
                return _lastCallSitePlan._plan;
            }
        }

        countForeignNameLookup;
        const plan = &_plans.of(function_);
        _callPlans ~= CallSitePlan(callSite, function_, plan);
        _lastCallSitePlan = _callPlans[$ - 1];
        return plan;
    }

    // RAII restore of the per-call evaluator state `execute` repoints at
    // the callee: constructed before the fields change, and the
    // destructor puts every one back when the call unwinds, normally or
    // by throw. One field list in one place, instead of a saved variable
    // plus a `scope(exit)` line per field growing at the call site.
    private static struct CallStateGuard {
        private Evaluator _evaluator;
        private Type _type;
        private TypeFacts _facts;
        private void* _place;
        private ubyte* _frameBase;
        private const(FrameLayout)* _layout;
        private FuncDeclaration _function;
        private bool _returned;
        private bool _continued;
        private Identifier _continueLabel;
        private bool _break;
        private Identifier _breakLabel;
        private Identifier _pendingLoopLabel;
        private Statement _gotoTarget;
        private Statement _switchStart;
        private bool _returnsRef;

        @disable this();
        @disable this(this);

        private this(Evaluator evaluator) {
            _evaluator = evaluator;
            _type = evaluator._type;
            _facts = evaluator._facts;
            _place = evaluator._place;
            _frameBase = evaluator._frameBase;
            _layout = evaluator._layout;
            _function = evaluator._function;
            _returned = evaluator._returned;
            _continued = evaluator._continued;
            _continueLabel = evaluator._continueLabel;
            _break = evaluator._break;
            _breakLabel = evaluator._breakLabel;
            _pendingLoopLabel = evaluator._pendingLoopLabel;
            _gotoTarget = evaluator._gotoTarget;
            _switchStart = evaluator._switchStart;
            _returnsRef = evaluator._returnsRef;
        }

        ~this() {
            _evaluator._type = _type;
            _evaluator._facts = _facts;
            _evaluator._place = _place;
            _evaluator._frameBase = _frameBase;
            _evaluator._layout = _layout;
            _evaluator._function = _function;
            _evaluator._returned = _returned;
            _evaluator._continued = _continued;
            _evaluator._continueLabel = _continueLabel;
            _evaluator._break = _break;
            _evaluator._breakLabel = _breakLabel;
            _evaluator._pendingLoopLabel = _pendingLoopLabel;
            _evaluator._gotoTarget = _gotoTarget;
            _evaluator._switchStart = _switchStart;
            _evaluator._returnsRef = _returnsRef;
        }
    }

    // Where the hidden context and each explicit parameter's bytes sit in
    // the frame the caller just filled: what the FFI needs to hand them
    // over, built from the layout this interpreter already computed.
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
        size_t count;
        if (layout.hiddenThis.variable !is null)
            slots[count++] =
                frameBase + layout.hiddenThis.parameter.offset;

        foreach (i, parameter; layout.parameters)
            slots[count++] = frameBase + parameter.offset;

        return slots[0 .. count];
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

        throw new SnakebiteException(
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

    override void visit(TryCatchStatement statement) {
        try {
            statement._body.accept(this);
        } catch (GuestException exception) {
            foreach (catch_; *statement.catches) {
                if (!matchesThrowable(catch_, exception))
                    continue;

                bindCatchVariable(catch_, exception._guest);
                catch_.handler.accept(this);
                return;
            }

            throw exception;
        }
    }

    override void visit(TryFinallyStatement statement) {
        try {
            if (statement._body !is null)
                statement._body.accept(this);
        } finally {
            if (statement.finalbody !is null)
                statement.finalbody.accept(this);
        }
    }

    // Match the actual guest class against the catch class and its base
    // chain. A native assertion has no guest declaration, but it is still
    // a Throwable and keeps the existing catch(Throwable) behavior.
    private bool matchesThrowable(
        Catch catch_,
        GuestException exception,
    ) {
        auto typeClass = catch_.type.isTypeClass;
        if (typeClass is null)
            return false;

        if (exception._class is null)
            return typeClass.sym is ClassDeclaration.throwable;

        return typeClass.sym is exception._class
            || typeClass.sym.isBaseOf(exception._class, null);
    }

    private void bindCatchVariable(Catch catch_, Throwable guest) {
        if (catch_.var is null)
            return;

        import snakebite.nativelayout: storeIntegral;

        auto slot = _frameBase + _layout.offsetOf(catch_.var);
        storeIntegral(slot, cast(size_t) cast(void*) guest, size_t.sizeof);
    }

    override void visit(CompoundStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements) {
            if (child !is null) {
                if (_switchStart !is null) {
                    if (child is _switchStart)
                        _switchStart = null;
                    else if (!containsSwitchTarget(child))
                        continue;
                }
                child.accept(this);
                if (_returned || _continued || _break
                        || _gotoTarget !is null)
                    return;
            }
        }
    }

    override void visit(UnrolledLoopStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements) {
            if (child !is null) {
                if (_switchStart !is null) {
                    if (child is _switchStart)
                        _switchStart = null;
                    else if (!containsSwitchTarget(child))
                        continue;
                }
                child.accept(this);
                if (_returned || _continued || _break
                        || _gotoTarget !is null)
                    return;
            }
        }
    }

    private bool containsSwitchTarget(Statement statement) {
        while (statement !is null) {
            if (statement is _switchStart)
                return true;

            if (auto case_ = statement.isCaseStatement)
                statement = case_.statement;
            else if (auto scope_ = statement.isScopeStatement)
                statement = scope_.statement;
            else if (auto compound = statement.isCompoundStatement) {
                if (compound.statements is null)
                    return false;

                foreach (child; *compound.statements)
                    if (child !is null && containsSwitchTarget(child))
                        return true;
                return false;
            }
            else
                return false;
        }

        return false;
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

        // dmd appends `return 0;` to every `main`, including `void main`.
        // A void return has no destination, so discard that synthetic value
        // instead of trying to lay it out as `void`.
        if (_type.ty == Tvoid)
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

    override void visit(BreakStatement statement) {
        _break = true;
        _breakLabel = statement.ident;
    }

    override void visit(LabelStatement statement) {
        auto previousLabel = _pendingLoopLabel;
        _pendingLoopLabel = statement.ident;
        scope (exit) _pendingLoopLabel = previousLabel;

        if (statement.statement !is null)
            statement.statement.accept(this);

        if (_breakLabel is statement.ident) {
            _break = false;
            _breakLabel = null;
        }
    }

    override void visit(SwitchStatement statement) {
        _pendingLoopLabel = null;
        const condition = asIntegral(statement.condition);
        Statement selected;
        if (statement.cases !is null)
            foreach (case_; *statement.cases) {
                if (asIntegral(case_.exp) == condition) {
                    selected = case_;
                    break;
                }
            }

        if (selected is null)
            selected = statement.sdefault;
        if (selected is null)
            return;

        auto previousStart = _switchStart;
        auto previousTarget = _gotoTarget;
        scope (exit) {
            _switchStart = previousStart;
            _gotoTarget = previousTarget;
        }

        while (true) {
            _switchStart = selected;
            _gotoTarget = null;
            statement._body.accept(this);

            if (_returned || _continued)
                return;

            if (_break) {
                if (_breakLabel is null) {
                    _break = false;
                    return;
                }

                return;
            }

            auto target = _gotoTarget;
            if (target is null)
                return;

            bool belongs;
            if (target is statement.sdefault)
                belongs = true;
            else if (statement.cases !is null)
                foreach (case_; *statement.cases)
                    if (target is case_) {
                        belongs = true;
                        break;
                    }

            if (!belongs)
                return;

            selected = target;
        }
    }

    override void visit(CaseStatement statement) {
        if (statement.statement !is null)
            statement.statement.accept(this);
    }

    override void visit(DefaultStatement statement) {
        if (statement.statement !is null)
            statement.statement.accept(this);
    }

    override void visit(GotoCaseStatement statement) {
        if (statement.cs is null)
            throw new SnakebiteException(
                "interpreter cannot execute an unresolved `goto case`",
            );

        _gotoTarget = statement.cs;
    }

    override void visit(GotoDefaultStatement statement) {
        if (statement.sw is null || statement.sw.sdefault is null)
            throw new SnakebiteException(
                "interpreter cannot execute an unresolved `goto default`",
            );

        _gotoTarget = statement.sw.sdefault;
    }

    override void visit(ThrowStatement statement) {
        throwGuest(statement.exp);
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
        // `8` is a register's width on the one ABI this project supports
        // (`ffi.abi.supported` is `false` everywhere else) - `size_t.sizeof`
        // names that rather than repeating the literal.
        if (facts.size <= size_t.sizeof && facts.alignment <= size_t.sizeof) {
            align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
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
        auto loopLabel = _pendingLoopLabel;
        _pendingLoopLabel = null;

        while (statement.condition is null || truthOf(statement.condition)) {
            if (statement._body !is null) {
                statement._body.accept(this);
                if (_returned || _gotoTarget !is null)
                    return;
                if (_break) {
                    if (_breakLabel is null) {
                        _break = false;
                        return;
                    }

                    return;
                }
                if (_continued) {
                    if (_continueLabel !is null
                            && _continueLabel !is loopLabel)
                        return;

                    _continued = false;
                    _continueLabel = null;
                }
            }

            if (statement.increment !is null)
                runForEffect(statement.increment);
        }
    }

    override void visit(DoStatement statement) {
        auto loopLabel = _pendingLoopLabel;
        _pendingLoopLabel = null;

        while (true) {
            if (statement._body !is null)
                statement._body.accept(this);

            if (_returned || _gotoTarget !is null)
                return;

            if (_break) {
                if (_breakLabel is null) {
                    _break = false;
                    return;
                }

                return;
            }

            if (_continued) {
                if (_continueLabel !is null
                        && _continueLabel !is loopLabel)
                    return;

                _continued = false;
                _continueLabel = null;
            }

            if (!truthOf(statement.condition))
                return;
        }
    }

    override void visit(ContinueStatement statement) {
        _continued = true;
        _continueLabel = statement.ident;
    }

    private bool truthOf(Expression expression) {
        import std.conv: text;

        auto type = expression.type;
        const facts = factsOf(type);
        if (facts.isIntegral)
            return asIntegral(expression, facts) != 0;

        // The pointer alone decides. dmd 2.112 and ldc2 1.42 disagree on
        // an array with a length but a null pointer - dmd calls it true,
        // ldc2 false - so that half is not something to assert as a
        // language rule. No guest program this interpreter can run builds
        // that value, so no test pins it either way; when one can, the
        // oracle the suite compares against settles it.
        if (type.ty == Tarray)
            return evaluateArray(expression, facts).elements !is null;

        // A pointer is true when it is not null, the same test `if (ptr)`
        // means in ordinary compiled D - `__typeAttrs`, on the `~=`
        // lowering's own chain, asks this of the block address it was
        // handed to decide whether to consult the GC about it at all.
        if (type.ty == Tpointer)
            return asPointer(expression) !is null;

        throw new SnakebiteException(
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
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as a dynamic array: its type is `", type.toString,
                    "`"),
            );

        assert(facts.size == arrayValueSize
                && facts.alignment <= size_t.sizeof,
            "a dynamic array is not two words on this target");

        align(size_t.sizeof) ubyte[arrayValueSize] value = void;
        evaluate(expression, type, facts, value.ptr);

        return ArrayValue(
            cast(size_t) loadIntegral(
                value.ptr + arrayLengthOffset, size_t.sizeof, false),
            *cast(ubyte**) (value.ptr + arrayPointerOffset),
        );
    }

    // Evaluates `expression` and hands back its value, for a caller that
    // needs the value itself rather than a destination to leave it at.
    private long asIntegral(Expression expression) {
        return asIntegral(expression, factsOf(expression.type));
    }

    private long asIntegral(Expression expression, in TypeFacts facts) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        auto type = expression.type;
        if (!facts.isIntegral)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as an integral: its type is `", type.toString, "`"),
            );

        align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
        assert(facts.size <= buffer.sizeof && facts.alignment <= buffer.alignof,
            "an integral wider than a register reached the scratch buffer");

        evaluate(expression, type, facts, buffer.ptr);

        return loadIntegral(buffer.ptr, facts.size, !facts.isUnsigned);
    }

    // As `asIntegral`, for a pointer: `Type.isIntegral` is false for
    // `Tpointer` (a pointer is not an arithmetic type), so `asIntegral`
    // itself refuses one. A dereference needs the address a pointer
    // expression evaluates to, not an integral value, hence the separate
    // path - though the bytes are read the same way either type is stored.
    private void* asPointer(Expression expression) {
        import std.conv: text;

        auto type = expression.type;
        if (type.ty != Tpointer)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as a pointer: its type is `", type.toString, "`"),
            );

        const facts = factsOf(type);
        align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
        assert(facts.size <= buffer.sizeof && facts.alignment <= buffer.alignof,
            "a pointer wider than a register reached the scratch buffer");

        evaluate(expression, type, facts, buffer.ptr);

        return *cast(void**) buffer.ptr;
    }

    override void visit(Expression expression) {
        import std.conv: text;

        throw new SnakebiteException(
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

    // A function literal as a value. The function word holds the
    // declaration itself rather than a machine address, because this
    // backend has no machine code for the literal - `calleeOf` reads it
    // back when the value is called. The context word is what tells a
    // delegate this interpreter can run from one it cannot: null is the
    // only context a non-capturing literal ever needs, so `calleeOf`
    // refuses anything else. A literal that reads an enclosing local
    // needs the frame it read from as its context, which this
    // interpreter does not represent, so it is refused here - where the
    // value is made - rather than at some later call through it.
    override void visit(FuncExp expression) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, storeIntegral;
        import std.conv: text;

        auto literal = expression.fd;
        if (literal is null || literal.isThis() !is null
                || literal.outerVars.length != 0)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only a non-capturing function literal is supported"),
            );

        auto bytes = cast(ubyte*) _place;
        const functionWord = cast(size_t) cast(void*) literal;

        if (_type.ty == Tdelegate) {
            storeIntegral(
                bytes + delegateContextOffset, 0, size_t.sizeof);
            storeIntegral(
                bytes + delegateFunctionOffset, functionWord, size_t.sizeof);
            return;
        }

        if (expression.type.ty == Tpointer) {
            storeIntegral(bytes, functionWord, size_t.sizeof);
            return;
        }

        throw new SnakebiteException(
            text("interpreter cannot evaluate `", expression.toString,
                "` as a `", _type.toString, "`"),
        );
    }

    override void visit(VarExp expression) {
        import core.stdc.string: memcpy;
        import dmd.id: Id;
        import snakebite.nativelayout: storeIntegral;

        // DMD creates this compiler variable during semantic analysis. Its
        // own native code generator defines it as false at run time; true is
        // reserved for DMD's CTFE engine. Compare the interned identifier,
        // not source spelling that guest code could imitate.
        if (expression.var.ident is Id.ctfe) {
            storeIntegral(_place, 0, _facts.size);
            return;
        }

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

    // A class `this` is a reference value in its hidden frame slot. A
    // struct `this` is the address of the struct value, so it keeps the
    // ordinary byte-copy behavior used by struct methods.
    override void visit(ThisExp expression) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: loadIntegral, storeIntegral;

        VarDeclaration variable;
        if (expression.var is null)
            variable = cast() _layout.hiddenThis.variable;
        else
            variable = expression.var;
        auto slot = slotOf(expression, variable);
        if (_type.ty == Tclass) {
            storeIntegral(
                _place,
                loadIntegral(slot, size_t.sizeof, false),
                _facts.size,
            );
            return;
        }

        memcpy(_place, slot, _facts.size);
    }

    // The function `variable` is a parameter or local of - `toParent2`
    // walks up past any block or `Catch` scope in between, which are not
    // `Dsymbol`s of their own, straight to the nearest enclosing function
    // or aggregate. `null` for anything else it could be a member of
    // (an aggregate's field, reached through `this` rather than a static
    // chain, or a module-scope symbol) - `frameOf`'s caller is the one
    // that turns that into a refusal, since only it knows whether "not a
    // frame variable at all" or "not on the chain from here" is the
    // right thing to say.
    private FuncDeclaration outerFunctionOf(VarDeclaration variable) {
        auto parent = variable.toParent2();
        return parent is null ? null : parent.isFuncDeclaration;
    }

    // Where `owner`'s own frame is: `owner` itself if it is the function
    // currently executing, otherwise found by following the static chain
    // up from there - one context-word hop per level of nesting, reading
    // each frame's own `vthis` slot the same way `bindFrame` filled it,
    // exactly as compiled D follows the same chain to reach the same
    // frame. Both a direct call to a nested function (`bindFrame`, to
    // learn what context to pass its callee) and an outer-variable read
    // (`slotOf`, to learn where the variable actually lives) need this;
    // the former is content with "unreachable" as an answer (nothing on
    // that path ever dereferences a link that was never asked for), the
    // latter is not, so it refuses through this wrapper instead.
    private ubyte* frameOf(FuncDeclaration owner) {
        import std.conv: text;

        auto base = tryFrameOf(owner);
        if (base is null)
            throw new SnakebiteException(
                text("interpreter cannot reach `", owner.toString,
                    "`'s frame: it is not on the current static chain"),
            );

        return base;
    }

    // As `frameOf`, but `null` rather than a thrown exception when
    // `owner`'s frame is not reachable from here - a caller nested
    // several levels above `owner` on the chain relays `owner`'s frame on
    // to a callee nested inside it without ever reading from it itself,
    // exactly as compiled D's own relayed static link does, and that
    // relay must succeed even when the function doing the relaying
    // happens not to be on `owner`'s chain at all (a non-capturing
    // callee's link is never dereferenced, so an unreachable answer is a
    // fine one to pass on).
    private ubyte* tryFrameOf(FuncDeclaration owner) {
        import snakebite.nativelayout: loadIntegral;

        auto fn = _function;
        auto base = _frameBase;
        while (fn !is owner) {
            auto layout = layoutOf(fn);
            if (layout.hiddenThis.variable is null)
                return null;

            auto parent = fn.toParent2();
            fn = parent is null ? null : parent.isFuncDeclaration;
            if (fn is null)
                return null;

            base = cast(ubyte*) loadIntegral(
                base + layout.hiddenThis.parameter.offset, size_t.sizeof,
                false);
        }

        return base;
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
            throw new SnakebiteException(
                text("interpreter cannot reach `", original.toString,
                    "`: not a parameter or local in the current frame"),
            );

        if (variable.isDataseg)
            return staticSlotOf(variable);

        countForeignNameLookup;

        // A parameter or local of the currently executing function itself
        // is the common case, and the only one a non-nested function ever
        // has. `variable` not being one of those is what an outer
        // variable - read from inside a nested function, through the
        // static chain `bindFrame` set up when it was called - looks
        // like here, so that is tried next rather than refusing outright.
        auto base = _frameBase;
        auto layout = _layout;
        if (!layout.hasSlot(variable)) {
            auto owner = outerFunctionOf(variable);
            if (owner is null)
                throw new SnakebiteException(
                    text("interpreter cannot reach `", original.toString,
                        "`: not a parameter or local in the current ",
                        "frame or an enclosing one"),
                );

            base = frameOf(owner);
            layout = layoutOf(owner);
        }

        auto slot = base + layout.offsetOf(variable);

        // A `ref` variable's own slot holds the address of the referenced
        // storage, not the storage itself. Reading through it once more here,
        // the one place every read, write and address-of a variable resolves
        // its slot, makes a reach of the variable reach its target instead.
        if (layout.isRef(variable))
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
        import std.conv: text;

        if (auto existing = variable in _statics)
            return cast(ubyte*) existing.ptr;

        // An `extern` variable is defined elsewhere - in a library the
        // host already links, or in another object file. Storage made
        // here would be a second variable that only looks like it, so
        // this refuses rather than answering from a private copy.
        if (variable.storage_class & STC.extern_)
            throw new SnakebiteException(
                text("interpreter cannot reach `", variable.toString,
                    "`: it is `extern`, so its storage is not the ",
                    "interpreter's to make"),
            );

        ExpInitializer expInitializer;
        if (variable._init !is null) {
            expInitializer = variable._init.isExpInitializer;
            if (expInitializer is null)
                throw new SnakebiteException(
                    text("interpreter cannot initialize `", variable.toString,
                        "`: only a plain expression initializer is supported"),
                );
        }

        // Over-allocated so the slot can start on the type's own
        // alignment: the guest reads and writes it in native layout, and
        // nothing in the GC's interface promises a block aligned for the
        // type that lands in it. Alignments are powers of two, so the
        // padding is the address masked into the block.
        const facts = factsOf(variable.type);
        const blockSize = facts.size + facts.alignment - 1;
        auto block = new void[](blockSize);
        const start = -cast(size_t) block.ptr & (facts.alignment - 1);
        auto slot = block[start .. start + facts.size];

        // Registered only once the initialiser has run: a slot in
        // `_statics` means initialised, so a failed initialiser must not
        // leave one behind for a later reach to read as a value.
        if (variable._init is null)
            initializeDefault(
                variable.type,
                facts,
                cast(ubyte*) slot.ptr,
                variable.loc,
            );
        else
            evaluate(
                initializerValueOf(expInitializer),
                variable.type,
                facts,
                slot.ptr,
            );
        _statics[variable] = slot;

        return cast(ubyte*) slot.ptr;
    }

    // Runs a local's initializer into the frame slot `layoutOf` already
    // gave it. `long sum = 0;` is a `DeclarationExp` here.
    override void visit(DeclarationExp expression) {
        import std.conv: text;

        // Semantic analysis has already established a function-local
        // struct's type, so declaring it needs no runtime action. Likewise,
        // `alias Unqual_T = Unqual!T;` binds a name to a type, not
        // storage, and `enum mask(ulong lo) = ...;` (an eponymous
        // template, folded to its value at each `mask!x` use rather than
        // run from here) binds a name to neither a type nor a value of
        // its own - druntime's own append hooks declare both kinds in
        // their own bodies, the same way an `import` inside a function
        // body binds a name with nothing left to execute (see
        // `visit(ImportStatement)`). `Ctfe`, this interpreter's sibling
        // backend, needs no special case of its own for either: it runs
        // dmd's own `dinterpret.d`, which already knows a body can hold
        // both. Any future backend that walks a body's AST itself,
        // rather than handing it to dmd's engine, inherits the same
        // need.
        // A nested function declaration - `int lookup(string key) { ... }`
        // written as a statement - likewise binds a name to a
        // `FuncDeclaration` dmd has already resolved every call to, not
        // storage this evaluator has to create: nothing runs until the
        // guest calls `lookup`, at which point `visit(CallExp)` reaches
        // it as `expression.f`, not through this declaration at all.
        if (expression.declaration.isStructDeclaration !is null
                || expression.declaration.isAliasDeclaration !is null
                || expression.declaration.isTemplateDeclaration !is null
                || expression.declaration.isFuncDeclaration !is null)
            return;

        auto variable = expression.declaration.isVarDeclaration;
        if (variable is null)
            throw new SnakebiteException(
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

        // `T value = void` requests storage without initialization. The
        // frame slot already exists, so executing this declaration performs
        // no write. Code must assign any bytes it reads, as in compiled D.
        if (variable._init.isVoidInitializer !is null)
            return;

        auto expInitializer = variable._init.isExpInitializer;
        if (expInitializer is null)
            throw new SnakebiteException(
                text("interpreter cannot run the initializer for `",
                    expression.toString, "`: only a plain expression ",
                    "initializer is supported"),
            );

        auto value = initializerValueOf(expInitializer);
        if (_layout.isRef(variable)) {
            import snakebite.nativelayout: storeIntegral;

            storeIntegral(
                _frameBase + offset,
                cast(size_t) addressOf(value),
                size_t.sizeof,
            );
            return;
        }

        evaluate(value, variable.type, _frameBase + offset);
    }

    // DMD lowers dynamic-array length assignment to a native druntime call
    // so allocation, prefix preservation, and the array pointer update stay
    // in druntime rather than being emulated by the interpreter.
    override void visit(LoweredAssignExp expression) {
        expression.lowering.accept(this);
    }

    // Assignment is an expression: it yields the value it assigned. A
    // struct right side needs scratch storage so evaluating a literal does
    // not clear an aliased target before all of its fields are read.
    // `_facts` is the target's facts here: dmd's semantic pass wraps an
    // assignment feeding a wider destination in a cast of its own, which is
    // a node this interpreter refuses rather than one it reaches this code
    // with.
    override void visit(AssignExp expression) {
        assign(expression);
    }

    private void* assign(AssignExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        // `ConstructExp` and `BlitExp` arrive as this same node. Over a
        // type with a destructor or an overloaded assignment, running
        // either as a plain store would be a wrong answer, not a
        // refusal, since D specifies construction and assignment
        // differently there - so both stay refused in general. Integral
        // and dynamic-array targets have neither: constructing, blitting
        // and assigning one are the same bytes written the same way, which
        // is exactly the shape `_d_arrayappendcTX_`'s own lowering
        // writes, on the `~=` lowering's own chain, into the slot it
        // just extended (`a[a.length - 1] = 2`, dmd's own `construct`
        // for filling storage the guest has not touched yet).
        auto structType = _type.isTypeStruct;
        const isSupportedStruct = structType !is null
            && supportsStruct(_type);
        // DMD represents the raw copy that precedes its explicit
        // `__aggrPostblit` call as `BlitExp`. It is not ordinary D
        // assignment: the following AST node applies the lifecycle hook,
        // so this node must copy the native bytes even when the struct has
        // a postblit.
        const isStructBlit = structType !is null
            && expression.isBlitExp !is null;
        const isSupportedArray = _type.ty == Tarray;
        if (structType !is null && !isSupportedStruct && !isStructBlit)
            throw new SnakebiteException(
                text("interpreter cannot assign unsupported struct `",
                    structType.toString, "`"),
            );

        if (expression.op != EXP.assign && !_facts.isIntegral
                && !isSupportedStruct && !isStructBlit
                && !isSupportedArray)
            throw new SnakebiteException(
                text("interpreter cannot run a `", expression.op,
                    "` on `", expression.e1.toString, "`"),
            );

        // Naming `e1` rather than the whole expression: dmd lowers
        // `s.length = n` into a node whose `toString` is a bare `=`.
        auto target = addressOf(expression.e1);
        if (isSupportedStruct || isStructBlit) {
            auto scratch = _frames.push(_facts.size, _facts.alignment);
            evaluate(expression.e2, _type, _facts, scratch.base);
            memcpy(target, scratch.base, _facts.size);
        } else {
            evaluate(expression.e2, _type, _facts, target);
        }
        memcpy(_place, target, _facts.size);
        return target;
    }

    private bool supportsStruct(Type type) {
        import dmd.astenums: STC;

        auto structType = type.isTypeStruct;
        if (structType is null)
            return false;

        auto declaration = structType.sym;
        // A non-zero `.init` needs field initializers that this bytewise
        // evaluator does not run for omitted fields.
        if (!declaration.zeroInit
                || declaration.isUnionDeclaration !is null
                || declaration.enclosing !is null
                || declaration.postblit !is null || declaration.hasCopyCtor
                || declaration.dtor !is null
                || declaration.hasIdentityAssign || declaration.hasBlitAssign)
            return false;

        foreach (field; declaration.fields) {
            if (field.isBitFieldDeclaration !is null
                    || field.storage_class & STC.ref_)
                return false;

            if (field.type.isTypeStruct !is null) {
                if (!supportsStruct(field.type))
                    return false;
                continue;
            }

            // A dynamic array field is a plain two-word slice - a
            // length and a pointer, in whichever order the compiler's
            // ABI puts them - with no copy hook of its own, so the
            // bytewise copy this predicate guards handles it: the copy
            // shares the same elements, exactly as compiled D
            // assignment of a slice does. It is not integral, so
            // without this the size/integrality check below would
            // reject it.
            if (field.type.ty == Tarray)
                continue;

            const facts = factsOf(field.type);
            if (!facts.isIntegral || !isIntegralSize(facts.size))
                return false;
        }

        return true;
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

        // dmd's semantic pass resolves a `this` the guest wrote to the
        // enclosing method's own `vthis` declaration; a constructor's
        // implicit `return this;` is synthesised with no `var`, and the
        // layout knows which declaration owns the frame's `this` slot,
        // so the reach is the same either way.
        // `cast()`: `_layout` is a const view, but dmd's own AST
        // accessors (`isVarDeclaration` among them) are not
        // const-correct, and `slotOf` only reads the declaration.
        if (auto thisExp = target.isThisExp)
        {
            auto slot = slotOf(
                thisExp,
                thisExp.var is null
                    ? cast() _layout.hiddenThis.variable
                    : thisExp.var,
            );
            if (target.type.ty == Tclass) {
                import snakebite.nativelayout: loadIntegral;

                return cast(void*) loadIntegral(
                    slot, size_t.sizeof, false);
            }
            return slot;
        }

        if (auto variable = target.isVarExp)
            return slotOf(variable);

        if (auto cast_ = target.isCastExp) {
            if (factsOf(cast_.e1.type).isIntegral
                    && factsOf(target.type).isIntegral)
                return addressOf(cast_.e1);
        }

        if (auto deref = target.isPtrExp)
            return asPointer(deref.e1);

        // Only the branch taken is ever an lvalue this needs the address
        // of - the other one, like an `if`'s untaken branch, never runs,
        // so evaluating its address would be reaching into storage this
        // call was never given.
        if (auto cond = target.isCondExp)
            return addressOf(truthOf(cond.econd) ? cond.e1 : cond.e2);

        // DMD uses a comma expression when a scoped temporary needs setup
        // before its initializer. The left side runs for its effects; only
        // the right side names the resulting lvalue.
        if (auto comma = target.isCommaExp) {
            runForEffect(comma.e1);
            return addressOf(comma.e2);
        }

        // An assignment used as an lvalue first performs the assignment,
        // then names the storage on its left. DMD uses this form for a
        // copied aggregate whose postblit is called on the new copy.
        void* assignmentResultAddress(AssignExp assignment) {
            const facts = factsOf(target.type);
            auto result = _frames.push(facts.size, facts.alignment);

            auto savedType = _type;
            auto savedFacts = _facts;
            auto savedPlace = _place;
            scope(exit) {
                _type = savedType;
                _facts = savedFacts;
                _place = savedPlace;
            }

            _type = target.type;
            _facts = facts;
            _place = result.base;
            return assign(assignment);
        }

        if (auto blit = target.isBlitExp)
            return assignmentResultAddress(blit);

        if (auto construct = target.isConstructExp)
            return assignmentResultAddress(construct);

        if (auto assignment = target.isAssignExp)
            return assignmentResultAddress(assignment);

        if (auto call = target.isCallExp)
            return refCallAddress(call);

        if (auto length = target.isArrayLengthExp) {
            import snakebite.nativelayout: arrayLengthOffset;

            if (length.e1.type.ty != Tarray)
                throw new SnakebiteException(
                    text("interpreter cannot take the address of `",
                        target.toString,
                        "`: only a dynamic-array length is supported"),
                );

            return cast(ubyte*) addressOf(length.e1) + arrayLengthOffset;
        }

        // `a[i] = x`: the address is the array's own element storage,
        // found the same way a read (`visit(IndexExp)`) finds it - bounds
        // checked the same way too, since writing past the array is the
        // same fault reading past it already is. `_d_arrayappendcTX_`, on
        // the `~=` lowering's own chain, writes the element it just grew
        // room for this way.
        if (auto index = target.isIndexExp)
            return indexAddressOf(index).ptr;

        if (auto dot = target.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field is null)
                throw new SnakebiteException(
                    text("interpreter cannot take the address of `",
                        target.toString,
                        "`: only a struct field is supported"),
                );

            return cast(ubyte*) fieldBaseAddress(dot.e1) + field.offset;
        }

        throw new SnakebiteException(
            text("interpreter cannot take the address of `",
                target.toString, "`: it is not an lvalue"),
        );
    }

    // An element's address and its own type's stride, from the one
    // `indexAddressOf` call both a read (`visit(IndexExp)`) and a write
    // (`addressOf`) need: `FrameLayout.Slot` already hands an offset and
    // its facts back together for the same reason - a caller that
    // computed the stride itself first, then called here for the
    // address, would pay `factsOf(array.type.nextOf)` twice, evicting
    // and refilling the one-entry `_cachedType` in between with
    // `factsOf(array.type)`, this call's own first lookup.
    private struct ElementAddress {
        void* ptr;
        size_t stride;
    }

    private ElementAddress indexAddressOf(IndexExp expression) {
        import std.conv: text;

        auto array = expression.e1;

        // `ptr[i]` has no length of its own to bound-check against - the
        // same as compiled D, which leaves that to whatever built the
        // pointer. dmd's own rvalue-AA-index lowering (`aa[key]`, see
        // `visit(AssocArrayLiteralExp)` for the literal's own lowering)
        // takes exactly this shape: `_d_aaGetRvalueX!(K, V)(aa, key)[0]`,
        // a pointer indexed at a literal `0`, wrapped by dmd's own
        // semantic pass in a `? :` that already turned a missing key into
        // `RangeError` before this is ever reached - so the null this
        // would otherwise have to guard against never arrives here.
        if (array.type.ty == Tpointer) {
            const stride = factsOf(array.type.nextOf).size;
            auto base = cast(ubyte*) asPointer(array);
            const index = indexOf(expression, 0);

            return ElementAddress(
                cast(void*) (base + index * stride), stride);
        }

        const value = evaluateArray(array, factsOf(array.type));
        const index = indexOf(expression, value.length);

        if (index < 0 || cast(size_t) index >= value.length)
            throw new SnakebiteException(
                text("interpreter cannot index `", array.toString,
                    "` at ", index, ": the array is ", value.length,
                    " long"),
            );

        const stride = factsOf(array.type.nextOf).size;
        return ElementAddress(
            cast(void*) (value.elements + index * stride), stride);
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

        const targetFacts = factsOf(expression.e1.type);
        if (!targetFacts.isIntegral)
            throw new SnakebiteException(
                text("interpreter cannot assign to `",
                    expression.e1.toString, "`: `", expression.toString,
                    "`"),
            );

        void* target;
        try {
            target = addressOf(expression.e1);
        } catch (SnakebiteException) {
            throw new SnakebiteException(
                text("interpreter cannot assign to `",
                    expression.e1.toString, "`: `", expression.toString,
                    "`"),
            );
        }
        const stepFacts = factsOf(expression.e2.type);
        const step = asIntegral(expression.e2, stepFacts);
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

        const facts = factsOf(expression.e1.type);
        if (!facts.isIntegral)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: `", expression.e1.toString,
                    "` is not an integral lvalue"),
            );

        auto target = addressOf(expression.e1);
        const step = asIntegral(expression.e2);
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
                throw new SnakebiteException(
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
        const a = asIntegral(expression.e1, aFacts);
        const b = asIntegral(expression.e2, bFacts);
        const answer = sharedSignedness(aFacts, bFacts, expression)
            ? mixin("cast(ulong) a " ~ op ~ " cast(ulong) b")
            : mixin("a " ~ op ~ " b");

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    override void visit(LogicalExp expression) {
        import snakebite.nativelayout: storeIntegral;

        const left = asIntegral(expression.e1) != 0;
        const answer = expression.op == EXP.andAnd
            ? left && asIntegral(expression.e2) != 0
            : left || asIntegral(expression.e2) != 0;

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    // dmd's usual arithmetic conversions give both operands the same type.
    // Integral equality can therefore compare the common representation,
    // while floating equality must compare values: positive and negative
    // zero have different representations but compare equal in D.
    override void visit(EqualExp expression) {
        import core.stdc.string: memcmp;
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (expression.op != EXP.equal && expression.op != EXP.notEqual)
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        // DMD's `Type.nextOf` is not const-correct, so this cannot be const.
        auto type = expression.e1.type;
        if (type.ty == Tarray) {
            // DMD lowers arrays whose elements need semantic equality to a
            // call that performs it. A missing lowering is DMD's proof that
            // these element types are trivially byte-comparable.
            if (expression.lowering !is null) {
                evaluate(
                    expression.lowering,
                    expression.lowering.type,
                    factsOf(expression.lowering.type),
                    _place,
                );
                return;
            }

            const a = evaluateArray(expression.e1, factsOf(type));
            const b = evaluateArray(
                expression.e2, factsOf(expression.e2.type));
            const bytes = a.length * factsOf(type.nextOf).size;
            const equal = a.length == b.length
                && (bytes == 0 || memcmp(a.elements, b.elements, bytes) == 0);
            const answer = expression.op == EXP.equal ? equal : !equal;

            storeIntegral(_place, answer ? 1 : 0, _facts.size);
            return;
        }

        bool equal;
        if (type.ty == Tfloat32 || type.ty == Tfloat64)
            equal = asFloating(expression.e1) == asFloating(expression.e2);
        else if (factsOf(type).isIntegral)
            equal = asIntegral(expression.e1) == asIntegral(expression.e2);
        else
            throw new SnakebiteException(
                text("interpreter cannot compare `", expression.toString,
                    "`: its operands are of type `", type.toString, "`"),
            );

        const answer = expression.op == EXP.equal ? equal : !equal;

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    // `is`/`!is`. Over most types it means the same thing `==`/`!=` does,
    // but a pointer is not `isIntegral`, so `asIntegral` cannot read
    // one - `ptr is null`, on the `~=` lowering's own chain, needs the
    // pointer's own bits read instead.
    override void visit(IdentityExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (expression.op != EXP.identity && expression.op != EXP.notIdentity)
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        auto type = expression.e1.type;
        bool equal;
        if (type.ty == Tclass)
            equal = classReferenceOf(expression.e1)
                == classReferenceOf(expression.e2);
        else if (type.ty == Tpointer)
            equal = asPointer(expression.e1) == asPointer(expression.e2);
        else if (factsOf(type).isIntegral)
            equal =
                asIntegral(expression.e1) == asIntegral(expression.e2);
        else
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its operands are of type `", type.toString, "`"),
            );

        const answer = expression.op == EXP.identity ? equal : !equal;

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    override void visit(AddExp expression) {
        import snakebite.nativelayout: storeIntegral;

        const lhsPointer = expression.e1.type.ty == Tpointer;
        const rhsPointer = expression.e2.type.ty == Tpointer;
        if (expression.type.ty == Tpointer
                && ((lhsPointer && factsOf(expression.e2.type).isIntegral)
                    || (rhsPointer && factsOf(expression.e1.type).isIntegral))) {
            void* pointer;
            long offset;
            if (lhsPointer) {
                pointer = asPointer(expression.e1);
                offset = asIntegral(expression.e2);
            } else {
                offset = asIntegral(expression.e1);
                pointer = asPointer(expression.e2);
            }
            const result = cast(ubyte*) pointer + cast(long) offset;

            storeIntegral(_place, cast(size_t) result, _facts.size);
            return;
        }

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

        // Every operator that can carry a floating type out of dmd's
        // semantic pass: the bitwise and shift operators are rejected by
        // the frontend on floating operands, so the `static if` only
        // keeps their mixins compilable, it refuses nothing. Both
        // operands already share the expression's own type - dmd's usual
        // arithmetic conversions convert them before any backend runs -
        // and a `float` read widened to `double` is exact, so narrowing
        // each operand back to `float` recovers it exactly and the
        // operation then rounds once, in the expression's own precision,
        // the same single rounding compiled D performs.
        static if (op == "+" || op == "-" || op == "*" || op == "/"
                || op == "%")
            if (_type.ty == Tfloat32 || _type.ty == Tfloat64) {
                const a = asFloating(expression.e1);
                const b = asFloating(expression.e2);
                if (_type.ty == Tfloat32)
                    *cast(float*) _place =
                        mixin("cast(float) a " ~ op ~ " cast(float) b");
                else
                    *cast(double*) _place = mixin("a " ~ op ~ " b");
                return;
            }

        if (!_facts.isIntegral)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its type is `", expression.type.toString, "`"),
            );

        const aFacts = factsOf(expression.e1.type);
        const bFacts = factsOf(expression.e2.type);
        const a = asIntegral(expression.e1, aFacts);
        const b = asIntegral(expression.e2, bFacts);

        storeIntegral(
            _place, combine!op(a, b, aFacts, bFacts, expression), _facts.size);
    }

    // As `asIntegral`, for a floating operand. The value comes back as a
    // `double` because a `float` widens to `double` exactly, so the one
    // return type carries either width without loss; the caller narrows
    // back when the operation itself is `float`-precision.
    private double asFloating(Expression expression) {
        import std.conv: text;

        auto type = expression.type;
        if (type.ty != Tfloat32 && type.ty != Tfloat64)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as floating point: its type is `", type.toString,
                    "`"),
            );

        const facts = factsOf(type);
        align(double.alignof) ubyte[double.sizeof] buffer = void;
        evaluate(expression, type, facts, buffer.ptr);

        return type.ty == Tfloat32
            ? *cast(float*) buffer.ptr
            : *cast(double*) buffer.ptr;
    }

    // `-x` and `~x` leave the same low bits whether the operand was read as
    // signed or unsigned, so neither needs the operand's own facts.
    private extern(D) void storeUnaryExp(string op)(UnaExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (!_facts.isIntegral)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its type is `", expression.type.toString, "`"),
            );

        const a = asIntegral(expression.e1);

        storeIntegral(_place, cast(ulong) mixin(op ~ "a"), _facts.size);
    }

    // `asIntegral` already sign- or zero-extends the operand to 64
    // bits per its own signedness, so storing the destination's low bytes
    // of that value is correct whichever way the width changes - the same
    // widen-then-truncate the `combine`d binary operators already rely on,
    // just with the two types differing instead of matching. A pointer
    // cast reinterprets the same bits at their native width instead: a
    // pointer's representation does not depend on its pointee, so no
    // conversion is needed, only a copy. A dynamic-array-to-dynamic-array
    // cast is the same idea again *when the element size does not
    // change*: druntime's own append hooks cast their result across a
    // change of qualifiers alone (`Tarr` to `Unqual_Tarr` and back),
    // never a change of element type, so the two share the same
    // `{length, ptr}` layout and the cast is a copy too. A change of
    // element size - `T[]` to `void[]`, which the same append hooks also
    // do, to pass a `void[]` byte range through hooks with no reason to
    // know the element type - is not that cast: D defines it as scaling
    // the length by the ratio of the two element sizes, not copying it
    // verbatim, and that scaling is what this does below. `arr.ptr` is
    // handled too, further down, since dmd lowers it into a `Tarray` to
    // `Tpointer` cast over the array itself. An integral-to-floating
    // cast rounds the operand's mathematical value to the destination's
    // own precision, read as signed or unsigned per the operand's type -
    // the host's own `cast(float)`/`cast(double)` is exactly that
    // conversion, so it is applied per destination width rather than
    // through a shared wider intermediate, which for `float` would round
    // twice. Anything else this node could mean - a class downcast, a
    // floating-to-integral cast - is refused the same way an unhandled
    // node already is.
    override void visit(CastExp expression) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, storeIntegral;
        import std.conv: text;

        auto sourceType = expression.e1.type;

        if (sourceType.ty == Tclass && _type.ty == Tclass) {
            auto value = classReferenceOf(expression.e1);
            if (value is null) {
                storeIntegral(_place, 0, _facts.size);
                return;
            }

            auto actual = value in _classes;
            auto target = _type.isTypeClass.sym;
            const matches = actual is null
                ? target is sourceType.isTypeClass.sym
                : target is *actual
                    || target.isBaseOf(*actual, null);
            storeIntegral(
                _place,
                matches ? cast(size_t) value : 0,
                _facts.size,
            );
            return;
        }

        if (sourceType.ty == Tpointer && _type.ty == Tpointer) {
            evaluate(expression.e1, sourceType, factsOf(sourceType), _place);
            return;
        }

        if (sourceType.ty == Tsarray && _type.ty == Tarray
                && sourceType.nextOf.equals(_type.nextOf)) {
            import snakebite.nativelayout:
                arrayLengthOffset, arrayPointerOffset, storeIntegral;

            const sourceFacts = factsOf(sourceType);
            const elementSize = factsOf(sourceType.nextOf).size;
            const length = sourceFacts.size / elementSize;
            auto bytes = cast(ubyte*) _place;
            storeIntegral(
                bytes + arrayLengthOffset, length, size_t.sizeof);
            *cast(void**) (bytes + arrayPointerOffset) =
                addressOf(expression.e1);
            return;
        }

        if (sourceType.ty == Tarray && _type.ty == Tarray) {
            const sourceElementSize = factsOf(sourceType.nextOf).size;
            const destElementSize = factsOf(_type.nextOf).size;

            if (sourceElementSize == destElementSize) {
                evaluate(
                    expression.e1, sourceType, factsOf(sourceType), _place);
                return;
            }

            // D reinterprets the same bytes at the new element width, so
            // the byte count - not the element count - is what has to
            // stay the same across the cast. `newlength` is truncated,
            // the same truncation `object.d`'s own `T[] to U[]` cast
            // does, rather than refused on a remainder: a remainder means
            // the source array's byte length is not a whole number of
            // destination elements, which is druntime's call to make, not
            // this interpreter's.
            const value = evaluateArray(expression.e1, factsOf(sourceType));
            const newLength =
                value.length * sourceElementSize / destElementSize;

            auto bytes = cast(ubyte*) _place;
            storeIntegral(
                bytes + arrayLengthOffset, newLength, size_t.sizeof);
            *cast(const(void)**) (bytes + arrayPointerOffset) =
                value.elements;
            return;
        }

        // `arr.ptr` is not a real member: `.ptr` is one of the two
        // properties dmd recognises directly on a dynamic array, and its
        // semantic pass lowers a read of it into exactly this cast, over
        // the array itself rather than a `.ptr` access node - reading the
        // array's own pointer word is what this cast means, not an
        // arbitrary reinterpretation of the array's bytes as a `T*`.
        // `_d_arrayappendcTX_`, on the `~=` lowering's own chain, reads
        // `px.ptr` this way to ask the GC what it already knows about the
        // block backing the array being grown.
        if (sourceType.ty == Tarray && _type.ty == Tpointer
                && sourceType.nextOf.equals(_type.nextOf)) {
            const bytes = cast(ubyte*) addressOf(expression.e1);
            const value = *cast(void**) (bytes + arrayPointerOffset);
            storeIntegral(
                _place, cast(size_t) value, _facts.size);
            return;
        }

        const sourceFacts = factsOf(sourceType);

        // dmd classifies `bool` as `integral | unsigned` (`mtype.d`), so
        // without this check the branch below would take it as an
        // ordinary integral-to-integral narrowing and store the operand's
        // low byte. D specifies `cast(bool) x` as `x != 0`, not "keep the
        // low byte": `cast(bool) 256` is `true` in D, not the `false` a
        // truncation would store, and a truncation can also store a value
        // like `2` in a `bool` slot that no compiled D ever produces.
        if (sourceFacts.isIntegral && _type.ty == Tbool) {
            const value = asIntegral(expression.e1, sourceFacts);
            storeIntegral(_place, value != 0, _facts.size);
            return;
        }

        if (sourceFacts.isIntegral && _facts.isIntegral) {
            storeIntegral(
                _place,
                asIntegral(expression.e1, sourceFacts),
                _facts.size,
            );
            return;
        }

        if (sourceFacts.isIntegral
                && (_type.ty == Tfloat32 || _type.ty == Tfloat64)) {
            const value = asIntegral(expression.e1, sourceFacts);
            if (_type.ty == Tfloat32)
                *cast(float*) _place = sourceFacts.isUnsigned
                    ? cast(float) cast(ulong) value
                    : cast(float) value;
            else
                *cast(double*) _place = sourceFacts.isUnsigned
                    ? cast(double) cast(ulong) value
                    : cast(double) value;
            return;
        }

        throw new SnakebiteException(
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
    // `&x[length]`, on the `~=` lowering's own chain (`_d_arrayappendT`
    // finds where the copied-in elements start this way), is the same
    // question as any other `&lvalue`: `addressOf` already answers it for
    // a variable, a dereference, a `ref`-typed branch or call, and an
    // index - this just stores whichever one it finds as a `size_t`, the
    // way any other pointer value is stored.
    override void visit(AddrExp expression) {
        import snakebite.nativelayout: storeIntegral;

        storeIntegral(
            _place, cast(size_t) addressOf(expression.e1), _facts.size);
    }

    // `*p`: the address `p` evaluates to is not this expression's own
    // destination - `_place`/`_facts` here are the pointee's, `int` for an
    // `int*` - so the pointer itself is read into a scratch register first
    // (`asPointer`), the same two-step `addressOf` uses to find
    // where `*p = ...` writes.
    override void visit(PtrExp expression) {
        import core.stdc.string: memcpy;

        memcpy(_place, asPointer(expression.e1), _facts.size);
    }

    // `info.base`: an aggregate field read. The field's own byte offset is
    // `expression.var.offset`, laid out by dmd's own native semantics, not
    // recomputed here.
    override void visit(DotVarExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        auto field = expression.var.isVarDeclaration;
        if (field is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only a field read is supported"),
            );

        // `field.offset` below is a whole-byte offset. A bitfield is also
        // a `VarDeclaration`, but its storage is a sub-byte slice of that
        // offset's byte, which a plain `memcpy` from it would read as
        // whole bytes instead - refused rather than run to a wrong
        // answer, the same way an unhandled node already is.
        if (field.isBitFieldDeclaration !is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: reading a bitfield is not supported"),
            );

        auto base = cast(ubyte*) fieldBaseAddress(expression.e1);
        memcpy(_place, base + field.offset, _facts.size);
    }

    private void* fieldBaseAddress(Expression aggregate) {
        if (aggregate.type.ty != Tclass)
            return addressOf(aggregate);

        const facts = factsOf(aggregate.type);
        assert(facts.size == size_t.sizeof,
            "a class reference is not one word on this target");
        void* object;
        evaluate(aggregate, aggregate.type, facts, &object);
        return object;
    }

    // `typeid(int)`: a class reference to a singleton dmd's glue layer -
    // codegen, which this interpreter has none of - would normally
    // conjure the storage for. dmd's frontend has already worked out
    // that singleton's identity by the time it hands this node over
    // (`Type.vtinfo`, set by `semanticTypeInfo` during this very node's
    // own semantic pass), and that identity's own `ident` already spells
    // its linker name: `TypeInfoDeclaration` is declared `extern(C)` with
    // that identifier standing in directly for a mangled name
    // (`declaration.d`'s `getTypeInfoIdent`), not a plain D identifier
    // this evaluator would have to mangle itself. Resolving it is then
    // the same question `execute`'s FFI branch already asks of any other
    // symbol compiled elsewhere: is it in this process.
    override void visit(TypeidExp expression) {
        import dmd.dtemplate: isType;
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        auto type = isType(expression.obj);
        if (type is null || type.vtinfo is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only `typeid` of a resolved type is supported"),
            );

        auto name = type.vtinfo.ident.toString;
        countForeignNameLookup;
        auto address = _plans.resolve(name);
        if (address is null)
            throw new SnakebiteException(
                text("interpreter cannot resolve the symbol `", name,
                    "` for `", expression.toString,
                    "`: it is not in this process"),
            );

        storeIntegral(_place, cast(size_t) address, _facts.size);
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
            throw new SnakebiteException(
                text("interpreter cannot execute the halt `",
                    expression.toString, "`"),
            );

        if (truthOf(expression.e1))
            return;

        import core.exception: AssertError;

        // What D does here is throw an `AssertError` the guest can catch.
        // Keep it inside an interpreter-owned wrapper so a guest catch does
        // not also catch the interpreter's own unsupported-node failures.
        auto guest = new AssertError(
            text("interpreter: assertion failed: `", expression.toString,
                "`"),
            __FILE__,
            __LINE__,
        );
        throw new GuestException(guest);
    }

    override void visit(ThrowExp expression) {
        throwGuest(expression.e1);
    }

    private void throwGuest(Expression expression) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        if (expression.type.ty != Tclass)
            throw new SnakebiteException(
                text("interpreter cannot throw `", expression.toString,
                    "`: it is not a class reference"),
            );

        const facts = factsOf(expression.type);
        align(size_t.sizeof) ubyte[size_t.sizeof] value = void;
        evaluate(expression, expression.type, facts, value.ptr);

        auto guest = cast(Throwable) cast(void*) loadIntegral(
            value.ptr, facts.size, false,
        );
        if (guest is null)
            throw new SnakebiteException(
                text("interpreter cannot throw `", expression.toString,
                    "`: it is null"),
            );

        auto classDeclaration = cast(void*) guest in _classes;
        throw new GuestException(
            guest,
            classDeclaration is null ? null : *classDeclaration,
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

        // A static array's own storage is already contiguous elements,
        // not a `{length, ptr}` pair to a block elsewhere - `newCapacity`,
        // on the `~=` lowering's own chain, indexes a `static immutable`
        // lookup table this shape. The two differ only in how the
        // elements' base address and count are found; the bounds check
        // and the read below are the same read either way.
        if (array.type.ty == Tsarray) {
            const length = cast(size_t) array.type.isTypeSArray.dim.toInteger;
            const index = indexOf(expression, length);
            if (index < 0 || cast(size_t) index >= length)
                throw new SnakebiteException(
                    text("interpreter cannot index `", array.toString,
                        "` at ", index, ": the array is ", length,
                        " long"),
                );

            const stride = factsOf(array.type.nextOf).size;
            assert(stride == _facts.size, "an index changed width");

            auto base = cast(ubyte*) addressOf(array);
            memcpy(_place, base + index * stride, stride);
            return;
        }

        // `indexAddressOf` does the same evaluate-index-bounds-check-
        // stride work an assignment's left side (`addressOf`) needs to
        // find this same element's address; a read just copies out of it
        // instead of writing through it. Compiled D throws a `RangeError`
        // on an out-of-range index, which needs guest exceptions this
        // interpreter does not have - `indexAddressOf` refuses instead,
        // since an unchecked read would hand back a byte of the host's
        // own memory as a guest value, or fault the host process
        // outright.
        //
        // The array's own element width, not the destination's: they
        // agree only because dmd wraps this in a `CastExp` for any change
        // of width, and `cast` is refused.
        const element = indexAddressOf(expression);
        assert(element.stride == _facts.size, "an index changed width");

        memcpy(_place, element.ptr, element.stride);
    }

    private long indexOf(IndexExp expression, in size_t length) {
        auto lengthVar = expression.lengthVar;
        if (lengthVar is null)
            return asIntegral(expression.e2);

        // An index nested in this one - or one a guest call from here
        // reaches - binds its own `$`, so this one's is put back rather
        // than cleared. `auto`, not `const`: a `const` copy of a struct
        // holding a reference cannot be assigned back.
        auto outer = _dollar;
        scope(exit) _dollar = outer;
        _dollar = Dollar(lengthVar, length);

        return asIntegral(expression.e2);
    }

    // `ptr[0 .. newlength]`: a dynamic array built from a pointer and a
    // bound, rather than sliced from an existing array's own bytes -
    // `_d_arrayappendcTX_`, on the `~=` lowering's own chain, does this
    // once GC.malloc hands it fresh storage, to turn that raw pointer
    // back into the array the guest sees. Slicing an existing array
    // (rather than a bare pointer) works the same way, just starting
    // from that array's own base and length instead of an unbounded one.
    override void visit(SliceExp expression) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, storeIntegral;
        import std.conv: text;

        auto array = expression.e1;
        auto sourceType = array.type;

        ubyte* base;
        size_t sourceLength;
        bool knownLength;
        if (sourceType.ty == Tpointer) {
            base = cast(ubyte*) asPointer(array);
        } else if (sourceType.ty == Tarray) {
            const value = evaluateArray(array, factsOf(sourceType));
            base = cast(ubyte*) value.elements;
            sourceLength = value.length;
            knownLength = true;
        } else
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only slicing a pointer or a dynamic array is ",
                    "supported"),
            );

        auto lengthVar = expression.lengthVar;
        auto outerDollar = _dollar;
        scope(exit) if (lengthVar !is null) _dollar = outerDollar;
        if (lengthVar !is null) {
            if (!knownLength)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `",
                        expression.toString, "`: `$` has no meaning ",
                        "slicing a pointer"),
                );

            _dollar = Dollar(lengthVar, sourceLength);
        }

        const lo = expression.lwr is null ? 0 : asIntegral(expression.lwr);
        const hi = expression.upr is null
            ? cast(long) sourceLength : asIntegral(expression.upr);

        if (lo < 0 || hi < lo
                || (knownLength && cast(size_t) hi > sourceLength))
            throw new SnakebiteException(
                text("interpreter cannot slice `", array.toString, "` [",
                    lo, " .. ", hi, "]"),
            );

        const stride = factsOf(sourceType.nextOf).size;
        auto bytes = cast(ubyte*) _place;
        storeIntegral(
            bytes + arrayLengthOffset, cast(size_t) (hi - lo), size_t.sizeof);
        *cast(ubyte**) (bytes + arrayPointerOffset) = base + lo * stride;
    }

    // `_d_arrayliteralTX`, the druntime hook real compiled D calls for a
    // heap array literal, has no `FuncDeclaration` and no call node: dmd's
    // `e2ir.d` conjures it by name only once it has already decided to
    // lower an `ArrayLiteralExp` this way, so there is nothing here to
    // interpret or call through. What that lowering does, though, is
    // exactly what a tree-walking evaluator can do on its own: allocate
    // room for the elements and evaluate each one into its slot. The room
    // this evaluator allocates is a GC block, the same storage
    // `staticSlotOf` already hands a `static` variable - a frame slot
    // would vanish with the call that made it, and this literal's
    // elements need to survive at least as long as whatever slice they
    // are assigned to, `static` or not.
    override void visit(ArrayLiteralExp expression) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, storeIntegral;
        import std.conv: text;

        // A static array's elements are its own bytes, written straight
        // into `_place` - unlike a dynamic array literal, nothing is
        // allocated, because the destination already is the storage:
        // `newCapacity`'s `static immutable multTable`, on the `~=`
        // lowering's own chain, is one of these - dmd's own CTFE engine
        // has already run its `(){ ... }()` initialiser and left this
        // evaluator a plain literal of the result to place, the same as
        // any other static's initializer (`staticSlotOf`).
        if (_type.ty == Tsarray) {
            auto elementType = _type.nextOf;
            const elementFacts = factsOf(elementType);
            const length = expression.elements is null
                ? 0 : expression.elements.length;
            auto bytes = cast(ubyte*) _place;

            foreach (i; 0 .. length)
                evaluate(
                    elementAt(expression, i), elementType, elementFacts,
                    bytes + i * elementFacts.size);
            return;
        }

        if (_type.ty != Tarray)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as a `", _type.toString, "`: only a dynamic array ",
                    "literal is supported"),
            );

        auto elementType = _type.nextOf;
        const elementFacts = factsOf(elementType);
        const length = expression.elements is null
            ? 0 : expression.elements.length;

        ubyte* elements = null;
        if (length > 0) {
            const blockSize = elementFacts.size * length;
            auto block = new void[](blockSize);
            foreach (i; 0 .. length)
                evaluate(
                    elementAt(expression, i), elementType, elementFacts,
                    cast(ubyte*) block.ptr + i * elementFacts.size);
            elements = cast(ubyte*) block.ptr;
        }

        auto bytes = cast(ubyte*) _place;
        storeIntegral(bytes + arrayLengthOffset, length, size_t.sizeof);
        *cast(ubyte**) (bytes + arrayPointerOffset) = elements;
    }

    override void visit(NewExp expression) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, storeIntegral;
        import std.conv: text;

        auto arguments = expression.arguments;
        if (expression.type.ty == Tclass) {
            const classType = expression.newtype.isTypeClass;
            if (classType is null || expression.placement !is null
                    || expression.thisexp !is null)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `", expression.op,
                        "` expression: `", expression.toString, "`"),
                );

            auto declaration = cast(ClassDeclaration) classType.sym;
            const alignment = declaration.alignsize == 0
                ? 1 : declaration.alignsize;
            const padding = alignment - 1;
            if (declaration.structsize > size_t.max - padding)
                throw new SnakebiteException(
                    text("interpreter cannot allocate `",
                        expression.toString, "`: its alignment padding " ~
                        "overflows `size_t`"),
                );

            auto allocation = new ubyte[](declaration.structsize + padding);
            _allocations ~= allocation;
            const start = -cast(size_t) allocation.ptr
                & (alignment - 1);
            auto object = cast(ubyte*) allocation.ptr + start;

            import core.stdc.string: memset;
            memset(object, 0, declaration.structsize);
            *cast(void**) object = classRuntimeInfo(declaration).vtbl.ptr;
            initializeClass(declaration, object, expression.loc);
            _classes[object] = declaration;

            if (expression.member !is null)
                constructClass(expression, object);

            storeIntegral(_place, cast(size_t) object, _facts.size);
            return;
        }

        if (expression.type.ty != Tarray || arguments is null
                || arguments.length != 1)
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        auto elementType = expression.type.nextOf;
        const elementFacts = factsOf(elementType);

        const length = cast(size_t) asIntegral((*arguments)[0]);
        if (elementFacts.size != 0 && length > size_t.max / elementFacts.size)
            throw new SnakebiteException(
                text("interpreter cannot allocate `", expression.toString,
                "`: its byte size overflows `size_t`"),
            );

        const dataSize = length * elementFacts.size;
        const padding = elementFacts.alignment - 1;
        if (dataSize > size_t.max - padding)
            throw new SnakebiteException(
                text("interpreter cannot allocate `", expression.toString,
                    "`: its alignment padding overflows `size_t`"),
            );

        ubyte* elements;
        if (dataSize != 0) {
            auto allocation = new ubyte[](dataSize + padding);
            _allocations ~= allocation;

            const start = -cast(size_t) allocation.ptr
                & (elementFacts.alignment - 1);
            elements = cast(ubyte*) allocation.ptr + start;

            foreach (i; 0 .. length) {
                try
                    initializeDefault(
                        elementType,
                        elementFacts,
                        elements + i * elementFacts.size,
                        expression.loc,
                    );
                catch (SnakebiteException exception)
                    throw new SnakebiteException(
                        text("interpreter cannot initialize an array of `",
                            elementType.toString, "` from its `.init`: ",
                            exception.msg),
                    );
            }
        }

        auto bytes = cast(ubyte*) _place;
        storeIntegral(bytes + arrayLengthOffset, length, size_t.sizeof);
        *cast(ubyte**) (bytes + arrayPointerOffset) = elements;
    }

    private TypeInfo_Class classRuntimeInfo(ClassDeclaration declaration) {
        if (declaration is ClassDeclaration.object)
            return typeid(Object);

        foreach (runtime; _classRuntime)
            if (runtime.declaration is declaration)
                return runtime.typeInfo;

        import std.conv: text;

        if (hasGuestVirtualDispatch(declaration))
            throw new SnakebiteException(
                text("interpreter cannot construct `",
                    declaration.toPrettyChars,
                    "`: guest virtual/interface dispatch is not supported"),
            );

        TypeInfo_Class baseInfo;
        if (declaration.baseClass is null
                || declaration.baseClass is ClassDeclaration.object)
            baseInfo = typeid(Object);
        else if (declaration.baseClass is ClassDeclaration.throwable)
            baseInfo = typeid(Throwable);
        else if (declaration.baseClass is ClassDeclaration.exception
                || (ClassDeclaration.exception !is null
                    && ClassDeclaration.exception.isBaseOf(
                        declaration.baseClass, null)))
            baseInfo = typeid(Exception);
        else if (declaration.baseClass is ClassDeclaration.errorException
                || (ClassDeclaration.errorException !is null
                    && ClassDeclaration.errorException.isBaseOf(
                        declaration.baseClass, null)))
            baseInfo = typeid(Error);
        else
            baseInfo = classRuntimeInfo(declaration.baseClass);

        auto typeInfo = new TypeInfo_Class;
        typeInfo.name = cast(string) declaration.toPrettyChars.toDString;
        typeInfo.base = baseInfo;
        typeInfo.vtbl = new void*[baseInfo.vtbl.length];
        typeInfo.vtbl[] = baseInfo.vtbl[];
        typeInfo.vtbl[0] = cast(void*) typeInfo;
        typeInfo.m_init = new byte[](declaration.structsize);
        *cast(void**) typeInfo.m_init.ptr = typeInfo.vtbl.ptr;

        _classRuntime ~= GuestClassRuntime(
            declaration,
            typeInfo,
            typeInfo.vtbl,
        );
        return typeInfo;
    }

    private bool hasGuestVirtualDispatch(ClassDeclaration declaration) {
        if (declaration.interfaces.length != 0)
            return true;
        if (declaration.baseClass is null
                || declaration.baseClass is ClassDeclaration.object)
            return false;
        if (declaration.vtbl.length != declaration.baseClass.vtbl.length)
            return true;
        foreach (i; 0 .. declaration.vtbl.length)
            if (declaration.vtbl[i] !is declaration.baseClass.vtbl[i])
                return true;
        return false;
    }

    private void initializeClass(
        ClassDeclaration declaration,
        ubyte* object,
        in Loc loc,
    ) {
        if (declaration.baseClass !is null)
            initializeClass(declaration.baseClass, object, loc);

        foreach (field; declaration.fields) {
            if (field._init is null)
                continue;

            auto initializer = field._init.isExpInitializer;
            if (initializer is null || field._init.isVoidInitializer !is null)
                continue;

            auto facts = factsOf(field.type);
            evaluate(
                initializerValueOf(initializer),
                field.type,
                facts,
                object + field.offset,
            );
        }
    }

    private void constructClass(NewExp expression, ubyte* object) {
        import std.conv: text;

        auto constructor = expression.member;
        auto layout = layoutOf(constructor);
        auto frame = _frames.push(layout.size, layout.alignment);

        import snakebite.nativelayout: storeIntegral;

        if (constructor.vthis is null)
            throw new SnakebiteException(
                text("interpreter cannot call class constructor `",
                    constructor.toString, "`: it has no `this`"),
            );

        storeIntegral(
            frame.base + layout.hiddenThis.parameter.offset,
            cast(size_t) object,
            size_t.sizeof,
        );

        auto parameters = typeFunctionOf(constructor).parameterList;
        auto arguments = expression.arguments;
        const argumentCount = arguments is null ? 0 : arguments.length;
        if (argumentCount != parameters.length)
            throw new SnakebiteException(
                text("interpreter: `", constructor.toString, "` expects ",
                    parameters.length, " argument(s), got ", argumentCount),
            );

        foreach (i; 0 .. parameters.length) {
            auto parameter = layout.parameters[i];
            evaluate(
                (*arguments)[i],
                parameters[i].type,
                parameter.facts,
                frame.base + parameter.offset,
            );
        }

        execute(constructor, null, frame.base, layout, null, true);
    }

    private void initializeDefault(
        Type type,
        in TypeFacts facts,
        ubyte* place,
        in Loc loc,
    ) {
        import core.stdc.string: memset;
        import dmd.typesem: defaultInit;
        import std.conv: text;

        auto structType = type.isTypeStruct;
        if (structType !is null && structType.sym.zeroInit) {
            memset(place, 0, facts.size);
            return;
        }

        auto initializer = defaultInit(type, loc);
        if (initializer is null)
            throw new SnakebiteException(
                text("interpreter cannot initialize `", type.toString,
                    "`: its `.init` has no expression"),
            );

        evaluate(initializer, type, facts, place);
    }

    override void visit(StructLiteralExp expression) {
        import core.stdc.string: memset;
        import std.conv: text;

        auto structType = _type.isTypeStruct;
        if (structType is null || structType.sym != expression.sd
                || !supportsStruct(_type))
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: unsupported struct literal"),
            );

        memset(_place, 0, _facts.size);
        if (expression.elements is null || expression.elements.length == 0)
            return;

        if (expression.elements.length > expression.sd.fields.length)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its fields do not match the struct layout"),
            );

        foreach (i, element; *expression.elements) {
            if (element is null)
                continue;

            auto field = expression.sd.fields[i];
            evaluate(
                element,
                field.type,
                factsOf(field.type),
                cast(ubyte*) _place + field.offset,
            );
        }
    }

    // `expression.elements`, dmd documents, "can be sparse" whenever
    // `basis` is set - a default-init literal for a static array
    // (`typesem.d`'s `TypeSArray.defaultInitLiteral`) is exactly that: an
    // array of `null`s with `basis` holding the one fill value every
    // element takes. Indexing `elements` directly, as both branches of
    // `visit(ArrayLiteralExp)` above used to, reads that `null` straight
    // through; `expression[i]` is dmd's own `opIndex`, which falls back
    // to `basis` for a sparse entry the way every other reader of an
    // `ArrayLiteralExp` is expected to. The result can still be `null` -
    // sparse without a `basis` is not a case this interpreter has a guest
    // program that reaches - so this refuses rather than handing
    // `evaluate` a null `Expression` to dereference.
    private Expression elementAt(ArrayLiteralExp expression, size_t i) {
        import std.conv: text;

        auto element = expression[i];
        if (element is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate element ", i, " of `",
                    expression.toString, "`: it is sparse with no `basis` ",
                    "fill value"),
            );

        return element;
    }

    // `~=` has no `FuncDeclaration` and no call node of its own either,
    // but for a different reason than `ArrayLiteralExp`: dmd's semantic
    // pass, not its glue layer, already rewrites `arr ~= x` into a call to
    // `_d_arrayappendcTX` or `_d_arrayappendT` (`dmd/expression.d`'s
    // `CatAssignExp.lowering`) - a real AST subtree naming a real,
    // interpretable `FuncDeclaration`, just not one any visitor reaches by
    // walking `expression`'s own children. Evaluating `lowering` instead
    // of `expression` is therefore not a special case for `~=`: it is
    // running the same tree-walking evaluator over the tree dmd already
    // built, one dmd itself picked over the operator syntax. Nothing
    // refuses `~=` by name; a `~=` semantic analysis left unlowered, if
    // one exists, still falls through to the "cannot evaluate" refusal
    // below.
    override void visit(CatAssignExp expression) {
        import std.conv: text;

        if (expression.lowering is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        expression.lowering.accept(this);
    }

    // An associative-array literal has no glue-layer codegen of its own to
    // interpret either: dmd's semantic pass lowers it to a call to
    // `object._d_assocarrayliteralTX!(K, V)` (`AssocArrayLiteralExp.lowering`),
    // built from the very same key and value `ArrayLiteralExp`s the guest
    // wrote, the same way `~=` is lowered to a call rather than left as an
    // operator this interpreter would otherwise have to build the runtime
    // representation for itself. Evaluating `lowering` runs that call
    // through the ordinary `CallExp` path, which resolves it as
    // already-compiled druntime code the same way any other FFI call is
    // resolved.
    override void visit(AssocArrayLiteralExp expression) {
        import std.conv: text;

        if (expression.lowering is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only a lowered associative-array literal is ",
                    "supported"),
            );

        expression.lowering.accept(this);
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
    // used, so this is the one place a `ref`-returning *guest* call is told
    // apart from an ordinary one when its value, not its address, is
    // wanted (see `addressOf`/`refCallAddress` for the other one). Two
    // more places check the same `isRef`, for the opposite reason -
    // refusing rather than running: `Evaluator.call`, the host entry
    // point, since the host is never the guest `CallExp` this branch
    // reads through, and `ffi/plan.d`'s `prepare`, since an
    // `extern(C)`-declared `ref`-returning function has no guest body for
    // this branch to run in the first place.
    override void visit(CallExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        auto function_ = expression.f;
        if (function_ is null)
            function_ = calleeOf(expression);

        // Whether this call needs a `this` or a static chain it cannot
        // provide is `execute`'s check, not this one - it runs there for
        // every call this backend makes, not only ones that arrive as a
        // guest `CallExp`.
        auto layout = layoutOf(function_);
        auto frame = bindFrame(expression, function_, layout);

        if (typeFunctionOf(function_).isRef) {
            memcpy(
                _place,
                resolvedRefAddress(function_, frame.base, layout, expression),
                _facts.size);
            return;
        }

        execute(
            function_, _place, frame.base, layout, expression,
            function_.isCtorDeclaration() !is null,
        );
    }

    // The callee of a call dmd left unresolved: one reached through a
    // value rather than a name, which for this interpreter means a
    // delegate. The value's function word is the declaration
    // `visit(FuncExp)` stored, read back here. A non-null context word
    // means the delegate carries a captured frame this interpreter does
    // not represent, so it is refused by name rather than run without
    // the frame it needs.
    private FuncDeclaration calleeOf(CallExp expression) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, delegateValueSize,
            loadIntegral;
        import std.conv: text;

        auto callee = expression.e1;
        if (callee.type.ty != Tdelegate)
            throw new SnakebiteException(
                text("interpreter cannot call an unresolved function: `",
                    expression.toString, "`"),
            );

        const facts = factsOf(callee.type);
        assert(facts.size == delegateValueSize
                && facts.alignment <= size_t.sizeof,
            "a delegate is not two words on this target");

        align(size_t.sizeof) ubyte[delegateValueSize] value = void;
        evaluate(callee, callee.type, facts, value.ptr);

        const context = loadIntegral(
            value.ptr + delegateContextOffset, size_t.sizeof, false);
        if (context != 0)
            throw new SnakebiteException(
                text("interpreter cannot call `", expression.toString,
                    "`: the delegate's context is not null, and a captured ",
                    "context is not supported"),
            );

        auto function_ = cast(FuncDeclaration) cast(void*) loadIntegral(
            value.ptr + delegateFunctionOffset, size_t.sizeof, false);
        if (function_ is null)
            throw new SnakebiteException(
                text("interpreter cannot call `", expression.toString,
                    "`: the delegate is null"),
            );

        return function_;
    }

    private void* classReferenceOf(Expression expression) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        if (expression.type.ty != Tclass)
            throw new SnakebiteException(
                text("interpreter cannot use `", expression.toString,
                    "` as a class receiver"),
            );

        const facts = factsOf(expression.type);
        align(size_t.sizeof) ubyte[size_t.sizeof] value = void;
        evaluate(expression, expression.type, facts, value.ptr);
        return cast(void*) loadIntegral(value.ptr, facts.size, false);
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
            throw new SnakebiteException(
                text("interpreter: `", function_.toString, "` expects ",
                    parameterList.length, " argument(s), got ", argCount),
            );

        auto frame = _frames.push(layout.size, layout.alignment);

        // `vthis` is dmd's one declaration for both hidden context
        // kinds: a method's `this`, and a nested function's static
        // chain. Which one this callee has is what `isThis` says.
        if (function_.vthis !is null) {
            if (function_.isThis() !is null) {
                auto dot = expression.e1.isDotVarExp;
                const classDeclaration =
                    cast(ClassDeclaration) function_.isThis().isClassDeclaration;
                if (classDeclaration !is null) {
                    if (dot !is null)
                        storeIntegral(
                            frame.base + layout.hiddenThis.parameter.offset,
                            cast(size_t) classReferenceOf(dot.e1),
                            size_t.sizeof,
                        );
                    else
                        storeIntegral(
                            frame.base + layout.hiddenThis.parameter.offset,
                            cast(size_t) classReferenceOf(expression.e1),
                            size_t.sizeof,
                        );
                } else if (dot is null)
                    throw new SnakebiteException(
                        text("interpreter cannot call `", function_.toString,
                            "`: its `this` receiver is not a struct lvalue"),
                    );
                else
                    storeIntegral(
                        frame.base + layout.hiddenThis.parameter.offset,
                        cast(size_t) addressOf(dot.e1),
                        size_t.sizeof,
                    );
            } else {
                // A nested callee's `vthis` is the static link: the
                // address of the frame it is lexically nested inside,
                // exactly as compiled D passes it - found by `tryFrameOf`
                // from wherever this call itself is running, which is
                // that frame when the callee is nested directly inside
                // the caller, and reached by hopping further up the chain
                // when it is nested deeper than that. Whether the callee
                // itself reads an outer variable is not enough to decide
                // this: it may relay the link on unread to a nested call
                // of its own instead, exactly as compiled D's own relayed
                // static link does, so the walk is always attempted. It
                // can still fail to reach the enclosing frame - when the
                // caller is not itself on that static chain at all - and
                // 0 is passed in that case, which is fine for a link
                // nothing along this callee's own nested calls reads.
                auto enclosing = function_.toParent2() is null
                    ? null : function_.toParent2().isFuncDeclaration;
                if (enclosing is null)
                    throw new SnakebiteException(
                        text("interpreter cannot call `",
                            function_.toString, "`: its enclosing ",
                            "function could not be determined"),
                    );

                storeIntegral(
                    frame.base + layout.hiddenThis.parameter.offset,
                    cast(size_t) tryFrameOf(enclosing),
                    size_t.sizeof,
                );
            }
        }

        // Every argument is evaluated, even one the callee never reads,
        // since evaluating an argument can have effects. The loop already
        // has the positional index `i`, so it indexes `layout.parameters`
        // directly instead of hashing a declaration through `offsetOf` and
        // a type through `factsOf` - a parameter's type never changes
        // between calls, so `layout.parameters[i].facts` is already its
        // facts.
        foreach (i; 0 .. parameterList.length) {
            auto argument = (*arguments)[i];
            auto parameter = layout.parameters[i];
            auto slot = frame.base + parameter.offset;

            if (parameter.isRef)
                storeIntegral(
                    slot, cast(size_t) addressOf(argument), size_t.sizeof);
            else
                evaluate(
                    argument, parameterList[i].type, parameter.facts, slot);
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
        CallExp callSite = null,
    ) {
        import snakebite.nativelayout: loadIntegral;

        align(size_t.sizeof) ubyte[size_t.sizeof] resultAddress = void;
        execute(function_, resultAddress.ptr, frameBase, layout, callSite);
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
            throw new SnakebiteException(
                text("interpreter cannot call an unresolved function: `",
                    expression.toString, "`"),
            );

        if (!typeFunctionOf(function_).isRef)
            throw new SnakebiteException(
                text("interpreter cannot take the address of `",
                    expression.toString, "`: it does not return `ref`"),
            );

        auto layout = layoutOf(function_);
        auto frame = bindFrame(expression, function_, layout);
        return resolvedRefAddress(function_, frame.base, layout, expression);
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
        throw new SnakebiteException(
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
        throw new SnakebiteException(
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
        throw new SnakebiteException(
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
