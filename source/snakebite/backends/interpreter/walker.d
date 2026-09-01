module snakebite.backends.interpreter.walker;


private:

import std.conv: text;


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
    import snakebite.backends.layout: ClosureLayout, FrameLayout;
    import dmd.dclass: ClassDeclaration;
    import dmd.dstruct: StructDeclaration;
    import snakebite.framestack: FrameStack, defaultFrameCapacity;
    import snakebite.ffi:
        CallPlan, CallResult, PlanCache, maxArguments;
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import snakebite.nativelayout:
        isIntegralSize, storeValue, TypeFacts;
    import object:
        Error, Exception, Throwable, TypeInfo_Class, TypeInfo_Struct;
    import dmd.root.string: toDString;
    import dmd.astenums:
        Tarray, Tbool, Tchar, Tclass, Tdelegate, Tfloat32, Tfloat64,
        Tfloat80, Tnoreturn, Tint64, Tpointer, Tsarray, Tuns32, Tuns8,
        Tvoid, Twchar;
    import dmd.arraytypes: Expressions;
    import dmd.declaration: Declaration, VarDeclaration;
    import dmd.expression;
    import dmd.expressionsem: toInteger;
    import dmd.func: FuncDeclaration;
    import dmd.funcsem: isVirtualMethod;
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
    import dmd.typesem: isIntegral, nextOf;

    alias visit = Visitor.visit;

    // Every guest frame lives in this one frame stack, bump-allocated on
    // call and popped on return. Frames never move; overflow throws
    // loudly.
    private FrameStack _frames;
    // Each guest function's frame layout, computed once on that
    // function's first call (the cold path) and reused by every call
    // after it.
    private Cache!(FuncDeclaration, FrameLayout) _layouts;
    // Storage for locals that dmd moves out of an activation frame when it
    // decides that the frame must survive its call. The backing bytes are
    // kept in `_allocations`, so a delegate can retain this context after
    // the frame stack has popped the call.
    private Cache!(FuncDeclaration, ClosureLayout) _closures;
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
    // A non-root struct can be requested by an interpreted compiler-generated
    // function even when its native TypeInfo was omitted by the compiler. The
    // runtime object is kept by declaration so repeated `typeid` expressions
    // see one stable identity.
    private Cache!(StructDeclaration, TypeInfo_Struct) _structRuntime;
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
    // The current function's closure, or null when its locals stay in its
    // frame. A nested callee receives this pointer as its hidden context
    // when it captures a variable from this function.
    private ubyte* _closureBase;
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

        const parameterCount =
            function_.parameters is null ? 0 : function_.parameters.length;
        if (args.length != 0 || parameterCount != 0)
            throw new SnakebiteException(
                "host-to-guest arguments not yet supported by the " ~
                    "interpreter backend",
            );

        withCompilerLock({
            auto layout = layoutOf(function_);
            layout.call.rejectHostReferenceReturn(function_);
            auto frame = _frames.push(layout.size, layout.alignment);

            executeCall(function_, returnPlace, frame.base, layout);
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

    private const(ClosureLayout)* closureLayoutOf(
        FuncDeclaration function_,
    ) {
        if (auto cached = function_ in _closures)
            return cached;

        _closures[function_] = ClosureLayout.of(function_);
        return function_ in _closures;
    }

    private ubyte* allocateClosure(
        FuncDeclaration function_,
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        import core.stdc.string: memcpy, memset;
        import snakebite.nativelayout: storeIntegral;
        const closureLayout = closureLayoutOf(function_);
        const padding = closureLayout.alignment - 1;
        auto allocation = new ubyte[](closureLayout.size + padding);
        _allocations ~= allocation;

        const start = -cast(size_t) allocation.ptr
            & (closureLayout.alignment - 1);
        auto closure = allocation.ptr + start;
        memset(closure, 0, closureLayout.size);

        auto parent = function_.toParent2;
        auto parentFunction = parent is null ? null : parent.isFuncDeclaration;
        storeIntegral(
            closure,
            parentFunction is null
                ? 0 : cast(size_t) tryContextOf(parentFunction),
            size_t.sizeof,
        );

        foreach (variable; function_.closureVars) {
            if (!variable.isParameter)
                continue;

            const slot = closureLayout.slotOf(variable);
            const frameSlot = layout.offsetOf(variable);
            memcpy(
                closure + slot.offset,
                frameBase + frameSlot,
                slot.facts.size,
            );
        }

        return closure;
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

    // Runs one call through the FFI seam. The callee receives its frame
    // already reserved and its parameter slots already filled. The call
    // result adapter keeps the representation of `ref` results out of the
    // evaluator; the raw runner below only executes the selected callee.
    private CallResult executeCall(
        FuncDeclaration function_,
        void* returnPlace,
        ubyte* frameBase,
        const(FrameLayout)* layout,
        CallExp callSite = null,
        bool classConstructor = false,
    ) {
        const(void)*[maxArguments] slots;

        scope void executeCallee(
            scope void* place,
            scope const(void*)[] arguments,
        ) {
            executeRaw(
                function_, place, frameBase, layout, callSite,
                classConstructor, arguments.ptr, arguments.length,
            );
        }

        return layout.call.invoke(
            returnPlace,
            argumentSlots(slots, frameBase, layout),
            &executeCallee,
        );
    }

    // Runs `function_`'s body with its frame already reserved at
    // `frameBase` - and its parameter slots already filled by the caller
    // - evaluating its `return` expression into `returnPlace`. Every call
    // this backend ever makes, whether the host called in directly or a
    // guest `CallExp` reached it, passes through here exactly once, so
    // this is where a call unsafe to run gets rejected.
    private void executeRaw(
        FuncDeclaration function_,
        void* returnPlace,
        ubyte* frameBase,
        const(FrameLayout)* layout,
        CallExp callSite = null,
        bool classConstructor = false,
        const(void*)* arguments,
        size_t argumentCount,
    ) {
        import std.conv: text;

        // A template instance used only by interpreted guest code has no
        // machine-code symbol for FFI to find. DMD has already synthesized
        // and analyzed its exact body, so walk that body. This is semantic:
        // no function name, package, or template argument gets a vote.
        // Other non-root declarations still run as native code already
        // linked into the process.
        const isGuest = _program.isInterpreted(function_);
        const isTemplate = function_.isInstantiated() !is null
            && function_.fbody !is null;
        // A template instance can inherit the guest module of its call site,
        // even when dmd also emitted a native specialization for it. Check
        // the process symbol for every instantiated body so guest ownership
        // does not force a duplicate walk of code druntime already provides.
        const interpretsTemplate = isTemplate
            && (!hasNativeSymbol(function_)
                || hasInterpretedDelegateArgument(callSite));
        const interprets = isGuest && !isTemplate
            || interpretsTemplate
            || hasInterpretedDelegateArgument(callSite);
        if (!interprets) {
            rejectInterpretedFunctionPointerArgument(
                function_, arguments, argumentCount);
            const plan = callSite is null
                ? &_plans.of(function_)
                : callPlanOf(callSite, function_);
            plan.call(returnPlace, arguments[0 .. argumentCount]);
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
        auto aggregate = function_.isThis;
        if (aggregate !is null && aggregate.isStructDeclaration is null
                && callSite is null && !classConstructor)
            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "`: its class `this` is not bound"),
            );

        import dmd.funcsem: needsClosure;

        // A root-owned declaration with no body has no code anywhere: the
        // program owns it, so no library can be expected to implement it.
        auto body_ = function_.fbody;
        if (body_ is null)
            throw new SnakebiteException(
                text("interpreter cannot call a function with no body: `",
                    function_.toString, "`"),
            );

        const guard = CallStateGuard(this);

        _closureBase = null;
        if (function_.needsClosure())
            _closureBase = allocateClosure(function_, frameBase, layout);

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
        body_.accept(this);
    }

    // `visit(SymOffExp)`/`visit(FuncExp)` store a guest function pointer's
    // value as the `FuncDeclaration` itself, since this backend has no
    // machine code of its own for an interpreted function - `calleeOf`
    // resolves that stand-in back on every call this evaluator makes. A
    // call routed to real native code instead (`function_` here has no
    // guest body to walk) hands its arguments to the FFI seam as opaque
    // bytes, which marshals a function-pointer argument's bits unchanged
    // into a register; if those bits are one of this backend's
    // declaration stand-ins rather than an executable address, the native
    // callee jumps to it and the host segfaults with no diagnostic.
    // Checked once here, at the one place every native call's arguments
    // are about to leave this evaluator for good, rather than in every
    // caller that might produce such a value.
    //
    // Only a function-pointer-typed parameter is inspected: any other
    // parameter's bytes might legitimately contain the same bit pattern
    // (an `int` happening to equal some declaration's address, say)
    // without meaning a function pointer at all.
    private void rejectInterpretedFunctionPointerArgument(
        FuncDeclaration function_,
        const(void*)* arguments,
        size_t argumentCount,
    ) {
        import snakebite.nativelayout: loadIntegral;
        import std.conv: text;

        auto type = function_.type.isTypeFunction;
        if (type is null)
            return;

        size_t index = function_.vthis !is null ? 1 : 0;
        foreach (i; 0 .. type.parameterList.length) {
            if (index >= argumentCount)
                return;

            const argumentIndex = index++;
            auto pointer = type.parameterList[i].type.isTypePointer;
            if (pointer is null || pointer.next.isTypeFunction is null)
                continue;

            const raw = loadIntegral(
                arguments[argumentIndex], size_t.sizeof, false);
            if (raw == 0)
                continue;

            auto candidate = cast(FuncDeclaration) cast(void*) raw;
            if (!_program.isInterpreted(candidate))
                continue;

            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "` with `", candidate.toString, "` as a function "
                    ~ "pointer argument: calling an interpreted function "
                    ~ "back from native code is not yet supported "
                    ~ "(see issue #9)"),
            );
        }
    }

    // dmd lowers `foreach` over an associative array to a call to a
    // druntime helper (e.g. `_aaApply2`) that invokes the loop body
    // through a delegate parameter. That helper is native code, but the
    // delegate it calls back into is the guest's loop body, whose
    // closure a native ABI call cannot reach. Walking the helper's own
    // body here, instead of calling it natively, keeps every call to the
    // delegate going through this evaluator. Only a delegate whose
    // declaration is itself guest-owned selects this: a native delegate
    // argument of the same opApply shape (an unrelated library call, for
    // instance) has no guest closure to reach and must still run
    // natively, since this evaluator may not have its body at all.
    private bool hasInterpretedDelegateArgument(CallExp callSite) {
        if (callSite is null || callSite.arguments is null)
            return false;

        foreach (argument; *callSite.arguments) {
            auto expression = argument;
            while (auto cast_ = expression.isCastExp)
                expression = cast_.e1;

            FuncDeclaration delegateFunction;
            if (auto funcExp = expression.isFuncExp)
                delegateFunction = funcExp.fd;
            else if (auto delegateExp = expression.isDelegateExp)
                delegateFunction = delegateExp.func;

            if (delegateFunction is null
                    || !_program.isInterpreted(delegateFunction))
                continue;

            auto functionType = typeFunctionOf(delegateFunction);
            if (functionType !is null
                    && functionType.parameterList.length != 0
                    && functionType.nextOf.isIntegral)
                return true;
        }

        return false;
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
        private ubyte* _closureBase;
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

        @disable this();
        @disable this(this);

        private this(Evaluator evaluator) {
            _evaluator = evaluator;
            _type = evaluator._type;
            _facts = evaluator._facts;
            _place = evaluator._place;
            _frameBase = evaluator._frameBase;
            _closureBase = evaluator._closureBase;
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
        }

        ~this() {
            _evaluator._type = _type;
            _evaluator._facts = _facts;
            _evaluator._place = _place;
            _evaluator._frameBase = _frameBase;
            _evaluator._closureBase = _closureBase;
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

        auto slot = storageOf(catch_.var);
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

        void* referenceAddress() {
            return addressOf(statement.exp);
        }

        void evaluateValue() {
            // `_type`/`_facts` are already this function's return type and
            // its facts, set together on entry (`executeRaw`) or by the last
            // `evaluate`, so this callback needs no fresh type lookup.
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

        _layout.call.returnFromCall(
            _place, &referenceAddress, &evaluateValue,
        );
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

        // DMD classifies pointers as integral for some type queries, but
        // their value must be read as an address, not as a signed integer.
        if (type.ty == Tpointer)
            return asPointer(expression) !is null;

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
    // back when the value is called. A capturing literal carries the
    // enclosing frame or closure as its context, and that storage remains
    // reachable through `_allocations` when the enclosing call returns.
    override void visit(FuncExp expression) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, storeIntegral;
        import std.conv: text;

        import dmd.funcsem: needsClosure;

        auto literal = expression.fd;
        if (literal is null || literal.isThis() !is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its function declaration is unsupported"),
            );

        auto bytes = cast(ubyte*) _place;
        if (bytes is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: it has no destination"),
            );
        const functionWord = cast(size_t) cast(void*) literal;

        if (_type.ty == Tdelegate) {
            auto context = cast(size_t) 0;
            if (literal.outerVars.length != 0 || literal.needsClosure()) {
                auto parent = literal.toParent2;
                auto parentFunction = parent is null
                    ? null : parent.isFuncDeclaration;
                if (parentFunction is null)
                    throw new SnakebiteException(
                        text("interpreter cannot evaluate `",
                            expression.toString,
                            "`: its enclosing function could not be " ~
                            "determined"),
                    );
                context = cast(size_t) tryContextOf(parentFunction);
            }
            storeIntegral(
                bytes + delegateContextOffset, context, size_t.sizeof);
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

    // `&nested` is lowered by dmd to a DelegateExp whose expression is the
    // nested function itself. Its context is the enclosing frame or heap
    // closure, just as for a delegate literal. The function declaration is
    // retained in the function word for the interpreter to resolve later.
    override void visit(DelegateExp expression) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, storeIntegral;
        import std.conv: text;

        auto function_ = expression.func;
        if (function_ is null || function_.isThis() !is null
                || _type.ty != Tdelegate)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its delegate declaration is unsupported"),
            );

        auto context = cast(size_t) 0;
        if (function_.outerVars.length != 0
                || functionNeedsClosure(function_)) {
            auto parent = function_.toParent2;
            auto parentFunction = parent is null
                ? null : parent.isFuncDeclaration;
            if (parentFunction is null)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `",
                        expression.toString,
                        "`: its enclosing function could not be determined"),
                );
            context = cast(size_t) tryContextOf(parentFunction);
        }

        auto bytes = cast(ubyte*) _place;
        if (bytes is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: it has no destination"),
            );
        storeIntegral(
            bytes + delegateContextOffset, context, size_t.sizeof);
        storeIntegral(
            bytes + delegateFunctionOffset,
            cast(size_t) cast(void*) function_,
            size_t.sizeof,
        );
    }

    override void visit(DelegatePtrExp expression) {
        import snakebite.nativelayout: delegateContextOffset;

        visitDelegateWord(expression.e1, delegateContextOffset);
    }

    override void visit(DelegateFuncptrExp expression) {
        import snakebite.nativelayout: delegateFunctionOffset;

        visitDelegateWord(expression.e1, delegateFunctionOffset);
    }

    private void visitDelegateWord(Expression expression, size_t offset) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: delegateValueSize;

        const facts = factsOf(expression.type);
        assert(facts.size == delegateValueSize);
        align(size_t.sizeof) ubyte[delegateValueSize] value = void;
        evaluate(expression, expression.type, facts, value.ptr);
        memcpy(
            _place,
            value.ptr + offset,
            _facts.size,
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

    // Where `owner`'s own context is: `owner` itself if it is the function
    // currently executing, otherwise found by following the static chain
    // up from there - one context hop per level of nesting. A context is
    // either a frame or a heap closure, as dmd decides for that owner.
    private ubyte* contextOf(FuncDeclaration owner) {
        import std.conv: text;

        auto base = tryContextOf(owner);
        if (base is null)
            throw new SnakebiteException(
                text("interpreter cannot reach `", owner.toString,
                    "`'s context: it is not on the current static chain"),
            );

        return base;
    }

    // As `contextOf`, but `null` rather than a thrown exception when
    // `owner`'s context is not reachable from here. The null result is
    // useful for a non-capturing delegate, whose context is never read.
    private ubyte* tryContextOf(FuncDeclaration owner) {
        import snakebite.nativelayout: loadIntegral;
        import dmd.funcsem: needsClosure;

        auto fn = _function;
        auto base = functionNeedsClosure(fn)
            ? _closureBase : _frameBase;
        while (fn !is owner) {
            if (base is null)
                return null;

            if (functionNeedsClosure(fn))
                base = cast(ubyte*) loadIntegral(
                    base, size_t.sizeof, false);
            else {
                auto layout = layoutOf(fn);
                if (layout.hiddenThis.variable is null)
                    return null;
                base = cast(ubyte*) loadIntegral(
                    base + layout.hiddenThis.parameter.offset,
                    size_t.sizeof, false);
            }
            auto parent = fn.toParent2();
            fn = parent is null ? null : parent.isFuncDeclaration;
            if (fn is null)
                return null;
        }

        return base;
    }

    private bool functionNeedsClosure(FuncDeclaration function_) {
        import dmd.funcsem: needsClosure;

        return function_.needsClosure();
    }

    // Where the variable read or written by `expression` lives: the
    // current frame for a parameter or local, and storage of its own for
    // anything in the data segment. A read and a compound assignment
    // differ in what they do with the slot, not in how they find it, so
    // both come here.
    private ubyte* slotOf(VarExp expression) {
        return slotOf(expression, expression.var);
    }

    // The raw slot for a declaration, before indirecting through a `ref`
    // variable. Declarations need this address to initialize a reference
    // slot itself; reads and writes use `slotOf` below and indirect it.
    private ubyte* storageOf(VarDeclaration variable) {
        auto owner = outerFunctionOf(variable);
        if (owner !is null && functionNeedsClosure(owner)) {
            auto context = contextOf(owner);
            const closure = closureLayoutOf(owner);
            if (closure.hasSlot(variable))
                return context + closure.slotOf(variable).offset;
        }

        if (_layout.hasSlot(variable))
            return _frameBase + _layout.offsetOf(variable);

        if (owner is null)
            throw new SnakebiteException(
                "interpreter cannot find storage for a local variable",
            );

        return contextOf(owner) + layoutOf(owner).offsetOf(variable);
    }

    private bool isRefStorage(VarDeclaration variable) {
        auto owner = outerFunctionOf(variable);
        if (owner !is null && functionNeedsClosure(owner)) {
            const closure = closureLayoutOf(owner);
            if (closure.hasSlot(variable))
                return closure.slotOf(variable).isRef;
        }

        if (_layout.hasSlot(variable))
            return _layout.isRef(variable);

        return owner !is null && layoutOf(owner).isRef(variable);
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
                    "` (", declaration.kind, ") in `",
                    _function.ident.toString,
                    ": not a parameter or local in the current frame"),
            );

        if (variable.isDataseg)
            return staticSlotOf(variable);

        countForeignNameLookup;

        // A parameter or local of the currently executing function itself
        // is the common case, and the only one a non-nested function ever
        // has. A variable in a function's closure is checked first because
        // dmd moved it out of the activation frame; all other variables use
        // the frame or context chain below.
        auto owner = outerFunctionOf(variable);
        if (owner !is null && functionNeedsClosure(owner)) {
            auto context = contextOf(owner);
            const closure = closureLayoutOf(owner);
            if (closure.hasSlot(variable)) {
                const slot = closure.slotOf(variable);
                auto result = context + slot.offset;
                if (slot.isRef)
                    return cast(ubyte*) loadIntegral(
                        result, size_t.sizeof, false);
                return result;
            }
        }

        auto base = _frameBase;
        auto layout = _layout;
        if (!layout.hasSlot(variable)) {
                if (owner is null)
                    throw new SnakebiteException(
                    text("interpreter cannot reach `", original.toString,
                        "` (", variable.ident.toString, ") in `",
                        _function.ident.toString,
                        "`: not a parameter or local in the current ",
                        "frame or an enclosing one"),
                );

            base = contextOf(owner);
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
        // `visit(ImportStatement)`). A local `enum Direction : ubyte
        // { north, south }` is the same story: semantic analysis has
        // already folded every member into a constant, so a cast to
        // `Direction` or a read of `Direction.north` never reaches this
        // declaration at all. `Ctfe`, this interpreter's sibling
        // backend, needs no special case of its own for any of these: it
        // runs dmd's own `dinterpret.d`, which already knows a body can
        // hold them. Any future backend that walks a body's AST itself,
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
                || expression.declaration.isFuncDeclaration !is null
                || expression.declaration.isEnumDeclaration !is null)
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
        auto slot = storageOf(variable);
        if (isRefStorage(variable)) {
            import snakebite.nativelayout: storeIntegral;

            storeIntegral(
                slot,
                cast(size_t) addressOf(value),
                size_t.sizeof,
            );
            return;
        }

        evaluate(value, variable.type, slot);
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
        // A scalar `ConstructExp` initializes storage that has no prior
        // value. This includes immutable fields in a constructor, which
        // cannot use ordinary assignment syntax but still have native bytes
        // that can be written once.
        const isConstruct = expression.isConstructExp !is null;
        const isSupportedArray = _type.ty == Tarray;
        if (structType !is null && !isSupportedStruct && !isStructBlit)
            throw new SnakebiteException(
                text("interpreter cannot assign unsupported struct `",
                    structType.toString, "`"),
            );

        if (expression.op != EXP.assign && !_facts.isIntegral && !isConstruct
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

            if (base is null)
                throw new SnakebiteException(
                    text("interpreter cannot index through a null pointer in `",
                        expression.toString, "` at ", index),
                );

            return ElementAddress(
                cast(void*) (base + index * stride), stride);
        }

        // A static array's own storage is already contiguous elements,
        // not a `{length, ptr}` pair `evaluateArray` below reads out of -
        // the same distinction `visit(IndexExp)` draws for a read. The
        // element's address is the array's own address (found the same
        // way any other lvalue's is, recursing through another
        // `indexAddressOf` call when `array` is itself an indexing of a
        // further-nested static array, e.g. `b[1][2]`) plus its offset.
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
            auto base = cast(ubyte*) addressOf(array);
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

        // dmd's usual arithmetic conversions give both operands the same
        // type, so testing either one for a floating type is enough. The
        // comparison itself is made at `real`'s own width, wide enough to
        // hold every operand exactly, since D's floating ordering follows
        // IEEE 754 rather than any integral signedness rule.
        auto type = expression.e1.type;
        if (type.ty == Tfloat32 || type.ty == Tfloat64
                || type.ty == Tfloat80) {
            const a = asFloating(expression.e1);
            const b = asFloating(expression.e2);
            const answer = mixin("a " ~ op ~ " b");
            storeIntegral(_place, answer ? 1 : 0, _facts.size);
            return;
        }

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

        const left = truthOf(expression.e1);
        const answer = expression.op == EXP.andAnd
            ? left && truthOf(expression.e2)
            : left || truthOf(expression.e2);

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
        auto structType = type.isTypeStruct;
        if (structType !is null) {
            const facts = factsOf(type);
            auto left = _frames.push(facts.size, facts.alignment);
            auto right = _frames.push(facts.size, facts.alignment);
            evaluate(expression.e1, type, facts, left.base);
            evaluate(expression.e2, type, facts, right.base);
            const equal = equalStruct(
                structType.sym,
                cast(const ubyte*) left.base,
                cast(const ubyte*) right.base,
            );
            const answer = expression.op == EXP.equal ? equal : !equal;
            storeIntegral(_place, answer ? 1 : 0, _facts.size);
            return;
        }

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

        // A static array has no length to disagree on - both operands
        // share the same type and therefore the same element count - so
        // its whole value, laid out as contiguous elements with no
        // header, is comparable the same way a dynamic array's elements
        // are: byte for byte, unless DMD's own lowering says otherwise
        // for elements needing semantic equality (a `float`/`double`
        // element's NaN, or one with its own `opEquals`).
        if (type.ty == Tsarray) {
            if (expression.lowering !is null) {
                evaluate(
                    expression.lowering,
                    expression.lowering.type,
                    factsOf(expression.lowering.type),
                    _place,
                );
                return;
            }

            const facts = factsOf(type);
            auto left = _frames.push(facts.size, facts.alignment);
            auto right = _frames.push(facts.size, facts.alignment);
            evaluate(expression.e1, type, facts, left.base);
            evaluate(expression.e2, type, facts, right.base);
            const equal = facts.size == 0
                || memcmp(left.base, right.base, facts.size) == 0;
            const answer = expression.op == EXP.equal ? equal : !equal;

            storeIntegral(_place, answer ? 1 : 0, _facts.size);
            return;
        }

        bool equal;
        if (type.ty == Tpointer)
            equal = asPointer(expression.e1) == asPointer(expression.e2);
        else if (type.ty == Tfloat32 || type.ty == Tfloat64
                || type.ty == Tfloat80)
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

    private bool equalStruct(
        StructDeclaration declaration,
        const ubyte* left,
        const ubyte* right,
    ) {
        import core.stdc.string: memcmp;
        import snakebite.nativelayout: arrayLengthOffset,
            arrayPointerOffset, loadIntegral;

        foreach (field; declaration.fields) {
            auto fieldType = field.type;
            auto a = left + field.offset;
            auto b = right + field.offset;
            if (fieldType.ty == Tarray) {
                const length = cast(size_t) loadIntegral(
                    a + arrayLengthOffset, size_t.sizeof, false);
                const otherLength = cast(size_t) loadIntegral(
                    b + arrayLengthOffset, size_t.sizeof, false);
                if (length != otherLength)
                    return false;

                const elements = *cast(const ubyte**)
                    (a + arrayPointerOffset);
                const otherElements = *cast(const ubyte**)
                    (b + arrayPointerOffset);
                const bytes = length * factsOf(fieldType.nextOf).size;
                if (bytes != 0 && memcmp(
                        elements, otherElements, bytes) != 0)
                    return false;
                continue;
            }

            auto nested = fieldType.isTypeStruct;
            if (nested !is null) {
                if (!equalStruct(
                        nested.sym,
                        a,
                        b,
                    ))
                    return false;
                continue;
            }

            // `==` on a float follows IEEE 754: `-0.0` equals `0.0`, and
            // `nan` never equals itself. `memcmp`, comparing raw bits,
            // disagrees with both, so a float field needs its own read
            // and its own `==` rather than a byte compare.
            if (fieldType.ty == Tfloat32) {
                if (*cast(const float*) a != *cast(const float*) b)
                    return false;
                continue;
            }
            if (fieldType.ty == Tfloat64) {
                if (*cast(const double*) a != *cast(const double*) b)
                    return false;
                continue;
            }
            const facts = factsOf(fieldType);
            if (memcmp(a, b, facts.size) != 0)
                return false;
        }

        return true;
    }

    // `is` on a struct is bitwise: dmd compares the whole object's raw
    // bytes, padding included, the same as `memcmp(&a, &b, S.sizeof)`
    // would. This differs from `==`, which recurses field by field and
    // reads a dynamic array field by its contents - `is` reads that same
    // field as its bare length and pointer, so two structs holding
    // separately allocated but equal-content arrays are `==` but not
    // `is`.
    private bool identicalStruct(
        StructDeclaration declaration,
        const ubyte* left,
        const ubyte* right,
    ) {
        import core.stdc.string: memcmp;

        const facts = factsOf(declaration.type);
        return memcmp(left, right, facts.size) == 0;
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
        auto structType = type.isTypeStruct;
        if (structType !is null) {
            const facts = factsOf(type);
            auto left = _frames.push(facts.size, facts.alignment);
            auto right = _frames.push(facts.size, facts.alignment);
            evaluate(expression.e1, type, facts, left.base);
            evaluate(expression.e2, type, facts, right.base);
            equal = identicalStruct(
                structType.sym,
                cast(const ubyte*) left.base,
                cast(const ubyte*) right.base,
            );
        }
        else if (type.ty == Tclass)
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
        // and every narrower width widens to `real` exactly, so narrowing
        // each operand back to the expression's own width recovers it
        // exactly and the operation then rounds once, in that precision,
        // the same single rounding compiled D performs.
        static if (op == "+" || op == "-" || op == "*" || op == "/"
                || op == "%")
            if (_type.ty == Tfloat32 || _type.ty == Tfloat64
                    || _type.ty == Tfloat80) {
                const a = asFloating(expression.e1);
                const b = asFloating(expression.e2);
                if (_type.ty == Tfloat32)
                    *cast(float*) _place =
                        mixin("cast(float) a " ~ op ~ " cast(float) b");
                else if (_type.ty == Tfloat64)
                    *cast(double*) _place =
                        mixin("cast(double) a " ~ op ~ " cast(double) b");
                else
                    *cast(real*) _place = mixin("a " ~ op ~ " b");
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
    // `real` because `float` and `double` both widen to it exactly, so the
    // one return type carries any of the three widths without loss; the
    // caller narrows back when the operation itself is `float`- or
    // `double`-precision.
    private real asFloating(Expression expression) {
        import std.conv: text;

        auto type = expression.type;
        if (type.ty != Tfloat32 && type.ty != Tfloat64
                && type.ty != Tfloat80)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as floating point: its type is `", type.toString,
                    "`"),
            );

        const facts = factsOf(type);
        align(real.alignof) ubyte[real.sizeof] buffer = void;
        evaluate(expression, type, facts, buffer.ptr);

        if (type.ty == Tfloat32)
            return *cast(float*) buffer.ptr;
        if (type.ty == Tfloat64)
            return *cast(double*) buffer.ptr;
        return *cast(real*) buffer.ptr;
    }

    // `-x` and `~x` leave the same low bits whether the operand was read as
    // signed or unsigned, so neither needs the operand's own facts.
    private extern(D) void storeUnaryExp(string op)(UnaExp expression) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        // `~` is rejected by the frontend on floating operands, so the
        // `static if` only keeps its mixin compilable for this operator;
        // only `-` ever reaches here with a floating type.
        static if (op == "-")
            if (_type.ty == Tfloat32 || _type.ty == Tfloat64
                    || _type.ty == Tfloat80) {
                const a = asFloating(expression.e1);
                if (_type.ty == Tfloat32)
                    *cast(float*) _place = -cast(float) a;
                else if (_type.ty == Tfloat64)
                    *cast(double*) _place = -cast(double) a;
                else
                    *cast(real*) _place = -a;
                return;
            }

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

        // `cast(void) e` discards the value but keeps e's effects. DMD
        // emits this around compiler-generated calls whose return value is
        // intentionally ignored, including associative-array iteration.
        if (_type.ty == Tvoid) {
            runForEffect(expression.e1);
            return;
        }

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

        // A floating-to-floating cast rounds the operand's own value to
        // the destination's own precision - `asFloating` already widens
        // any of the three to `real` without loss, so narrowing that back
        // to the destination's width is the one rounding the host's own
        // `cast(float)`/`cast(double)`/`cast(real)` performs.
        if ((sourceType.ty == Tfloat32 || sourceType.ty == Tfloat64
                    || sourceType.ty == Tfloat80)
                && (_type.ty == Tfloat32 || _type.ty == Tfloat64
                    || _type.ty == Tfloat80)) {
            const value = asFloating(expression.e1);
            if (_type.ty == Tfloat32)
                *cast(float*) _place = cast(float) value;
            else if (_type.ty == Tfloat64)
                *cast(double*) _place = cast(double) value;
            else
                *cast(real*) _place = value;
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
    //
    // `&someModuleLevelFunction` reaches this node too, with `var` a
    // `FuncDeclaration` instead: dmd only lowers a nested function's
    // address to a `DelegateExp` (a nested function may need its
    // enclosing frame or closure as context), never a module-level one,
    // so a plain function pointer here has no context word to carry. This
    // backend has no machine code for an interpreted function, so, exactly
    // as `visit(FuncExp)` already does for a function pointer, the
    // function word is the declaration itself, and `calleeOf` resolves it
    // back when the pointer is called.
    override void visit(SymOffExp expression) {
        import snakebite.nativelayout: storeIntegral;

        if (auto function_ = expression.var.isFuncDeclaration) {
            // A function has no fields for `offset` to select between: dmd
            // never emits a non-zero offset alongside a `FuncDeclaration`
            // `var`, so this stand-in scheme (see above) has nowhere to
            // apply an offset to. Asserted rather than silently ignored,
            // so a dmd change that starts doing so is caught here instead
            // of producing a function pointer value that is quietly wrong.
            assert(expression.offset == 0,
                "SymOffExp naming a function has a non-zero offset");
            storeIntegral(
                _place, cast(size_t) cast(void*) function_, _facts.size);
            return;
        }

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

        auto classType = type.isTypeClass;
        if (classType !is null && isRootOwnedClass(classType.sym)) {
            storeIntegral(
                _place,
                cast(size_t) cast(void*) classRuntimeInfo(classType.sym),
                _facts.size,
            );
            return;
        }

        auto name = type.vtinfo.ident.toString;
        countForeignNameLookup;
        auto address = _plans.resolve(name);
        if (address is null) {
            auto structType = type.isTypeStruct;
            if (structType !is null
                    && !isRootOwnedStruct(structType.sym)) {
                storeIntegral(
                    _place,
                    cast(size_t) cast(void*)
                        structRuntimeInfo(structType.sym),
                    _facts.size,
                );
                return;
            }

            throw new SnakebiteException(
                text("interpreter cannot resolve the symbol `", name,
                    "` for `", expression.toString,
                    "`: it is not in this process"),
            );
        }

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
            auto runtime = classRuntimeInfo(declaration);
            auto object = cast(ubyte*) cast(void*) runtime.create;
            if (object is null)
                throw new SnakebiteException(
                    text("interpreter cannot allocate `",
                        expression.toString, "`: druntime returned null"),
                );

            initializeClass(declaration, object, expression.loc);
            _classes[object] = declaration;

            if (expression.member !is null)
                constructClass(expression, object);

            storeIntegral(_place, cast(size_t) object, _facts.size);
            return;
        }

        if (expression.type.ty == Tpointer) {
            const structType = expression.newtype.isTypeStruct;
            if (structType is null || expression.placement !is null
                    || expression.thisexp !is null)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `", expression.op,
                        "` expression: `", expression.toString, "`"),
                );

            const declaration = structType.sym;
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
            initializeDefault(
                expression.newtype,
                factsOf(expression.newtype),
                object,
                expression.loc,
            );

            if (expression.member !is null)
                constructStruct(expression, object);
            else if (arguments !is null)
                initializeStructArguments(expression, object);

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

    // Parsed guest classes have no emitted native ClassInfo. Build the
    // native TypeInfo_Class metadata druntime needs for allocation and
    // classinfo; guest virtual calls still use dmd declarations below.
    private TypeInfo_Class classRuntimeInfo(ClassDeclaration declaration) {
        if (declaration is ClassDeclaration.object)
            return typeid(Object);

        foreach (runtime; _classRuntime)
            if (runtime.declaration is declaration)
                return runtime.typeInfo;

        TypeInfo_Class baseInfo;
        if (declaration.isInterfaceDeclaration !is null)
            baseInfo = null;
        else if (declaration.baseClass is null
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
        typeInfo.m_flags = cast(TypeInfo_Class.ClassFlags) 0;
        typeInfo.name = cast(string) declaration.toPrettyChars.toDString;
        typeInfo.base = baseInfo;
        const baseVtableLength = baseInfo is null ? 0 : baseInfo.vtbl.length;
        const vtableLength = declaration.vtbl.length > baseVtableLength
            ? declaration.vtbl.length : baseVtableLength;
        typeInfo.vtbl = new void*[vtableLength];
        if (baseInfo !is null)
            typeInfo.vtbl[0 .. baseVtableLength] = baseInfo.vtbl[];
        typeInfo.vtbl[0] = cast(void*) typeInfo;
        if (declaration.isInterfaceDeclaration is null) {
            typeInfo.m_init = new byte[](declaration.structsize);
            *cast(void**) typeInfo.m_init.ptr = typeInfo.vtbl.ptr;
        }

        if (declaration.interfaces.length != 0) {
            import object: Interface;

            typeInfo.interfaces.length = declaration.interfaces.length;
            foreach (i, base; declaration.interfaces) {
                auto interfaceInfo = classRuntimeInfo(base.sym);
                typeInfo.interfaces[i] = Interface(
                    interfaceInfo,
                    interfaceInfo.vtbl,
                    base.offset,
                );
            }
        }

        _classRuntime ~= GuestClassRuntime(
            declaration,
            typeInfo,
            typeInfo.vtbl,
        );
        return typeInfo;
    }

    private TypeInfo_Struct structRuntimeInfo(StructDeclaration declaration) {
        if (auto cached = declaration in _structRuntime)
            return *cached;

        auto typeInfo = new TypeInfo_Struct;
        typeInfo.m_init = new byte[](declaration.structsize);
        typeInfo.m_align = declaration.alignsize;
        if (declaration.hasPointerField)
            typeInfo.m_flags = TypeInfo_Struct.StructFlags.hasPointers;

        _structRuntime[declaration] = typeInfo;
        return typeInfo;
    }

    private bool isRootOwnedClass(ClassDeclaration declaration) const {
        const module_ = declaration.getModule;
        foreach (rootModule; _program.rootModules)
            if (module_ is rootModule)
                return true;

        return false;
    }

    private bool isRootOwnedStruct(StructDeclaration declaration) const {
        const module_ = declaration.getModule;
        foreach (rootModule; _program.rootModules)
            if (module_ is rootModule)
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

        auto arguments = expression.arguments;

        bindArguments(
            constructor,
            arguments,
            expression.loc,
            frame.base,
            layout,
        );

        executeCall(constructor, null, frame.base, layout, null, true);
    }

    private void constructStruct(NewExp expression, ubyte* object) {
        import std.conv: text;

        auto constructor = expression.member;
        auto layout = layoutOf(constructor);
        auto frame = _frames.push(layout.size, layout.alignment);

        import snakebite.nativelayout: storeIntegral;

        if (constructor.vthis is null)
            throw new SnakebiteException(
                text("interpreter cannot call struct constructor `",
                    constructor.toString, "`: it has no `this`"),
            );

        storeIntegral(
            frame.base + layout.hiddenThis.parameter.offset,
            cast(size_t) object,
            size_t.sizeof,
        );

        auto arguments = expression.arguments;

        bindArguments(
            constructor,
            arguments,
            expression.loc,
            frame.base,
            layout,
        );

        executeCall(constructor, null, frame.base, layout, null, true);
    }

    private void initializeStructArguments(NewExp expression, ubyte* object) {
        import std.conv: text;

        auto declaration = expression.newtype.isTypeStruct.sym;
        if (expression.arguments.length > declaration.fields.length)
            throw new SnakebiteException(
                text("interpreter cannot initialize `", expression.toString,
                    "`: too many constructor arguments"),
            );

        foreach (i; 0 .. expression.arguments.length) {
            auto field = declaration.fields[i];
            evaluate(
                (*expression.arguments)[i],
                field.type,
                factsOf(field.type),
                object + field.offset,
            );
        }
    }

    private void bindArguments(
        FuncDeclaration function_,
        Expressions* arguments,
        in Loc loc,
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        import dmd.astenums: STC;
        import std.conv: text;

        auto parameterList = typeFunctionOf(function_).parameterList;
        const argumentCount = arguments is null ? 0 : arguments.length;
        if (argumentCount != parameterList.length)
            throw new SnakebiteException(
                text("interpreter: `", function_.toString, "` expects ",
                    parameterList.length, " argument(s), got ", argumentCount),
            );

        foreach (i; 0 .. parameterList.length) {
            auto argument = (*arguments)[i];
            auto parameter = layout.parameters[i];
            auto slot = frameBase + parameter.offset;

            void* address;

            void* argumentAddress() {
                if (argument.type.ty == Tpointer
                        && argument.type.nextOf.equals(parameterList[i].type))
                    return asPointer(argument);
                address = addressOf(argument);
                return address;
            }

            void evaluateArgument(void* place) {
                evaluate(
                    argument,
                    parameterList[i].storageClass & STC.lazy_
                        ? argument.type : parameterList[i].type,
                    parameter.facts,
                    place,
                );
            }

            parameter.call.store(
                slot,
                &argumentAddress,
                &evaluateArgument,
            );

            if (parameterList[i].storageClass & STC.out_)
                initializeDefault(
                    parameterList[i].type,
                    factsOf(parameterList[i].type),
                    cast(ubyte*) address,
                    loc,
                );
        }
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

    // `~=` appending a `dchar` (`CatDcharAssignExp`, `EXP.concatenateDcharAssign`)
    // takes neither of the two paths above: dmd's semantic pass
    // (`expressionsem.d`'s `CatAssignExp.visit`) builds `.lowering` only for
    // `EXP.concatenateAssign` and `EXP.concatenateElemAssign`, leaving this
    // case's `.lowering` null and its UTF encoding plus the append itself
    // entirely to glue-layer codegen (`e2ir.d`'s `visitCatAssign`), which
    // calls `_d_arrayappendcd` (`char[]`) or `_d_arrayappendwd` (`wchar[]`)
    // directly by linker symbol - never through an AST `CallExp` any visitor
    // could walk. This resolves and calls that same compiled hook a real
    // build would, the same way `TypeidExp` resolves a symbol with no
    // `FuncDeclaration` of its own, rather than reimplementing the
    // UTF-8/UTF-16 encoding here.
    override void visit(CatDcharAssignExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        auto elementType = expression.e1.type.nextOf;
        const name = elementType.ty == Tchar ? "_d_arrayappendcd"
            : elementType.ty == Twchar ? "_d_arrayappendwd"
            : null;
        if (name is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: appending a `dchar` to `", expression.e1.type.toString,
                    "` is neither `char[]` nor `wchar[]`"),
            );

        countForeignNameLookup;
        auto hook = _plans.resolve(name);
        if (hook is null)
            throw new SnakebiteException(
                text("interpreter cannot resolve the symbol `", name,
                    "` for `", expression.toString,
                    "`: it is not in this process"),
            );

        alias ArrayAppendDchar = extern(C) void[] function(void*, dchar);
        auto appendDchar = cast(ArrayAppendDchar) hook;
        auto array = addressOf(expression.e1);
        appendDchar(array, cast(dchar) asIntegral(expression.e2));

        memcpy(_place, array, _facts.size);
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
    // Calls always go through the FFI call adapter. It copies a reference's
    // value into `_place` for this ordinary expression path; `addressOf`
    // uses `refCallAddress` when the expression itself is an lvalue.
    override void visit(CallExp expression) {
        import core.stdc.string: memcpy;
        import std.conv: text;

        auto callee = expression.f is null
            ? calleeOf(expression)
            : Callee(expression.f, null, false);
        auto function_ = callee.function_;

        void* classReceiver;
        bool hasClassReceiver;
        auto aggregate = function_.isThis;
        if (aggregate !is null && aggregate.isClassDeclaration !is null
                && !callee.fromDelegate) {
            auto dot = expression.e1.isDotVarExp;
            auto receiver = dot is null ? expression.e1 : dot.e1;
            classReceiver = classReferenceOf(receiver);
            hasClassReceiver = true;
            if (classReceiver is null)
                throw new SnakebiteException(
                    text("interpreter cannot call `", expression.toString,
                        "`: its class receiver is null"),
                );

            // `super.f()` is statically bound. Every other virtual class
            // call uses the declaration of the object held by the receiver,
            // not the declaration dmd selected from its static type.
            if (receiver.isSuperExp is null)
                function_ = virtualFunction(function_, classReceiver);
        }

        auto layout = layoutOf(function_);
        auto frame = bindFrame(
            expression,
            function_,
            layout,
            classReceiver,
            hasClassReceiver,
            callee.context,
            callee.fromDelegate,
        );

        auto nativeVirtual = nativeVirtualAddress(function_, classReceiver);
        if (nativeVirtual !is null) {
            const(void)*[maxArguments] slots;
            _plans.of(function_).callAt(
                nativeVirtual,
                _place,
                argumentSlots(slots, frame.base, layout),
            );
            return;
        }
        executeCall(
            function_, _place, frame.base, layout, expression,
            function_.isCtorDeclaration() !is null,
        );
    }

    private void* nativeVirtualAddress(
        FuncDeclaration staticFunction,
        void* receiver,
    ) {
        if (receiver is null || receiver in _classes
                || !staticFunction.isVirtualMethod)
            return null;

        const index = staticFunction.vtblIndex;
        if (index < 0)
            return null;

        auto vtable = *cast(void***) receiver;
        return vtable[index];
    }

    private FuncDeclaration virtualFunction(
        FuncDeclaration staticFunction,
        void* receiver,
    ) {
        if (!staticFunction.isVirtualMethod)
            return staticFunction;

        auto actual = receiver in _classes;
        if (actual is null)
            return staticFunction;

        // Const makes DMD's vtable entries const, but this function must
        // return the mutable declaration that the evaluator executes.
        auto declaration = *actual;
        const staticClass = staticFunction.isThis.isClassDeclaration;
        if (staticClass is null)
            return staticFunction;

        if (staticClass.isInterfaceDeclaration !is null) {
            import dmd.funcsem: overrides;

            foreach (symbol; declaration.vtbl) {
                auto candidate = symbol.isFuncDeclaration;
                if (candidate !is null
                        && candidate.overrides(staticFunction))
                    return candidate;
            }
            return staticFunction;
        }

        const index = staticFunction.vtblIndex;
        if (index >= 0 && cast(size_t) index < declaration.vtbl.length)
            if (auto candidate = declaration.vtbl[index].isFuncDeclaration)
                return candidate;

        return staticFunction;
    }

    private struct Callee {
        FuncDeclaration function_;
        void* context;
        bool fromDelegate;
    }

    // The callee of a call dmd left unresolved: one reached through a
    // value rather than a name, which for this interpreter means either a
    // delegate or a plain function pointer. Either way the function word
    // holds the declaration `visit(FuncExp)`/`visit(SymOffExp)` stored,
    // read back here. A delegate's context word is passed directly into
    // the callee's hidden context slot, since the delegate may be called
    // after the function that created it has returned; a function pointer
    // has no context word, so it never carries one.
    //
    // dmd lowers `fn(args)` on a function-pointer-typed `fn` to
    // `(*fn)(args)`, so the call's `e1` is a `PtrExp` whose own type is the
    // pointed-to `Tfunction`, not `Tpointer` - `deref.e1` is the pointer
    // expression itself, read with `asPointer` the same way any other
    // dereference reads what it points at.
    private Callee calleeOf(CallExp expression) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, delegateValueSize,
            loadIntegral;
        import std.conv: text;

        auto callee = expression.e1;
        if (auto deref = callee.isPtrExp) {
            auto function_ = cast(FuncDeclaration) asPointer(deref.e1);
            if (function_ is null)
                throw new SnakebiteException(
                    text("interpreter cannot call `", expression.toString,
                        "`: the function pointer is null"),
                );

            return Callee(function_, null, false);
        }

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

        auto function_ = cast(FuncDeclaration) cast(void*) loadIntegral(
            value.ptr + delegateFunctionOffset, size_t.sizeof, false);
        if (function_ is null)
            throw new SnakebiteException(
                text("interpreter cannot call `", expression.toString,
                    "`: the delegate is null"),
            );

        return Callee(function_, cast(void*) context, true);
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
        void* classReceiver = null,
        bool hasClassReceiver = false,
        void* delegateContext = null,
        bool fromDelegate = false,
    ) {
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;
        import dmd.astenums: STC;

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
            if (function_.isThis !is null) {
                auto dot = expression.e1.isDotVarExp;
                const classDeclaration =
                    cast(ClassDeclaration) function_.isThis.isClassDeclaration;
                if (classDeclaration !is null) {
                    if (hasClassReceiver)
                        storeIntegral(
                            frame.base + layout.hiddenThis.parameter.offset,
                            cast(size_t) classReceiver,
                            size_t.sizeof,
                        );
                    else if (fromDelegate)
                        storeIntegral(
                            frame.base + layout.hiddenThis.parameter.offset,
                            cast(size_t) delegateContext,
                            size_t.sizeof,
                        );
                    else {
                        classReceiver = classReferenceOf(
                            dot is null ? expression.e1 : dot.e1,
                        );
                        storeIntegral(
                            frame.base + layout.hiddenThis.parameter.offset,
                            cast(size_t) classReceiver,
                            size_t.sizeof,
                        );
                    }
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
                // A nested callee's `vthis` is its enclosing context. A
                // delegate supplies this context directly because it may
                // outlive the call that created it; a direct call finds it
                // by walking the current static chain.
                auto enclosing = function_.toParent2() is null
                    ? null : function_.toParent2().isFuncDeclaration;
                if (enclosing is null)
                    throw new SnakebiteException(
                        text("interpreter cannot call `",
                            function_.toString, "`: its enclosing ",
                            "function could not be determined"),
                    );

                const context = fromDelegate
                    ? cast(size_t) delegateContext
                    : cast(size_t) tryContextOf(enclosing);
                storeIntegral(
                    frame.base + layout.hiddenThis.parameter.offset,
                    context, size_t.sizeof);
            }
        }

        // Every argument is evaluated, even one the callee never reads,
        // since evaluating an argument can have effects. The shared binder
        // also preserves the native representation of `ref`, `out`, and
        // `lazy` parameters for constructor calls.
        bindArguments(
            function_,
            arguments,
            expression.loc,
            frame.base,
            layout,
        );

        return frame;
    }

    // The address a call hands back for `addressOf` when the call itself is
    // the lvalue - `pick(a, b, true) = 5;`'s left side, or a `ref` argument
    // bound to another call's `ref` result. The FFI call adapter validates
    // that the result is a reference.
    private void* refCallAddress(CallExp expression) {
        import std.conv: text;

        auto function_ = expression.f;
        if (function_ is null)
            throw new SnakebiteException(
                text("interpreter cannot call an unresolved function: `",
                    expression.toString, "`"),
            );

        auto layout = layoutOf(function_);
        auto frame = bindFrame(expression, function_, layout);
        return executeCall(
            function_, null, frame.base, layout, expression,
        ).address;
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
