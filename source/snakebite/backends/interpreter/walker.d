module snakebite.backends.interpreter.walker;


private:

import std.conv: text;
import snakebite.callarguments: CallArguments;


// Walks dmd's AST directly. The one invariant: a result is never boxed
// into a host-side representation - every expression is evaluated
// straight into a caller-designated native address, in native layout.
public final class Interpreter: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.ffi: CallbackBridge, CallbackCall;
    import snakebite.hostthreads: PerThread;

    // What every thread that runs this program shares: the caches that
    // are filled once per key, and the plan cache with its callback
    // bridge (ADR-0006).
    private Shared* _shared;
    // Each native stack needs independent execution state: a suspended Fiber
    // must not leave its active frame or expression state in another Fiber.
    // Entries are owned and released by their host thread (ADR-0006).
    private PerThread!(Evaluator, true) _evaluators;

    public this(const Program program) {
        super(program);
        _shared = new Shared(program);
        _shared.plans.useCallbacks(
            new CallbackBridge(
                &invokeCallback,
                cast(void*) this,
                &prepareCallback,
            ));
        _evaluators = PerThread!(Evaluator, true)(() => new Evaluator(_shared));
    }

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        evaluator.call(function_, returnPlace, args);
    }

    // The evaluator of the calling thread: made on its first entry, and
    // kept until it ends.
    private Evaluator evaluator() {
        initializeThread;
        return _evaluators.current;
    }

    // The re-entry a pool entry (ADR-0003) reaches when host code calls
    // a guest function pointer or delegate, from any thread (ADR-0006).
    extern(C) private static void invokeCallback(
        void* context,
        CallbackCall* call,
    ) {
        auto interpreter = cast(Interpreter) context;
        interpreter.evaluator.callGuestFromHost(call);
    }

    private static void prepareCallback(
        void* context,
        FuncDeclaration function_,
    ) {
        auto interpreter = cast(Interpreter) context;
        interpreter.evaluator.prepareCallback(function_);
    }

    public override string eval(FuncDeclaration function_) {
        string result;
        call(function_, &result, []);
        return result;
    }

    // These read the calling thread's own evaluator: correct for a
    // `version(unittest)` caller, which reads its own counters on the
    // same thread that made the calls being counted.
    version(unittest)
    public size_t nameLookups() {
        return _evaluators.current.nameLookups();
    }

    version(unittest)
    public size_t typeLookups() {
        return _evaluators.current.typeLookups();
    }

    version(unittest)
    public size_t symbolLookups() {
        return _evaluators.current.symbolLookups();
    }

    // Frame layouts built on this thread - by this evaluator or by any
    // shared code it reaches - since the thread started. Global, so only a
    // difference between two readings on the same thread means anything.
    version(unittest)
    public size_t layoutBuilds() @safe @nogc nothrow const scope {
        import snakebite.backends.layout: FrameLayout;

        return FrameLayout.builds;
    }

}

import snakebite.exception: SnakebiteException;

// A guest throw must remain distinguishable from a refusal to interpret a
// guest construct. The runner catches this wrapper, while interpreter
// failures travel as `SnakebiteException` and continue through the host
// unchanged.
private final class GuestException: Exception {
    private Throwable _guest;

    public this(Throwable guest) {
        super(guest.msg);
        _guest = guest;
        if (_guest.refcount)
            ++_guest.refcount;
    }

    ~this() {
        if (_guest !is null)
            _d_delThrowable(_guest);
    }

    private Throwable take() {
        auto guest = _guest;
        _guest = null;
        return guest;
    }
}

import snakebite.backends.loweringvisitor: LoweringVisitor;
import snakebite.backends.identity: IdentityPlan;
import snakebite.backends.comparison: ComparisonPlan;
import snakebite.backends.controlflow: ControlFlowState,
    cleanupCount, scopePath;
import snakebite.backends.interpreter.temporarylifetime: TemporaryLifetime;
import snakebite.backends.fullexpression: FullExpressionKind;

// The state one program's evaluators share, whichever thread they run
// on (ADR-0006). Every table here is filled once per key - under its
// own `SharedTable` lock, and under the frontend compiler lock too only
// while a dmd forward reference still needs resolving
// (`snakebite.frontend.compiler.forceIfNeeded`) - and read without any
// lock after that, so the only thing an evaluator keeps for itself is
// its own execution state.
private struct Shared {
    import dmd.dclass: ClassDeclaration;
    import dmd.declaration: Declaration;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Catch;
    import snakebite.backends.backend: Program;
    import snakebite.backends.calls: CallSelection;
    import snakebite.backends.classinfo: ClassRuntimeCache;
    import snakebite.backends.layout: ClosureLayout, FrameLayout;
    import snakebite.backends.runtimetypes: RuntimeTypes;
    import snakebite.backends.staticchain: Hop;
    import snakebite.ffi: PlanCache;
    import snakebite.nativelayout: NativeData, TypeFacts;
    import snakebite.sharedtable: SharedTable;

    // The program being run: its `isInterpreted` is the one decision for
    // whether a callee is walked or called natively.
    const Program program;
    NativeData nativeData;
    RuntimeTypes runtimeTypes;
    // How to reach each already-compiled function this guest calls,
    // worked out on that function's first call and reused by every call
    // after it.
    PlanCache plans;
    // Whether a callee's own body is preferred does not change while a
    // program runs. Call-site decisions stay with the evaluator: delegate
    // arguments and the active nesting context are checked per call.
    CallSelection callSelection;
    ClassRuntimeCache classRuntime;
    // The reverse of `classRuntime`: which declaration a generated
    // `TypeInfo_Class` stands for. An object's own dynamic type is read
    // straight out of its native layout (word 0's vtable, slot 0 - the
    // same place a real compiled object keeps its `classinfo`), the same
    // way the bytecode VM reads it; this is the one place that answer
    // needs to travel back to the `ClassDeclaration` this backend still
    // dispatches virtual calls and `DeleteExp`'s destructor through. A
    // native object's own dynamic type is never a key here, since only
    // `classRuntimeInfo` below ever inserts one - that absence is how a
    // native receiver is told apart from a guest one. Keyed by the
    // `TypeInfo_Class` object's own address: `TypeInfo` compares and
    // hashes by name, and a native class can share a guest class's fully
    // qualified name (a root module also linked into this process), so a
    // name-keyed table would answer a native object with the guest
    // declaration.
    SharedTable!(const(void)*, ClassDeclaration) declarationOf;
    // Each guest function's frame layout, computed on that function's
    // first call and reused by every call after it.
    SharedTable!(FuncDeclaration, FrameLayout) layouts;
    // The FFI call adapter for a guest callee's own signature: whether it
    // returns by `ref`, and whether each declared parameter passes an
    // address or a value. `FrameLayout` describes storage, not the
    // calling convention layered on top of it, so this stays its own
    // table beside `layouts` - the bytecode compiler never reads a
    // `FuncDeclaration`'s call adapter at all, only an evaluator does,
    // on every call.
    SharedTable!(FuncDeclaration, CallShape) calls;
    // Storage for locals that dmd moves out of an activation frame when
    // it decides that the frame must survive its call.
    SharedTable!(FuncDeclaration, ClosureLayout) closures;
    // DMD's closure analysis is stable after semantic analysis. Keep both
    // answers so execution does not repeat the same AST walk for
    // functions that stay in this program.
    SharedTable!(FuncDeclaration, bool) needsClosure;
    // The static-chain hops from one function's frame to an enclosing
    // function's context, keyed by that pair. Working the hops out builds
    // the frame layout of every function on the way, so it is done once
    // per pair and read back on every reach of a captured variable.
    SharedTable!(StaticChainKey, Hop[]) staticChains;
    // Each catch clause's own runtime type, resolved the first time
    // `visit(TryCatchStatement)` reaches it and reused by every throw
    // that later unwinds through it.
    SharedTable!(Catch, TypeInfo_Class) catchTypes;
    // Every dmd `Type` any evaluator has ever asked dmd about, keyed by
    // the `Type` node itself: `Type.size`/`alignsize`/`isIntegral`/
    // `isUnsigned` are pure functions of the type, re-entering dmd's
    // semantic-analysis machinery every call, so this asks each of them
    // once per distinct `Type`. Not per-function like `layouts`: a `Type`
    // such as `int` is dmd's own shared, interned instance, so the same
    // entry serves every function that mentions it.
    SharedTable!(Type, TypeFacts) typeFacts;
    // The reverse of `callableAddress`: a real callable address any
    // evaluator handed out for a guest function, back to the declaration
    // it stands for, so a call through that same address - made by any
    // evaluator, not only the one that first resolved it - is interpreted
    // directly instead of crossing the FFI barrier to call itself.
    SharedTable!(const(void)*, FuncDeclaration) callableDeclarations;

    this(const Program program) {
        this.program = program;
        plans = PlanCache(program.dependencyImage);
        nativeData = NativeData(&this.program.isRootOwned,
            &constantSymbolAddress,
            (name) => plans.resolveThreadLocal(name),
            &classRuntimeInfo);
        runtimeTypes = RuntimeTypes(&this.program.isRootOwned,
            (name) => plans.resolve(name),
            &classRuntimeInfo,
            (type, loc) => nativeData.initialValue(type, loc));
    }

    private void* constantSymbolAddress(Declaration symbol) {
        import snakebite.nativelayout: nativeSymbolName;

        if (auto function_ = symbol.isFuncDeclaration)
            return callableAddress(function_, 0);

        return plans.resolve(nativeSymbolName(symbol));
    }

    // A guest class's native metadata. This vtable is real native layout
    // that native code reaching a guest object can call through directly
    // (an unoverridden base method, a template instantiated natively
    // over a guest type, ...), and that an evaluator's own virtual call
    // also reads directly, so every slot stays a real callable address,
    // never a `FuncDeclaration` only an evaluator knows how to walk.
    TypeInfo_Class classRuntimeInfo(ClassDeclaration declaration) {
        import snakebite.backends.classinfo:
            classRuntimeInfo_ = classRuntimeInfo, Hooks;

        if (auto found = classRuntime.find(declaration))
            return *found;

        return classRuntime.build(() => classRuntimeInfo_(
            declaration,
            classRuntime,
            Hooks(
                &callableAddress,
                (decl, base) => nativeData.fillFields(decl, base),
                &runtimeTypes.linkedClassInfo,
                (decl, info) {
                    declarationOf.insert(cast(const(void)*) info, decl);
                },
            ),
        ));
    }

    // A guest function's callable address: a class vtable slot's own
    // entry (adjusted for the interface offset the slot carries), or the
    // value `visit(FuncExp)`, `storeDelegateValue` and
    // `constantSymbolAddress` store for a plain function pointer or a
    // delegate's function word (`adjustment` 0, no vtable involved).
    // Program-wide, like the vtable slot itself (ADR-0006): a guest
    // function's own callability does not depend on which thread asks
    // for it, so every evaluator forwards here instead of keeping its
    // own answer.
    private void* callableAddress(FuncDeclaration method, ptrdiff_t adjustment) {
        import dmd.astenums: VarArg;
        import dmd.dsymbolsem: isAbstract;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        // getOverloads can leave an alias in a function-pointer constant.
        method = method.toAliasFunc;
        if (method.isAbstract)
            return null;

        // Untyped variadic calls need the argument types from their call
        // site. The callback bridge cannot prepare a fixed entry for
        // them, so this keeps the declaration itself as the word, the
        // same as before this cache existed: `calleeOf` still resolves
        // it through `plans.isGuestWord`.
        if (typeFunctionOf(method).parameterList.varargs == VarArg.variadic
                && adjustment == 0) {
            plans.registerGuestFunction(cast(void*) method, method);
            return cast(void*) method;
        }

        const(void)* word;
        if (callSelection.usesGuestBody(method,
                (callee) => program.isInterpreted(callee),
                plans.hasNativeSymbol(method),
                plans.hasIndependentNativeSymbol(method))) {
            plans.registerGuestFunction(cast(void*) method, method);
            word = cast(void*) method;
        }
        auto address = plans.callableAddress(word, method, adjustment);
        // The reverse lookup only ever needs the unadjusted address: an
        // adjusted one is a vtable slot's own entry, reached only through
        // a virtual call, which already knows its declaration and never
        // asks `calleeOf`.
        if (adjustment == 0)
            callableDeclarations.insert(address, method);
        return address;
    }
}

// `CallAdapter` paired with one `CallAdapter.Argument` per declared
// parameter, parallel to `FrameLayout.parameters` - both are pure
// functions of the same `FuncDeclaration`'s type, so both are worked
// out from it together and kept in one table.
private struct CallShape {
    import snakebite.ffi: CallAdapter;

    private CallAdapter adapter;
    private CallAdapter.Argument[] arguments;
}

// The evaluation context: executes statements and evaluates expressions,
// always into the current destination (`_type` bytes at `_place`),
// resolving parameter reads against the currently executing function's
// frame. One class covers statement and expression nodes both, so the
// (type, place, frame) context lives in one spot instead of being copied
// between visitor types. Any node kind it does not know throws, naming
// the node, instead of silently doing nothing. One evaluator serves one
// thread (ADR-0006): it owns that thread's frame stack and execution
// state, and reads every per-function answer from the `Shared` tables
// the program's evaluators fill together.
extern(C++) private final class Evaluator: LoweringVisitor {
    import snakebite.backends.aggregateinit: InitStep;
    import snakebite.backends.calls: CallSelection;
    import snakebite.backends.backend: Program;
    import snakebite.frontend.dmd.delegates: DelegateTarget, outerFunctionOf;
    import snakebite.backends.layout: ClosureLayout, FrameLayout;
    import snakebite.backends.staticchain: Hop;
    import snakebite.backends.classinfo;
    import dmd.dclass: ClassDeclaration;
    import dmd.dstruct: StructDeclaration;
    import snakebite.framestack: FrameStack, defaultFrameCapacity;
    import snakebite.backends.interpreter.nativestack:
        InterpreterStack, defaultInterpreterStackBytes, fiberContextOf,
        snakebite_interpreter_call_on_stack;
    import snakebite.backends.druntimehooks: DruntimeHook;
    import snakebite.ffi:
        CallAdapter, CallbackCall, CallPlan, CallResult, PlanCache;
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import snakebite.nativelayout:
        initializerConstructsThroughSlice, initializerValueOf,
        isIntegralSize, TypeFacts;
    import object:
        Error, Exception, Throwable, TypeInfo, TypeInfo_Class,
        TypeInfo_Tuple;
    import dmd.root.string: toDString;
    import dmd.astenums:
        Tarray, Taarray, Tbool, Tchar, Tclass, Tdelegate, Tfloat32,
        Tfloat64, Tfloat80, Tnoreturn, Tint64, Tpointer, Tsarray, Ttuple,
        Tuns32, Tuns8, Tvoid, Twchar, VarArg;
    import dmd.arraytypes: Expressions;
    import dmd.declaration: Declaration, VarDeclaration;
    import dmd.expression;
    import dmd.expressionsem: toInteger;
    import dmd.func: FuncDeclaration;
    import dmd.funcsem: isVirtualMethod;
    import dmd.identifier: Identifier;
    import dmd.init: ExpInitializer;
    import dmd.location: Loc;
    import dmd.mtype: Type, TypeFunction;
    import dmd.statement:
        BreakStatement, CaseStatement, Catch, CompoundStatement,
        ContinueStatement, DefaultStatement, DoStatement, ExpStatement,
        ForStatement, GotoCaseStatement, GotoDefaultStatement, GotoStatement,
        IfStatement,
        ImportStatement, LabelStatement, ReturnStatement, ScopeStatement,
        Statement, SwitchStatement, ThrowStatement, TryCatchStatement,
        TryFinallyStatement, UnrolledLoopStatement, WithStatement;
    import dmd.tokens: EXP;
    import dmd.typesem: isIntegral, nextOf, toBasetype;
    import snakebite.nativelayout: NativeData, nativeSymbolName;
    import snakebite.backends.runtimetypes: RuntimeTypes;

    alias visit = LoweringVisitor.visit;

    private Shared* _shared;
    // Every guest frame this thread runs lives in this one frame stack,
    // bump-allocated on call and popped on return. Frames never move;
    // overflow throws loudly.
    private FrameStack _frames;
    // The native stack every host-to-guest entry runs its recursive walk
    // on, regardless of which stack it was reached on - see
    // `InterpreterStack`'s own documentation (nativestack.d).
    private InterpreterStack _interpreterStack;
    private NativeData* _nativeData;
    // This thread's reads of the shared tables, counted.
    private Cache!(FuncDeclaration, FrameLayout) _layouts;
    private Cache!(FuncDeclaration, CallShape) _calls;
    // The backing bytes of a closure are kept in `_allocations`, so a
    // delegate can retain this context after the frame stack has popped
    // the call.
    private Cache!(FuncDeclaration, ClosureLayout) _closures;
    private Cache!(FuncDeclaration, bool) _needsClosure;
    private Cache!(StaticChainKey, Hop[]) _staticChains;
    private CallSelection* _callSelection;
    version(unittest) private size_t _staticLookups;
    // A guest pointer can live in an unscanned frame, so the evaluator keeps
    // each backing allocation reachable for as long as guest state can be.
    private void[][] _allocations;
    private Cache!(Catch, TypeInfo_Class) _catchTypes;
    private RuntimeTypes* _runtimeTypes;
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
    // after it - the same cold-path-once shape as `_layouts`. Shared by
    // every thread's own evaluator (ADR-0006): owned by `Shared`, read
    // through this pointer.
    private PlanCache* _plans;
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

    private Cache!(Type, TypeFacts) _typeFacts;
    // Expression-scoped rvalues and temporary destructors have one owner.
    private TemporaryLifetime _temporaries;
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
    // A label stays pending while its wrapped statement is entered. The
    // wrapped loop takes it, even when dmd put a scope block between them.
    private Identifier _pendingLoopLabel;
    // A control transfer carries DMD's resolved statement destination. The
    // state also records when a function is being resumed at that statement,
    // so every enclosing visitor can continue its normal statement sequence.
    private ControlFlowState _controlFlow;
    private SwitchStatement _switchStatement;
    // `extern(D)`: only `Visitor`'s `visit` overloads need the C++
    // linkage.
    extern(D) public this(Shared* shared_) {
        _shared = shared_;
        _program = shared_.program;
        _nativeData = &shared_.nativeData;
        _runtimeTypes = &shared_.runtimeTypes;
        _plans = &shared_.plans;
        _callSelection = &shared_.callSelection;
        _layouts = Cache!(FuncDeclaration, FrameLayout)(&shared_.layouts);
        _calls = Cache!(FuncDeclaration, CallShape)(&shared_.calls);
        _closures = Cache!(FuncDeclaration, ClosureLayout)(&shared_.closures);
        _needsClosure = Cache!(FuncDeclaration, bool)(&shared_.needsClosure);
        _staticChains =
            Cache!(StaticChainKey, Hop[])(&shared_.staticChains);
        _catchTypes = Cache!(Catch, TypeInfo_Class)(&shared_.catchTypes);
        _typeFacts = Cache!(Type, TypeFacts)(&shared_.typeFacts);
        _frames = FrameStack(defaultFrameCapacity);
        _interpreterStack = InterpreterStack(defaultInterpreterStackBytes);
        _temporaries = new TemporaryLifetime(&destroyTemporary);
    }

    // Runs `function_` against a fresh top-level frame, mirroring the
    // `Backend.call` contract: `returnPlace` is where the result goes
    // (`null` if the caller does not want it), `args` are host-to-guest
    // arguments in native layout. `extern(D)`: a dynamic array
    // parameter is not valid on an `extern(C++)` method, and this one is
    // never called from C++ - only `Visitor`'s `visit` overloads need
    // that linkage.
    //
    // The compiler lock is not held across the call (ADR-0006): every
    // answer that still needs dmd's own analysis is worked out on its
    // own slow path, under that lock only while the analysis is not
    // already done (`forceIfNeeded`), and read back without it after
    // (`Cache.build`). A thread that held the lock while it waited for
    // another thread's callback would otherwise never see that callback
    // return, since the callback's own slow paths need the same lock.
    extern(D) final void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        runHostToGuest(function_, returnPlace, args);
    }

    // The interpreter's one host-to-guest entry. The program runner's
    // top-level call (`call`) and a callback's re-entry
    // (`callGuestFromHost`) both reach guest code only here - neither
    // binds arguments on its own. `args` are host-to-guest arguments in
    // native layout, one pointer per parameter, per `Backend.call`'s own
    // contract - each pointer holds the address of storage for that
    // parameter's native bytes, which for a `ref`/`out` parameter are the
    // target's own address. When the callee has a hidden `this`, `args[0]`
    // is that same shape one more time, before the declared parameters:
    // the address of a pointer-sized word holding the context - the one
    // convention `CallPlan.call` and a callback's own `addresses` already
    // use for it.
    //
    // A `ref`-returning callee hands back the result's own address, not
    // its value - the same word compiled D returns in `rax` - so
    // `returnPlace` must be pointer-sized for one of those, exactly as a
    // callback re-entry already required.
    //
    // This nests under the caller's own pending temporaries
    // (`withTemporaryLifetime`) rather than a fresh top-level lifetime: at
    // true top level `_temporaries.length` is 0, so the nested form is
    // already the same as starting one from empty, and every release path
    // here runs in `scope(exit)`, so no earlier call can leave temporaries
    // behind that a separate top-level backstop would need to clean up.
    // This also suspends the caller's expression state around the
    // callee's body (`withNestedCall`) - the same protection a guest call
    // site gives a callee it reaches mid-expression (`executeCall`). A
    // callback can fire while an outer guest expression still owns
    // pending temporaries; a top-level call owns none, so the nesting
    // costs it nothing.
    extern(D) private void runHostToGuest(
        FuncDeclaration function_,
        void* returnPlace,
        scope const(void*)[] args,
    ) {
        runOnInterpreterStack({
            runHostToGuestOnDedicatedStack(function_, returnPlace, args);
        });
    }

    // Runs `action` with this thread's own `_interpreterStack` active,
    // switching onto it first if needed. Two cases need no switch: a
    // nested host-to-guest entry reached while already running there (a
    // guest delegate passed to a host algorithm, itself called from guest
    // code already on this stack: it already has the full budget, and
    // switching twice would only cost time), and a plain OS thread with
    // no guest `Fiber` active (`Fiber.getThis`) - its own stack is
    // already sized like compiled D's (`InterpreterStack`'s own
    // documentation, nativestack.d), so only a `Fiber`'s own
    // (druntime-default-sized) stack ever needs the switch.
    //
    // Switching `%rsp` alone would leave the *active guest `Fiber`'s*
    // `StackContext.bstack` naming its own small stack while a live
    // `%rsp` reads point into this one, and druntime's conservative GC
    // scans exactly that mismatched range on every collection
    // (`nativestack.d`'s own documentation on `fiberContextOf`) - so
    // `ctxt.bstack` is pointed at this stack too, for as long as the
    // switch lasts. `active` is per-`Evaluator`, so per (thread, fiber)
    // context (ADR-0006): a `Fiber.yield()` inside `action` suspends by
    // switching `%rsp` on its own, through druntime's own unmodified
    // `Fiber` machinery, to whatever called `Fiber.call()` - not through
    // here - so neither `active` nor `ctxt.bstack` is restored while a
    // guest fiber is suspended mid-recursion: both stay set until this
    // same call truly completes (`scope(exit)`, below), never popped by
    // an unrelated switch-back in between. A later resume lands back on
    // this same dedicated stack, at the exact point `Fiber.yield()` left
    // it (`Fiber`'s own `StackContext.tstack`, which the switch away
    // never touches), so it needs no switch of its own either.
    //
    // Repointing `ctxt.bstack` fixes the scan for this stack, but for the
    // same duration it also drops the guest `Fiber`'s *own* small stack
    // from that scan: every frame between the `Fiber`'s entry point and
    // here sits below `savedBstack`, on a stack no `StackContext` names
    // any more. When that `Fiber` is guest code calling guest code (this
    // module's own recursion, dlib), those frames are the walker's own
    // and hold nothing the GC needs. When a *host* owns the `Fiber` and
    // calls guest code from inside it (a vibe.d-style task, say -
    // ADR-0005's own scenario), the host's frames down there can hold
    // the only reference to a guest object. `callOnInterpreterStack`
    // registers that abandoned span with `GC.addRange` for as long as
    // the switch lasts, so a collection during the switch still finds
    // it - see its own documentation for exactly which span.
    //
    // What that does not close: `ctxt.bstack` and the live `%rsp` briefly
    // name two different stacks at the switch's own entry and exit
    // (after `ctxt.bstack` moves here but before `%rsp` follows it, and
    // the mirror image coming back) - the same inconsistency druntime's
    // own `Fiber.switchIn`/`switchOut` hold `ThreadBase.m_lock` around,
    // precisely so a concurrent collection never observes it
    // (`thread_suspendHandler` only writes a suspended thread's `tstack`
    // when `!m_lock`). `m_lock` is `package(core.thread)`, unreachable
    // from here, so a collection landing on another thread inside either
    // window can still scan a mismatched pair - the same class of crash
    // this whole mechanism exists to prevent, now at a lower
    // probability, worse under many concurrent callbacks. Not fixed
    // here: closing it needs druntime's own locked machinery (a private
    // worker `Fiber` relaying `yield`s outward), which is a redesign,
    // not a bounds fix - see the known-limitation issue linked from
    // nativestack.d's module documentation.
    extern(D) private void runOnInterpreterStack(scope void delegate() action) {
        import core.thread.fiber: Fiber;

        if (_interpreterStack.active) {
            action();
            return;
        }
        auto guestFiber = Fiber.getThis;
        if (guestFiber is null) {
            action();
            return;
        }

        _interpreterStack.active = true;
        scope (exit) _interpreterStack.active = false;

        auto ctxt = fiberContextOf(guestFiber);
        auto savedBstack = ctxt.bstack;
        ctxt.bstack = _interpreterStack.top;
        scope (exit) ctxt.bstack = savedBstack;

        callOnInterpreterStack(_interpreterStack.top, savedBstack, action);
    }

    // `snakebite_interpreter_call_on_stack` (interpreter_stack_amd64.S)
    // only knows plain C pointers, so `action`'s closure - itself a
    // local on the caller's own stack, and so still valid throughout,
    // wherever `%rsp` points while it runs - is passed across by address
    // rather than as a D delegate value.
    //
    // `abandonedStackBase` is the guest `Fiber`'s own `StackContext.bstack`
    // from before `runOnInterpreterStack` repointed it - the base of the
    // small stack this call is about to leave unscanned (see that
    // function's own documentation for why). `mark`'s address, taken
    // here rather than higher up the call chain, approximates how deep
    // the switch reaches; everything between it and `abandonedStackBase`
    // - every frame from the guest `Fiber`'s entry point down through
    // `runHostToGuest` and `runOnInterpreterStack` - is registered with
    // `GC.addRange` for as long as the switch lasts, so a collection
    // during that window still finds whatever those frames hold. The
    // sliver between `&mark` and the true `%rsp` at the switch - this
    // function's own remaining prologue and
    // `snakebite_interpreter_call_on_stack`'s few instructions before it
    // moves `%rsp` - holds only plain C pointers already passed by
    // value, no GC reference of its own, so leaving it unregistered
    // costs nothing.
    extern(D) private void callOnInterpreterStack(
        void* top,
        void* abandonedStackBase,
        scope void delegate() action,
    ) @system {
        import core.memory: GC;

        void* mark;
        assert(
            cast(ubyte*) &mark < cast(ubyte*) abandonedStackBase,
            "the guest fiber's stack does not grow the way this switch assumes",
        );
        GC.addRange(
            &mark, cast(ubyte*) abandonedStackBase - cast(ubyte*) &mark);
        scope (exit) GC.removeRange(&mark);

        auto closure = action;
        snakebite_interpreter_call_on_stack(top, &runClosure, &closure);
    }

    // The plain C function pointer `snakebite_interpreter_call_on_stack`
    // actually calls: `context` is `&closure` above, still readable no
    // matter which stack is current (see `callOnInterpreterStack`).
    extern(C) private static void runClosure(void* context) {
        (*cast(void delegate()*) context)();
    }

    extern(D) private void runHostToGuestOnDedicatedStack(
        FuncDeclaration function_,
        void* returnPlace,
        scope const(void*)[] args,
    ) {
        import snakebite.nativelayout: loadIntegral, storeIntegral;

        // `layoutOf`/`callShapeOf` build under the compiler lock only on
        // a cache miss (`Cache.build`) and are read without it after;
        // `checkHostArgumentCount` and the binding below touch no dmd
        // state. Nothing from here to the end of this function takes the
        // compiler lock: a thread that held it while it waited for
        // another thread's callback - the way `Thread.join` waits here in
        // `otherThread`/`concurrentThreads` guest code - would never see
        // that callback return, since the callback's own slow paths need
        // this same lock (ADR-0006).
        auto layout = layoutOf(function_);
        auto shape = callShapeOf(function_);
        layout.checkHostArgumentCount(
            args.length, function_, "interpreter");
        auto frame = _frames.push(layout.size, layout.alignment);

        scope const(void*)[] declaredArguments = args;
        if (layout.hiddenThis.variable !is null) {
            if (args.length) {
                storeIntegral(
                    frame.base + layout.hiddenThis.parameter.offset,
                    loadIntegral(args[0], size_t.sizeof, false),
                    size_t.sizeof,
                );
                declaredArguments = args[1 .. $];
            } else
                storeIntegral(
                    frame.base + layout.hiddenThis.parameter.offset,
                    0, size_t.sizeof,
                );
        }

        try
            _temporaries.withTemporaryLifetime({
                bindHostArguments(
                    declaredArguments, frame.base, layout, shape);
                auto arguments = argumentSlots(frame.base, layout);
                _temporaries.withNestedCall({
                    executeRaw(
                        function_, returnPlace, frame.base, layout,
                        null, arguments.values.ptr,
                        arguments.values.length,
                    );
                });
            });
        catch (GuestException exception)
            throw exception.take;
    }

    extern(D) private void bindHostArguments(
        scope const(void*)[] args,
        ubyte* frameBase,
        const(FrameLayout)* layout,
        const(CallShape)* shape,
    ) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: loadIntegral;

        foreach (i, parameter; layout.parameters) {
            auto argument = args[i];
            shape.arguments[i].store(
                frameBase + parameter.offset,
                () => cast(void*) loadIntegral(
                    argument, size_t.sizeof, false),
                (void* place) {
                    memcpy(place, argument, parameter.facts.size);
                },
            );
        }
    }

    // Every hash lookup this evaluator has made to find where a name
    // lives: a variable's storage, or how to reach a called function.
    version(unittest)
    extern(D) final size_t nameLookups() @safe @nogc nothrow pure const scope {
        return _foreignNameLookups + _layouts.lookups + _staticLookups
            + _staticChains.lookups + _plans.nativeSymbolLookups;
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

    private bool hasIndependentNativeSymbol(FuncDeclaration function_) {
        return _plans.hasIndependentNativeSymbol(function_);
    }

    // `function_`'s frame layout, from the shared table; computed on its
    // first call on any thread. The returned pointer stays valid and is
    // the same on every thread.
    private const(FrameLayout)* layoutOf(FuncDeclaration function_) {
        if (auto cached = function_ in _layouts)
            return cached;

        return _layouts.build(function_, () => buildLayout(function_));
    }

    extern(D) private FrameLayout buildLayout(FuncDeclaration function_) {
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
        // safe only under the frontend-wide compiler lock, the same lock
        // every other reach into that structure already goes through -
        // without it, a second thread forcing the same forward reference
        // would race this one. `forceIfNeeded` takes that lock only when
        // `function_` is not already past `semantic3` - the common case
        // once some other program's evaluator has already reached this
        // same shared declaration - so a repeat build for a druntime
        // hook already forced by an earlier program never queues on the
        // lock at all; `FrameLayout.of` below forces the same pass again
        // through `hasHiddenThis`, its own independent reason to (used,
        // unlike this cache, by native FFI call sites this interpreter
        // never walks a body for), guarded the same way, so it is always
        // a no-op by the time it runs here.
        import core.atomic: atomicLoad, MemoryOrder;
        import dmd.dsymbol: PASS;
        import dmd.funcsem: functionSemantic3;
        import snakebite.frontend.compiler: forceIfNeeded;

        // Acquire load - see `forceIfNeeded`'s own doc
        // (`snakebite.frontend.compiler`) for why the unlocked check
        // needs that much, not a plain field read.
        forceIfNeeded(
            () => atomicLoad!(MemoryOrder.acq)(function_.semanticRun)
                >= PASS.semantic3done,
            () { functionSemantic3(function_); },
        );

        return FrameLayout.of(function_);
    }

    private const(CallShape)* callShapeOf(FuncDeclaration function_) {
        if (auto cached = function_ in _calls)
            return cached;

        return _calls.build(function_, () => buildCallShape(function_));
    }

    extern(D) private CallShape buildCallShape(FuncDeclaration function_) {
        auto parameterList = typeFunctionOf(function_).parameterList;
        CallAdapter.Argument[] arguments;
        arguments.length = parameterList.length;
        foreach (i; 0 .. parameterList.length)
            arguments[i] = CallAdapter.Argument.of(parameterList[i]);

        return CallShape(CallAdapter.of(function_), arguments);
    }

    // `ClosureLayout.of` reads `function_.closureVars`, which semantic3
    // (body semantic) populates - safe unlocked here because every
    // caller of `closureLayoutOf` (`allocateClosure`, only ever reached
    // after `functionNeedsClosure(function_)` answered `true`) already
    // forced that pass, under the frontend lock where it still needed
    // one, to get that very answer.
    private const(ClosureLayout)* closureLayoutOf(
        FuncDeclaration function_,
    ) {
        if (auto cached = function_ in _closures)
            return cached;

        return _closures.build(function_, () => ClosureLayout.of(function_));
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
        // Captured values can own the only references to other GC objects.
        auto allocation = new void[](closureLayout.size + padding);
        _allocations ~= allocation;

        const start = -cast(size_t) allocation.ptr
            & (closureLayout.alignment - 1);
        auto closure = cast(ubyte*) allocation.ptr + start;
        memset(closure, 0, closureLayout.size);

        if (layout.hiddenThis.variable !is null)
            memcpy(closure, frameBase + layout.hiddenThis.parameter.offset,
                size_t.sizeof);

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

        const facts = *_typeFacts.build(type, () => TypeFacts.of(type));
        _cachedType = type;
        _cachedFacts = facts;
        return facts;
    }

    // Runs one call through the FFI seam. The callee receives its frame
    // already reserved. Guest arguments are evaluated within construction
    // lifetime handling. The result adapter keeps `ref` results out of the
    // evaluator; the raw runner below only executes the selected callee.
    private CallResult executeCall(
        FuncDeclaration function_,
        void* returnPlace,
        ubyte* frameBase,
        const(FrameLayout)* layout,
        CallExp callSite = null,
    ) {
        auto arguments = argumentSlots(frameBase, layout);
        auto adapter = callShapeOf(function_).adapter;
        ubyte* receiver;

        scope void executeCallee(
            scope void* place,
            scope const(void*)[] arguments,
        ) {
            _temporaries.withNestedCall({
                executeRaw(
                    function_, place, frameBase, layout, callSite,
                    arguments.ptr, arguments.length,
                );
            });
            // A constructor's ref-qualified ABI result is its receiver.
            // An interpreted body has no return statement that stores it.
            if (adapter.isVoid && adapter.isReferenceResult)
                *cast(void**) place = receiver;
        }

        import snakebite.backends.temporary: constructTemporary;
        import snakebite.nativelayout: loadIntegral;

        CallResult result;
        constructTemporary(function_, {
            receiver = cast(ubyte*) loadIntegral(
                frameBase + layout.hiddenThis.parameter.offset,
                size_t.sizeof, false);
            _temporaries.suspendConstructor(receiver);
        }, {
            if (callSite !is null && typeFunctionOf(function_).isDstyleVariadic) {
                bindArguments(function_, callSite.arguments, callSite.loc,
                    frameBase, layout, true);
                bindVariadicArguments(callSite, frameBase, layout);
            } else if (callSite !is null)
                bindArguments(function_, callSite.arguments, callSite.loc,
                    frameBase, layout);
            result = adapter.invoke(
                returnPlace, arguments.values, &executeCallee);
        }, { _temporaries.armConstructor(receiver); });
        return result;
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
        // A declaration without a body can only describe a native call
        // or a builtin, regardless of which module owns it - never a
        // guest one, since there is no guest body to walk.
        auto body_ = function_.fbody;
        const decision = _callSelection.decisionOf(
            function_,
            (callee) => _program.isInterpreted(callee),
            hasNativeSymbol(function_),
            hasIndependentNativeSymbol(function_),
        );
        final switch (decision.route) with (CallSelection.Route) {
        case native:
            const plan = callSite is null
                ? _plans.of(function_)
                : callPlanOf(callSite, function_);
            callHost(
                function_, plan, returnPlace, arguments, argumentCount,
            );
            return;
        case builtin:
            decision.builtinEntry(returnPlace, arguments, argumentCount);
            return;
        case guest:
            break;
        }

        const guard = CallStateGuard(this);

        _closureBase = null;
        if (functionNeedsClosure(function_))
            _closureBase = allocateClosure(function_, frameBase, layout);

        _type = function_.type.nextOf;
        _facts = factsOf(_type);
        _place = returnPlace;
        _frameBase = frameBase;
        _layout = layout;
        _function = function_;
        _pendingLoopLabel = null;
        _controlFlow = ControlFlowState.init;
        _switchStatement = null;
        while (true) {
            body_.accept(this);
            if (!_controlFlow.hasGoto)
                break;

            _controlFlow.resume;
        }
    }

    private void callHost(
        FuncDeclaration hostFunction,
        const(CallPlan)* plan,
        void* returnPlace,
        const(void*)* arguments,
        size_t argumentCount,
    ) {
        callPlan(plan, returnPlace, arguments[0 .. argumentCount]);
    }

    // Every crossing of the barrier through a `CallPlan` shares this catch
    // chain (`callHost`, `throwArrayBounds`, `callVariadicNative`): native
    // code throws a real `Throwable`, not the `GuestException` wrapper a
    // guest `throw` or a failed native `assert` produces (`throwGuest`,
    // `visit(HaltStatement)`) - a guest `catch` only ever looks for that
    // wrapper (`visit(TryCatchStatement)`). A callback re-entering the
    // interpreter (`callGuestFromHost`) can also unwind through
    // here with a `GuestException` already, or with a `SnakebiteException`
    // reporting that the interpreter itself could not run the callback -
    // both must reach the host exactly as thrown, not double-wrapped or
    // reinterpreted as a guest-catchable exception.
    extern(D) private void callPlan(
        const(CallPlan)* plan,
        void* place,
        scope const(void*)[] slots,
    ) {
        try
            plan.call(place, slots);
        catch (SnakebiteException exception)
            throw exception;
        catch (GuestException exception)
            throw exception;
        catch (Throwable guest)
            throw new GuestException(guest);
    }

    // Calls druntime's own bounds-failure hook - `_d_arraybounds_indexp`
    // or `_d_arraybounds_slicep`, see `snakebite.backends.druntimehooks`
    // - the same one the bytecode compiler emits a call to. It never
    // returns, so every caller here only reaches this once its own bounds
    // check already failed; wrapping its throw through `callPlan`, the
    // same as any other native call, lets a guest `catch (RangeError)`
    // see it, instead of the interpreter's own refusal or a hand-built
    // guest exception.
    extern(D) private void throwArrayBounds(
        DruntimeHook hook,
        in Loc loc,
        scope const(void*)[] extraArguments,
    ) {
        import snakebite.backends.druntimehooks: planOf, specOf;

        auto plan = planOf(*_plans, hook);
        if (plan is null)
            throw new SnakebiteException(
                text("interpreter cannot resolve the symbol `",
                    specOf(hook).name, "`: it is not in this process"),
            );

        const file = cast(const(char)*) loc.filename;
        const line = cast(uint) loc.linnum;
        const(void*)[] arguments =
            [cast(const(void)*) &file, cast(const(void)*) &line]
            ~ extraArguments;

        callPlan(plan, null, arguments);
    }

    // The re-entry a pool entry (ADR-0003) reaches when host code calls a
    // guest function pointer or delegate. It shares `runHostToGuest` with
    // the program runner's top-level call: neither binds arguments on its
    // own. Runs on the calling thread's own evaluator, whichever thread
    // that is (ADR-0006), and holds no lock: see `runHostToGuest`. A
    // `Throwable` the body throws unwinds through the host frames
    // untouched (ADR-0004).
    extern(D) final void callGuestFromHost(CallbackCall* call) {
        runHostToGuest(call.declaration, call.returnPlace, call.arguments);
    }

    extern(D) final void prepareCallback(FuncDeclaration function_) {
        layoutOf(function_);
        callShapeOf(function_);
        functionNeedsClosure(function_);
        factsOf(function_.type.nextOf);
    }

    private void destroyTemporary(Expression expression) {
        runForEffect(expression);
    }

    private const(CallPlan)* callPlanOf(
        CallExp callSite,
        FuncDeclaration function_,
    ) {
        return cachedCallPlan(
            callSite, function_, () => _plans.of(function_));
    }

    // The call-site cache (issue #96) serves ordinary and variadic calls:
    // a call expression is one call site, even when
    // a loop visits it many times, so the plan cache proper
    // (`PlanCache._plans`/`.of`) stays the cold path, reached only once
    // per site through `build`.
    extern(D) private const(CallPlan)* cachedCallPlan(
        CallExp callSite,
        FuncDeclaration function_,
        scope const(CallPlan)* delegate() build,
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
        const plan = build();
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
        private Identifier _pendingLoopLabel;
        private ControlFlowState _controlFlow;
        private SwitchStatement _switchStatement;

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
            _pendingLoopLabel = evaluator._pendingLoopLabel;
            _controlFlow = evaluator._controlFlow;
            _switchStatement = evaluator._switchStatement;
        }

        ~this() {
            _evaluator._type = _type;
            _evaluator._facts = _facts;
            _evaluator._place = _place;
            _evaluator._frameBase = _frameBase;
            _evaluator._closureBase = _closureBase;
            _evaluator._layout = _layout;
            _evaluator._function = _function;
            _evaluator._pendingLoopLabel = _pendingLoopLabel;
            _evaluator._controlFlow = _controlFlow;
            _evaluator._switchStatement = _switchStatement;
        }
    }

    // Where the hidden context and each explicit parameter's bytes sit in
    // the frame the caller just filled: what the FFI needs to hand them
    // over, built from the layout this interpreter already computed.
    extern(D) private CallArguments argumentSlots(
        ubyte* frameBase,
        const(FrameLayout)* layout,
    ) {
        auto arguments = CallArguments(layout.parameters.length
            + (layout.hiddenThis.variable !is null));
        auto values = arguments.values; // The address slots must stay mutable.
        size_t count;
        if (layout.hiddenThis.variable !is null)
            values[count++] = frameBase + layout.hiddenThis.parameter.offset;
        foreach (parameter; layout.parameters)
            values[count++] = frameBase + parameter.offset;
        return arguments;
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
        if (_controlFlow.seeking) {
            try {
                if (statement._body !is null)
                    statement._body.accept(this);
            } catch (GuestException exception) {
                foreach (catch_; *statement.catches) {
                    if (!matchesThrowable(catch_, exception))
                        continue;

                    bindCatchVariable(catch_, exception.take);
                    catch_.handler.accept(this);
                    return;
                }

                throw exception;
            }
            if (_controlFlow.seeking)
                foreach (catch_; *statement.catches)
                    if (catch_.handler !is null)
                        catch_.handler.accept(this);
            return;
        }

        try {
            statement._body.accept(this);
        } catch (GuestException exception) {
            foreach (catch_; *statement.catches) {
                if (!matchesThrowable(catch_, exception))
                    continue;

                bindCatchVariable(catch_, exception.take);
                catch_.handler.accept(this);
                return;
            }

            throw exception;
        }
    }

    private Statement controlTarget() const {
        return cast(Statement) _controlFlow.target;
    }

    private bool exitsFinally(TryFinallyStatement statement) const {
        auto target = controlTarget;
        if (target is null)
            return false;

        return cleanupCount(
            scopePath(statement),
            scopePath(cast(Statement) _controlFlow.destinationScope),
        ) != 0;
    }

    override void visit(TryFinallyStatement statement) {
        bool bodyRan;
        Throwable pendingException;
        if (_controlFlow.seeking) {
            if (statement._body !is null)
                statement._body.accept(this);
            bodyRan = true;
            if (_controlFlow.seeking && statement.finalbody !is null)
                statement.finalbody.accept(this);
            if (_controlFlow.seeking)
                return;
        }

        try {
            if (!bodyRan && statement._body !is null)
                statement._body.accept(this);

            while (_controlFlow.hasGoto && !exitsFinally(statement)) {
                _controlFlow.resume;
                if (statement._body !is null)
                    statement._body.accept(this);
            }
        } catch (GuestException exception) {
            pendingException = exception.take;
        } finally {
            _controlFlow.withCleanup({
                runFinallyBody(statement.finalbody, pendingException);
            });
        }
    }

    private void runFinallyBody(
        Statement finalbody,
        Throwable pendingException,
    ) {
        if (pendingException is null) {
            runCleanupBody(finalbody);
            return;
        }

        try {
            import snakebite.backends.exceptions: unwindFinally;

            unwindFinally(pendingException, {
                try
                    runCleanupBody(finalbody);
                catch (GuestException exception)
                    throw exception.take;
            });
        } catch (Throwable exception) {
            throw new GuestException(exception);
        }
    }

    private void runCleanupBody(Statement finalbody) {
        if (finalbody is null)
            return;

        finalbody.accept(this);
        while (_controlFlow.hasGoto) {
            _controlFlow.resume;
            finalbody.accept(this);
        }
    }

    // Whether `catch_`'s own declared type accepts `exception`'s actual
    // thrown object. A guest throwable's actual declaration is already
    // known (`declarationOf`, the reverse of `classRuntimeInfo`'s own
    // cache), so this stays the AST-level comparison it always was for
    // that case - no runtime metadata to build while unwinding a guest
    // `throw`, the hot path every guest exception takes. A native
    // throwable has no such declaration; matching it reads the same
    // native `TypeInfo_Class` the bytecode VM's `findHandler` already
    // compares by identity, in place of the name string this used to
    // compare instead.
    private bool matchesThrowable(Catch catch_, GuestException exception) {
        auto typeClass = catch_.type.isTypeClass;
        if (typeClass is null)
            return false;

        auto actual = exception._guest.classinfo;
        auto declaration = declarationOf(actual);
        if (declaration !is null)
            return typeClass.sym is *declaration
                || typeClass.sym.isBaseOf(*declaration, null);

        import snakebite.backends.exceptions: catchMatches;

        return catchMatches(catchRuntimeInfo(catch_), actual);
    }

    private TypeInfo_Class catchRuntimeInfo(Catch catch_) {
        if (auto cached = catch_ in _catchTypes)
            return *cached;

        return *_catchTypes.build(catch_,
            () => cast(TypeInfo_Class) _runtimeTypes.get(catch_.type));
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
                child.accept(this);
                if (_controlFlow.hasTransfer)
                    return;
            }
        }
    }

    override void visit(UnrolledLoopStatement statement) {
        // A tuple `foreach` is a real loop for labelled control flow too.
        auto loopLabel = _pendingLoopLabel;
        _pendingLoopLabel = null;

        if (statement.statements is null)
            return;

        foreach (child; *statement.statements) {
            if (child !is null) {
                child.accept(this);
                if (_controlFlow.leavesLoop(loopLabel))
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
    // just running whatever it wraps, honouring pending transfers the same way
    // `visit(CompoundStatement)` does for its own children.
    override void visit(ScopeStatement statement) {
        if (statement.statement is null)
            return;

        statement.statement.accept(this);
    }

    // Semantic analysis resolves every member in a `with` body through its
    // compiler-generated `wthis` temporary. Initialise that temporary once
    // before the body, so an aggregate expression has the same evaluation
    // and aliasing behaviour as compiled D. A type `with` has no temporary:
    // it only changes name lookup, which semantic analysis already did.
    override void visit(WithStatement statement) {
        if (_controlFlow.seeking) {
            if (statement._body !is null)
                statement._body.accept(this);
            return;
        }

        if (statement.wthis !is null) {
            auto initializer = statement.wthis._init.isExpInitializer;
            if (initializer is null)
                throw new SnakebiteException(
                    "interpreter cannot initialize `with` expression",
                );

            evaluate(
                initializerValueOf(initializer),
                statement.wthis.type,
                storageOf(statement.wthis),
            );
        }

        if (statement._body !is null)
            statement._body.accept(this);
    }

    override void visit(ReturnStatement statement) {
        if (_controlFlow.seeking)
            return;

        _controlFlow.returnFromFunction;

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

        _temporaries.withExpression(FullExpressionKind.value, statement.exp, {
            void* referenceAddress() {
                return addressOf(statement.exp);
            }

            void evaluateValue() {
                // `_type`/`_facts` are already this function's return type
                // and its facts, set together on entry (`executeRaw`) or by
                // the last `evaluate`, so this callback needs no fresh type
                // lookup.
                if (_place !is null) {
                    evaluate(statement.exp, _type, _facts, _place);
                    return;
                }

                // The caller discarded the result, but evaluating the
                // expression can have effects, so it still runs - into a
                // reservation on the frame stack, popped when it goes out
                // of scope, not into a GC allocation.
                auto frame = _frames.push(_facts.size, _facts.alignment);
                evaluate(statement.exp, _type, _facts, frame.base);
            }

            callShapeOf(_function).adapter.returnFromCall(
                _place, &referenceAddress, &evaluateValue,
            );
        });
    }

    override void visit(ExpStatement statement) {
        if (_controlFlow.seeking)
            return;

        if (statement.exp is null)
            return;

        runFullExpression(statement.exp);
    }

    // Runs one full expression for its effects, giving back its rvalue
    // temporaries afterward - the end of the full expression is where D
    // destroys them. The mark is recorded before anything can reserve a
    // temporary, so a guest throw from any point of the evaluation still
    // releases whatever was reserved by then.
    private void runFullExpression(Expression expression) {
        _temporaries.withExpression(FullExpressionKind.effect, expression, {
            runForEffect(expression);
        });
    }

    // A condition is a full expression of its own on each evaluation - a
    // loop's every test included - so its temporaries are given back as
    // soon as its truth is known.
    private bool conditionHolds(Expression condition) {
        bool result;
        _temporaries.withExpression(FullExpressionKind.value, condition, {
            result = truthOf(condition);
        });
        return result;
    }

    override void visit(BreakStatement statement) {
        if (_controlFlow.seeking)
            return;

        _controlFlow.breakTo(statement.ident);
    }

    override void visit(LabelStatement statement) {
        _controlFlow.at(cast(void*) statement);
        if (statement.statement !is null)
            _controlFlow.at(cast(void*) statement.statement);

        auto previousLabel = _pendingLoopLabel;
        _pendingLoopLabel = statement.ident;
        scope (exit) _pendingLoopLabel = previousLabel;

        if (statement.statement !is null)
            statement.statement.accept(this);

        _controlFlow.finishLabel(statement.ident);
    }

    override void visit(SwitchStatement statement) {
        _pendingLoopLabel = null;

        if (_controlFlow.seeking) {
            if (statement._body !is null)
                statement._body.accept(this);
            return;
        }

        Statement selected;
        _temporaries.withExpression(FullExpressionKind.value,
            statement.condition, {
            const condition = asIntegral(statement.condition);
            if (statement.cases !is null)
                foreach (case_; *statement.cases) {
                    if (asIntegral(case_.exp) == condition) {
                        selected = case_;
                        break;
                    }
                }
            });

        if (selected is null)
            selected = statement.sdefault;
        if (selected is null)
            return;

        auto outerSwitch = _switchStatement;
        _switchStatement = statement;
        scope (exit)
            _switchStatement = outerSwitch;

        while (true) {
            _controlFlow.seek(cast(void*) selected);
            statement._body.accept(this);

            if (_controlFlow.leavesSwitch)
                return;

            auto target = controlTarget;
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

            _controlFlow.resume;
            selected = target;
        }
    }

    override void visit(CaseStatement statement) {
        _controlFlow.at(cast(void*) statement);
        if (statement.statement !is null)
            statement.statement.accept(this);
    }

    override void visit(DefaultStatement statement) {
        _controlFlow.at(cast(void*) statement);
        if (statement.statement !is null)
            statement.statement.accept(this);
    }

    override void visit(GotoCaseStatement statement) {
        if (_controlFlow.seeking)
            return;

        if (statement.cs is null)
            throw new SnakebiteException(
                "interpreter cannot execute an unresolved `goto case`",
            );

        if (_switchStatement is null)
            throw new SnakebiteException(
                "interpreter cannot execute `goto case` outside a switch",
            );

        _controlFlow.transfer(
            cast(void*) statement.cs,
            cast(void*) _switchStatement.tryBody,
        );
    }

    override void visit(GotoDefaultStatement statement) {
        if (_controlFlow.seeking)
            return;

        if (statement.sw is null || statement.sw.sdefault is null)
            throw new SnakebiteException(
                "interpreter cannot execute an unresolved `goto default`",
            );

        _controlFlow.transfer(
            cast(void*) statement.sw.sdefault,
            cast(void*) statement.sw.tryBody,
        );
    }

    override void visit(GotoStatement statement) {
        if (_controlFlow.seeking)
            return;

        if (statement.label is null || statement.label.statement is null)
            throw new SnakebiteException(
                "interpreter cannot execute an unresolved `goto`",
            );

        _controlFlow.transfer(
            cast(void*) statement.label.statement,
            cast(void*) statement.label.statement.tryBody,
        );
    }

    protected override void visitThrowStatement(ThrowStatement statement) {
        if (_controlFlow.seeking)
            return;

        _temporaries.withTemporaryLifetime({
            throwGuest(statement.exp);
        });
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
        if (expression.isDeclarationExp !is null) {
            expression.accept(this);
            return;
        }

        // A tuple result is a sequence of effects, not a native value. This
        // also covers enclosing expressions such as `CommaExp` whose type is
        // the tuple result of their right operand.
        if (expression.type.ty == Ttuple) {
            expression.accept(this);
            return;
        }

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

    protected extern(C++) override void visitTupleElement(
        Expression expression,
    ) {
        runForEffect(expression);
    }

    // Only the branch that runs is walked: the other one never executes,
    // so nothing in it is ever evaluated, not even to be discarded.
    override void visit(IfStatement statement) {
        if (_controlFlow.seeking) {
            if (statement.ifbody !is null)
                statement.ifbody.accept(this);
            if (_controlFlow.seeking && statement.elsebody !is null)
                statement.elsebody.accept(this);
            return;
        }

        auto taken = conditionHolds(statement.condition)
            ? statement.ifbody
            : statement.elsebody;

        if (taken !is null)
            taken.accept(this);
    }

    override void visit(ForStatement statement) {
        auto loopLabel = _pendingLoopLabel;
        _pendingLoopLabel = null;

        bool bodyRan;
        if (_controlFlow.seeking) {
            if (statement._body !is null)
                statement._body.accept(this);
            if (_controlFlow.seeking)
                return;
            bodyRan = true;
        }

        while (bodyRan || statement.condition is null
                || conditionHolds(statement.condition)) {
            if (statement._body !is null) {
                if (!bodyRan)
                    statement._body.accept(this);
                bodyRan = false;
                if (_controlFlow.leavesLoop(loopLabel))
                    return;
            }

            if (statement.increment !is null)
                runFullExpression(statement.increment);
        }
    }

    override void visit(DoStatement statement) {
        auto loopLabel = _pendingLoopLabel;
        _pendingLoopLabel = null;

        bool bodyRan;
        if (_controlFlow.seeking) {
            if (statement._body !is null)
                statement._body.accept(this);
            if (_controlFlow.seeking)
                return;
            bodyRan = true;
        }

        while (true) {
            if (!bodyRan && statement._body !is null)
                statement._body.accept(this);
            bodyRan = false;

            if (_controlFlow.leavesLoop(loopLabel))
                return;

            if (!conditionHolds(statement.condition))
                return;
        }
    }

    override void visit(ContinueStatement statement) {
        if (_controlFlow.seeking)
            return;

        _controlFlow.continueTo(statement.ident);
    }

    // `TypeFacts.Truth` decides which native bytes of `expression`'s
    // value make it true - the whole value for a pointer, a class
    // reference, an associative array's handle, or an integral; only the
    // pointer word for a dynamic array; either of a delegate's two words
    // (`ptr`, `funcptr`) - so this method carries no case of its own for
    // any of them, and reads the same shared rule the bytecode compiler
    // does.
    private bool truthOf(Expression expression) {
        import snakebite.nativelayout: TypeFacts, loadIntegral;
        import snakebite.nativevalue: loadFloating;
        import std.conv: text;

        auto type = expression.type;
        const truth = TypeFacts.Truth.of(type);
        if (!truth.supported)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "` as a condition: its type is `", type.toString, "`"),
            );

        // Sized to `creal`, the widest condition value `Truth.of` ever
        // answers `supported` for - a plain real, an imaginary, or one
        // component of a complex all fit within it too.
        const facts = factsOf(type);
        align(real.alignof) ubyte[2 * real.sizeof] buffer = void;
        assert(facts.size <= buffer.sizeof,
            "a condition value wider than a `creal` reached the scratch"
                ~ " buffer");
        evaluate(expression, type, facts, buffer.ptr);

        if (truth.isFloat) {
            if (loadFloating(buffer.ptr + truth.offset, truth.size) != 0)
                return true;
            if (truth.secondOffset == TypeFacts.Truth.noSecondWord)
                return false;
            return loadFloating(
                buffer.ptr + truth.secondOffset, truth.size) != 0;
        }

        if (loadIntegral(buffer.ptr + truth.offset, truth.size, false) != 0)
            return true;
        if (truth.secondOffset == TypeFacts.Truth.noSecondWord)
            return false;
        return loadIntegral(
            buffer.ptr + truth.secondOffset, size_t.sizeof, false) != 0;
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

        auto type = expression.type.toBasetype;
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
        if (type.ty != Tpointer && type.ty != Tclass)
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

    private void* asReference(Expression expression, in TypeFacts facts) {
        align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
        assert(facts.size <= buffer.sizeof && facts.alignment <= buffer.alignof,
            "a reference wider than a register reached the scratch buffer");
        evaluate(expression, expression.type, facts, buffer.ptr);
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
        _nativeData.write(_type, _facts, expression, _place);
    }

    override void visit(RealExp expression) {
        _nativeData.write(_type, _facts, expression, _place);
    }

    // `1.0f + 0.0fi`: dmd's own constant folding already reduces
    // `complex`-literal arithmetic to one `ComplexExp` (`EXP.complex80`
    // regardless of the actual `cfloat`/`cdouble`/`creal` width - only
    // `.type` differs), the same compile-time constant `RealExp` above
    // is for a real one.
    override void visit(ComplexExp expression) {
        _nativeData.write(_type, _facts, expression, _place);
    }

    override void visit(NullExp expression) {
        _nativeData.write(_type, _facts, expression, _place);
    }

    // `int4 v = 1;`/`cast(int4) 1`: dmd's own semantic pass (`dcast.d`)
    // rewrites either shape to this node, `e1` already cast to the
    // vector's own element type, and its meaning is "every lane gets
    // this one value" - filling the first lane by evaluating `e1`
    // straight into `_place` and then copying those same bytes to every
    // remaining lane. `int4 v = cast(int4) someInt4Sarray;` reaches this
    // node too, with `e1` a matching-size static array instead: dmd's
    // own `dcast.d` (`T[n] <-- __vector(U[m])`... in reverse) wraps
    // that shape here rather than the scalar element cast, and its
    // meaning is a plain reinterpret of the array's own bytes, not a
    // broadcast of a single "element".
    override void visit(VectorExp expression) {
        import core.stdc.string: memcpy;

        if (expression.e1.type.toBasetype.ty == Tsarray) {
            evaluate(expression.e1, expression.e1.type,
                factsOf(expression.e1.type), _place);
            return;
        }

        const elementFacts = factsOf(expression.e1.type);
        evaluate(expression.e1, expression.e1.type, elementFacts, _place);
        auto bytes = cast(ubyte*) _place;
        foreach (i; 1 .. _facts.size / elementFacts.size)
            memcpy(bytes + i * elementFacts.size, bytes, elementFacts.size);
    }

    // `someVector.array`: dmd's own semantic pass (`typesem.d`'s
    // `TypeVector.dotExp`, `Id.array`) reinterprets the vector as its
    // own `basetype` static array - the same bytes, so evaluating `e1`
    // with its own (vector) type straight into `_place` already is the
    // static array's own value.
    override void visit(VectorArrayExp expression) {
        evaluate(
            expression.e1, expression.e1.type, factsOf(expression.e1.type),
            _place,
        );
    }

    override void visit(StringExp expression) {
        _nativeData.write(_type, _facts, expression, _place);
    }

    // Stored function pointers must also be callable from host code when
    // they arrive inside an aggregate or through a pointer to guest data.
    // The barrier cannot replace function words hidden in that storage.
    override void visit(FuncExp expression) {
        import snakebite.frontend.dmd.delegates: delegateTargetOf;
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, storeIntegral;
        import std.conv: text;

        auto literal = expression.fd;

        if (_type.ty != Tdelegate) {
            if (literal is null || literal.isThis() !is null
                    || expression.type.ty != Tpointer)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `", expression.toString,
                        "` as a `", _type.toString, "`"),
                );

            auto bytes = cast(ubyte*) _place;
            if (bytes is null)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `", expression.toString,
                        "`: it has no destination"),
                );
            storeIntegral(
                bytes, cast(size_t) callableAddress(literal, 0), size_t.sizeof);
            return;
        }

        storeDelegateValue(
            delegateTargetOf(literal, _type), expression, _place);
    }

    // `&nested` is lowered by dmd to a DelegateExp whose expression is the
    // nested function itself. Its context is the enclosing frame or heap
    // closure, just as for a delegate literal.
    override void visit(DelegateExp expression) {
        import snakebite.frontend.dmd.delegates: delegateTargetOf;

        storeDelegateValue(
            delegateTargetOf(expression.func, _type, expression.e1),
            expression, _place);
    }

    // A delegate keeps its native context word so compiled code can pass
    // that context back through the callback entry without conversion.
    private void storeDelegateValue(
        DelegateTarget target,
        Expression expression,
        void* place,
    ) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, storeIntegral;
        import std.conv: text;

        if (target.function_ is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its delegate declaration is unsupported"),
            );

        auto context = cast(size_t) 0;
        if (target.receiver !is null) {
            if (target.receiverIsAddress)
                context = cast(size_t) addressOf(target.receiver);
            else
                evaluate(target.receiver, target.receiver.type,
                    factsOf(target.receiver.type), &context);

        } else if (target.needsContext) {
            if (target.contextOwner is null)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `",
                        expression.toString,
                        "`: its enclosing function could not be determined"),
                );
            context = cast(size_t) tryContextOf(target.contextOwner);
        }

        auto bytes = cast(ubyte*) place;
        if (bytes is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: it has no destination"),
            );
        storeIntegral(
            bytes + delegateContextOffset, context, size_t.sizeof);
        void* address;
        if (target.virtualDispatch)
            address = _virtualAddress(target.function_, cast(void*) context);
        else
            address = callableAddress(target.function_, 0);
        storeIntegral(bytes + delegateFunctionOffset,
            cast(size_t) address, size_t.sizeof);
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
        import snakebite.frontend.dmd.delegates: isCtfeVariable;
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        // See `snakebite.frontend.dmd.delegates.isCtfeVariable`: shared with
        // the bytecode backend.
        if (isCtfeVariable(expression.var)) {
            storeIntegral(_place, 0, _facts.size);
            return;
        }

        if (expression.var is _dollar.var) {
            storeIntegral(_place, _dollar.length, _facts.size);
            return;
        }

        // initSymbol exposes the aggregate's native initializer as bytes.
        // Keep the image in the same storage used for default values and
        // class runtime information so its address remains valid.
        if (auto symbol = expression.var.isSymbolDeclaration) {
            if (symbol.type.isTypeStruct !is null) {
                initializeDefault(_type, _facts, cast(ubyte*) _place,
                    expression.loc);
                return;
            }

            auto declaration = symbol.dsym.isAggregateDeclaration;
            if (declaration is null)
                throw new SnakebiteException(
                    text("interpreter cannot evaluate `", expression.toString,
                        "`: unsupported initializer symbol"),
                );
            const initial = _runtimeTypes.initializer(declaration);

            import snakebite.nativelayout:
                arrayLengthOffset, arrayPointerOffset;

            auto bytes = cast(ubyte*) _place;
            storeIntegral(
                bytes + arrayLengthOffset, initial.length, size_t.sizeof);
            *cast(const(void)**) (bytes + arrayPointerOffset) = initial.ptr;
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

        if (owner is _function)
            return functionNeedsClosure(_function) ? _closureBase : _frameBase;

        const path = staticChainOf(owner);
        if (path is null)
            return null;

        auto base = _frameBase;
        foreach (const hop; path) {
            if (base is null)
                return null;
            base = cast(ubyte*) loadIntegral(
                base + hop.offset, size_t.sizeof, false);
        }

        return base;
    }

    // The hops from `_function`'s own frame to `owner`'s context, as
    // `staticChainPath` decides them; `null` when `owner` is not on the
    // chain at all. `staticChainPath` walks every function between the
    // two with `FrameLayout.of`/`functionNeedsClosure`, and both already
    // force semantic3 themselves, guarded, wherever they are called from
    // - so nothing extra is forced here.
    extern(D) private const(Hop)[] staticChainOf(FuncDeclaration owner) {
        import snakebite.backends.staticchain: staticChainPath;

        const key = StaticChainKey(
            cast(const(void)*) _function, cast(const(void)*) owner);
        if (auto cached = key in _staticChains)
            return *cached;

        return *_staticChains.build(key,
            () => staticChainPath(_function, owner));
    }

    // The answer shared with the bytecode compiler
    // (`snakebite.frontend.dmd.delegates.functionNeedsClosure`), kept: dmd
    // works it out by walking every captured variable's references each
    // time it is asked, and this evaluator asks on every reach of a
    // variable.
    private bool functionNeedsClosure(FuncDeclaration function_) {
        if (auto cached = function_ in _needsClosure)
            return *cached;

        import snakebite.frontend.dmd.delegates:
            sharedFunctionNeedsClosure = functionNeedsClosure;

        return *_needsClosure.build(function_,
            () => sharedFunctionNeedsClosure(function_));
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

        if (auto slot = _layout.slotOf(variable))
            return _frameBase + slot.offset;

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

        if (auto slot = _layout.slotOf(variable))
            return slot.isRef;

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
        auto slot = layout.slotOf(variable);
        if (slot is null) {
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
            slot = layout.slotOf(variable);
        }

        if (slot is null)
            return base + layout.offsetOf(variable);

        auto address = base + slot.offset;

        // A `ref` variable's own slot holds the address of the referenced
        // storage, not the storage itself. Reading through it once more here,
        // the one place every read, write and address-of a variable resolves
        // its slot, makes a reach of the variable reach its target instead.
        if (slot.isRef)
            return cast(ubyte*) loadIntegral(
                address, size_t.sizeof, false);

        return address;
    }

    extern(D) private ubyte* staticSlotOf(VarDeclaration variable) {
        version(unittest) ++_staticLookups;
        return cast(ubyte*) _nativeData.storageOf(variable).ptr;
    }

    // Runs a local's initializer into the frame slot `layoutOf` already
    // gave it. `long sum = 0;` is a `DeclarationExp` here.
    override void visit(DeclarationExp expression) {
        import snakebite.backends.declaration: forEachRuntimeVariable;

        forEachRuntimeVariable(expression.declaration, (variable) {
            initializeDeclaredVariable(variable, expression);
        });
    }

    private void initializeDeclaredVariable(
        VarDeclaration variable, DeclarationExp expression,
    ) {
        import std.conv: text;

        // A data-segment variable is initialised once, when the guest
        // first reaches it, not every time its declaration executes.
        if (variable.isDataseg)
            return;

        // `T value = void` requests storage without initialization. The
        // frame slot already exists, so executing this declaration performs
        // no write. Code must assign any bytes it reads, as in compiled D.
        if (variable._init is null || variable._init.isVoidInitializer !is null)
            return;

        auto expInitializer = variable._init.isExpInitializer;
        if (expInitializer is null)
            throw new SnakebiteException(
                text("interpreter cannot run the initializer for `",
                    expression.toString, "`: only a plain expression ",
                    "initializer is supported"),
            );

        auto slot = storageOf(variable);

        if (initializerConstructsThroughSlice(expInitializer, variable)) {
            _temporaries.initialize(variable, expression, slot, {
                runForEffect(expInitializer.exp);
            });
            return;
        }

        auto value = initializerValueOf(expInitializer);
        _temporaries.initialize(variable, expression, slot, {
            if (isRefStorage(variable)) {
                import snakebite.nativelayout: storeIntegral;

                storeIntegral(slot, cast(size_t) addressOf(value),
                    size_t.sizeof);
            } else
                evaluate(value, variable.type, slot);
        });
    }

    protected override void visitUnloweredConstruct(ConstructExp expression) {
        assign(expression);
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

    override void visit(BlitExp expression) {
        assign(expression);
    }

    private void* assign(AssignExp expression) {
        return addressOf(expression);
    }

    private void* assignAt(AssignExp expression, void* target) {
        import core.stdc.string: memcpy;
        import snakebite.backends.assignment: executeAssignment;
        import snakebite.nativelayout: loadIntegral, storeIntegral;

        const isConstruct = expression.isConstructExp !is null;

        if (auto dot = expression.e1.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field !is null && field.isBitFieldDeclaration !is null) {
                const valueFacts = factsOf(expression.e2.type);
                auto scratch = _frames.push(valueFacts.size,
                    valueFacts.alignment);
                evaluate(expression.e2, expression.e2.type,
                    valueFacts, scratch.base);
                const result = loadIntegral(
                    scratch.base, valueFacts.size, !valueFacts.isUnsigned);
                storeBitfieldAt(field, target, result);
                storeIntegral(_place, result, _facts.size);
                return _place;
            }
        }

        void* delegate(size_t, size_t) reserve =
            (size_t size, size_t alignment) {
            return _temporaries.reserveValue(
                size, cast(uint) alignment);
        };
        void delegate(void*) evaluateRhs = (void* value) {
            evaluate(expression.e2, _type, _facts, value);
        };
        void delegate(void*) publish = (void* value) {
            memcpy(target, value, _facts.size);
        };
        executeAssignment!(void*, reserve, evaluateRhs, publish)(
            isConstruct, target, _facts.size, _facts.alignment);
        if (_place !is null)
            memcpy(_place, target, _facts.size);
        return target;
    }

    // The shared resolver has already selected the slice-assignment primitive
    // before this hook runs. The DMD node metadata selects the primitive's
    // native scalar-fill or array-copy operation; no lvalue classification is
    // repeated here.
    private void* assignSliceAt(AssignExp expression, void* target) {
        if (expression.memset == MemorySet.blockAssign)
            return assignSliceScalar(expression, target);
        if (expression.e2.type.ty == Tarray)
            return assignSlice(expression, target);
        return assignSliceScalar(expression, target);
    }

    // A scalar slice assignment evaluates the right side once before any
    // destination element is overwritten: `a[] = a[0]` fills every element
    // with the old first value. DMD marks this shape with `blockAssign`,
    // including the static-array initialization lowering that reaches it as
    // a `T[]` slice despite the underlying storage being a `T[N]`.
    private void* assignSliceScalar(AssignExp expression, void* target) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, isNativeBytes,
            loadIntegral;
        import std.conv: text;

        auto elementType = _type.nextOf;
        if (elementType is null)
            throw new SnakebiteException(
                text("interpreter cannot fill `", expression.e1.toString,
                    "`: it has no element type"),
            );
        if (!isNativeBytes(elementType))
            throw new SnakebiteException(
                text("interpreter cannot fill `", expression.e1.toString,
                    "`: its element type is `", elementType.toString, "`"),
            );
        const elementFacts = factsOf(elementType);
        const sourceFacts = factsOf(expression.e2.type);
        if (sourceFacts.size != elementFacts.size)
            throw new SnakebiteException(
                text("interpreter cannot fill `", expression.e1.toString,
                    "`: source `", expression.e2.type.toString,
                    "` and element `", elementType.toString,
                    "` have different sizes"),
            );

        auto destination = _frames.push(_facts.size, _facts.alignment);
        // `addressOf` has already evaluated the slice bounds and left its
        // descriptor at `target`. Reuse that value so each bound runs once.
        memcpy(destination.base, target, _facts.size);
        auto value = _frames.push(sourceFacts.size, sourceFacts.alignment);
        evaluate(
            expression.e2, expression.e2.type, sourceFacts, value.base,
        );

        const length = loadIntegral(
            destination.base + arrayLengthOffset, size_t.sizeof, false);
        auto element = *cast(ubyte**) (
            destination.base + arrayPointerOffset);
        foreach (_; 0 .. length) {
            memcpy(element, value.base, elementFacts.size);
            element += elementFacts.size;
        }

        memcpy(_place, destination.base, _facts.size);
        return destination.base;
    }

    // `a[] = b[]`: both sides are evaluated as ordinary dynamic-array
    // values first, then handed to druntime so its length and overlap
    // checks stay authoritative.
    private void* assignSlice(AssignExp expression, void* target) {
        import core.stdc.string: memcpy;
        import snakebite.druntime.arraycopy: _d_arraycopy;

        auto destination = _frames.push(_facts.size, _facts.alignment);
        // `addressOf` has already evaluated the slice bounds and left its
        // descriptor at `target`. Reuse that value so each bound runs once.
        memcpy(destination.base, target, _facts.size);
        auto source = _frames.push(_facts.size, _facts.alignment);
        evaluate(expression.e2, _type, _facts, source.base);

        const elementSize = factsOf(_type.nextOf).size;
        try
            _d_arraycopy(
                elementSize,
                *cast(void[]*) source.base,
                *cast(void[]*) destination.base,
            );
        catch (SnakebiteException exception)
            throw exception;
        catch (GuestException exception)
            throw exception;
        catch (Throwable guest)
            throw new GuestException(guest);

        memcpy(_place, destination.base, _facts.size);
        return destination.base;
    }

    // The address of the storage `target` names: a variable's own slot
    // (through a `ref` parameter's indirection, if it is one - see
    // `slotOf`), the address a pointer currently holds for `*p`, whichever
    // branch a `ref`-typed `cond ? a : b` took, or the address a `ref`-
    // returning call hands back. An assignment's left side and a `ref`
    // argument's binding both need exactly this - "where does this
    // lvalue live" - so both come here rather than each walking the same
    // handful of node kinds on their own.
    private struct StorageAdapter {
        Evaluator evaluator;

        public void* storageThis(ThisExp expression) {
            auto slot = evaluator.slotOf(
                expression,
                expression.var is null
                    ? cast() evaluator._layout.hiddenThis.variable
                    : expression.var,
            );
            if (expression.type.ty == Tclass) {
                import snakebite.nativelayout: loadIntegral;

                return cast(void*) loadIntegral(slot, size_t.sizeof, false);
            }
            return slot;
        }

        public void* storageSuper(SuperExp expression) {
            return storageThis(cast(ThisExp) expression);
        }

        public void* storageVariable(VarExp expression) {
            return evaluator.slotOf(expression);
        }

        public void* storageReferenceInit(AssignExp expression) {
            auto variable = expression.e1.isVarExp;
            auto declaration = variable is null
                ? null : variable.var.isVarDeclaration;
            if (declaration is null)
                throw new SnakebiteException(
                    "interpreter cannot initialize a non-variable reference",
                );

            import snakebite.nativelayout: storeIntegral;

            // DMD marks reference construction separately from ordinary
            // assignment. Keep the declaration's own slot, rather than
            // resolving it through the reference it does not hold yet.
            auto target = evaluator.storageOf(declaration);
            auto source = evaluator.addressOf(expression.e2);
            storeIntegral(target, cast(size_t) source, size_t.sizeof);
            return source;
        }

        public void* storagePointer(PtrExp expression) {
            return evaluator.asPointer(expression.e1);
        }

        public void storageEffect(Expression expression) {
            evaluator.runForEffect(expression);
        }

        public extern(D) void* storageConditional(
            CondExp expression,
            scope void* delegate(Expression) resolve,
        ) {
            return resolve(evaluator.truthOf(expression.econd)
                ? expression.e1 : expression.e2);
        }

        public void* storageStructLiteral(StructLiteralExp expression) {
            return evaluator.structLiteralAddress(expression);
        }

        public void* storageSlice(SliceExp expression) {
            return storageValue(expression);
        }

        public void* storageLowered(Expression expression) {
            const facts = evaluator.factsOf(expression.type);
            auto temporary = evaluator._temporaries.reserveValue(
                facts.size, facts.alignment);
            evaluator.evaluate(expression, expression.type, facts, temporary);
            return temporary;
        }

        public void storagePlainAssignment(
            AssignExp expression, void* target,
        ) {
            auto savedType = evaluator._type;
            auto savedFacts = evaluator._facts;
            auto savedPlace = evaluator._place;
            scope(exit) {
                evaluator._type = savedType;
                evaluator._facts = savedFacts;
                evaluator._place = savedPlace;
            }

            evaluator._type = expression.type;
            evaluator._facts = evaluator.factsOf(expression.type);
            evaluator.assignAt(expression, target);
        }

        public void storageSliceAssignment(
            AssignExp expression, void* target,
        ) {
            auto savedType = evaluator._type;
            auto savedFacts = evaluator._facts;
            auto savedPlace = evaluator._place;
            scope(exit) {
                evaluator._type = savedType;
                evaluator._facts = savedFacts;
                evaluator._place = savedPlace;
            }

            evaluator._type = expression.type;
            evaluator._facts = evaluator.factsOf(expression.type);
            evaluator.assignSliceAt(expression, target);
        }

        public void storageCompoundAssignment(
            BinAssignExp expression, void* target,
        ) {
            auto savedType = evaluator._type;
            auto savedFacts = evaluator._facts;
            auto savedPlace = evaluator._place;
            scope(exit) {
                evaluator._type = savedType;
                evaluator._facts = savedFacts;
                evaluator._place = savedPlace;
            }

            evaluator._type = expression.type;
            evaluator._facts = evaluator.factsOf(expression.type);
            evaluator.storeCompoundAt(expression, target);
        }

        public void storageCatAssignment(
            CatAssignExp expression, void* target,
        ) {
            evaluator.runForEffect(expression);
        }

        public void* storageReferenceCall(CallExp expression) {
            return evaluator.refCallAddress(expression);
        }

        public void* storageValueCall(CallExp expression) {
            return evaluator.valueCallAddress(expression);
        }

        public void* storageDelegateWord(void* base, in size_t offset) {
            return cast(ubyte*) base + offset;
        }

        public void* storageArrayLength(
            ArrayLengthExp expression, void* base,
        ) {
            import snakebite.nativelayout: arrayLengthOffset;
            return cast(ubyte*) base + arrayLengthOffset;
        }

        public size_t storageDynamicIndexLength(
            IndexExp expression, void* base,
        ) {
            import snakebite.nativelayout: arrayLengthOffset, loadIntegral;

            return loadIntegral(
                cast(ubyte*) base + arrayLengthOffset,
                size_t.sizeof,
                false,
            );
        }

        public size_t storageStaticIndexLength(IndexExp expression) {
            return cast(size_t) expression.e1.type.isTypeSArray.dim
                .toInteger;
        }

        public void* storageIndexValue(
            IndexExp expression, size_t length,
        ) {
            import snakebite.nativelayout: storeIntegral;

            auto value = evaluator._temporaries.reserveValue(
                size_t.sizeof, size_t.alignof);
            storeIntegral(value, evaluator.indexOf(expression, length),
                size_t.sizeof);
            return value;
        }

        public void storageIndexBounds(
            IndexExp expression, void* index, size_t length,
        ) {
            import snakebite.backends.druntimehooks: DruntimeHook;
            import snakebite.nativelayout: loadIntegral;

            const value = loadIntegral(index, size_t.sizeof, false);
            if (value < length)
                return;

            evaluator.throwArrayBounds(
                DruntimeHook.indexBounds, expression.loc,
                [cast(const(void)*) index,
                    cast(const(void)*) &length],
            );
        }

        public void* storagePointerIndexBase(
            IndexExp expression, void* base,
        ) {
            import snakebite.nativelayout: loadIntegral;

            return cast(void*) loadIntegral(base, size_t.sizeof, false);
        }

        public void* storagePointerIndexValue(IndexExp expression) {
            return storageIndexValue(expression, 0);
        }

        public void* storageDynamicIndex(
            IndexExp expression, void* base, void* index,
        ) {
            import snakebite.nativelayout:
                arrayPointerOffset, loadIntegral;

            const stride = evaluator.factsOf(expression.e1.type.nextOf).size;
            const value = loadIntegral(index, size_t.sizeof, false);
            auto elements = cast(ubyte*) loadIntegral(
                cast(ubyte*) base + arrayPointerOffset,
                size_t.sizeof,
                false,
            );
            return elements + value * stride;
        }

        public void* storageStaticIndex(
            IndexExp expression, void* base, void* index,
        ) {
            import snakebite.nativelayout: loadIntegral;

            const stride = evaluator.factsOf(expression.e1.type.nextOf).size;
            const value = loadIntegral(index, size_t.sizeof, false);
            return cast(ubyte*) base + value * stride;
        }

        public void* storagePointerIndex(
            IndexExp expression, void* pointer, void* index,
        ) {
            import snakebite.nativelayout: loadIntegral;

            const stride = evaluator.factsOf(expression.e1.type.nextOf).size;
            const value = loadIntegral(index, size_t.sizeof, false);
            auto elements = cast(ubyte*) pointer;
            if (elements is null)
                throw new SnakebiteException(
                    text("interpreter cannot index through a null pointer in `",
                        expression.toString, "` at ", value),
                );
            return elements + value * stride;
        }

        public void* storageField(DotVarExp expression) {
            auto field = expression.var.isVarDeclaration;
            if (field is null)
                throw new SnakebiteException(
                    text("interpreter cannot take the address of `",
                        expression.toString,
                        "`: only a struct field is supported"),
                );
            return cast(ubyte*) evaluator.fieldBaseAddress(expression.e1)
                + field.offset;
        }

        // The generic fallback for any expression `StorageResolver.resolve`
        // does not otherwise recognise - any slice (`storageSlice`), and
        // any rvalue with no storage of its own yet, `ArrayLiteralExp`
        // included: dmd's own typesafe variadic packing (`dmd.
        // expressionsem.functionParameters`, issue #334 step 6) slices a
        // fresh `ArrayLiteralExp` of static-array type directly (`T
        // t...`), with no hidden variable declaration of its own the way
        // a named local would have one, so `visit(SliceExp)`'s own
        // whole-static-array-slice case reaches here asking for that
        // literal's own address. Evaluating it here, into a fresh
        // temporary, then handing back that temporary's own address, is
        // what supplies one. `_temporaries.reserveValue`, not `_frames.
        // push` (`valueCallAddress`'s own doc has the same reasoning):
        // `push` hands back a `Frame` whose own destructor pops the
        // reservation the moment that local `Frame` goes out of scope -
        // here, at this very function's own return, before the caller
        // this address is for ever reads it - while `reserveValue`'s
        // storage stays live until the enclosing full expression releases
        // it, the same lifetime a callee reading a typesafe variadic
        // parameter throughout its own body, after nested calls of its
        // own, needs.
        public void* storageValue(Expression expression) {
            const facts = evaluator.factsOf(expression.type);
            auto temporary = evaluator._temporaries.reserveValue(
                facts.size, facts.alignment);
            evaluator.evaluate(expression, expression.type, facts, temporary);
            return temporary;
        }
    }

    private struct SymbolAddressAdapter {
        Evaluator evaluator;

        public void* symbolAddress(SymOffExp expression) {
            if (auto function_ = expression.var.isFuncDeclaration)
                return evaluator.callableAddress(function_, 0);

            if (auto typeInfo = expression.var.isTypeInfoDeclaration)
                return cast(void*) evaluator._runtimeTypes.get(typeInfo.tinfo);

            return evaluator.slotOf(expression, expression.var);
        }

        public void* addSymbolOffset(
            in void* address,
            in long offset,
        ) {
            return cast(void*) (cast(ubyte*) address + offset);
        }
    }

    private void* addressOf(Expression target) {
        import snakebite.frontend.storage: StorageResolver;

        return StorageResolver!(void*, StorageAdapter)(StorageAdapter(this))
            .resolve(target);
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

    private void storeCompoundAt(BinAssignExp expression, void* target) {
        if (expression.isAddAssignExp) return storeAssignExp!("+")(
            expression, target);
        if (expression.isMinAssignExp) return storeAssignExp!("-")(
            expression, target);
        if (expression.isMulAssignExp) return storeAssignExp!("*")(
            expression, target);
        if (expression.isDivAssignExp) return storeAssignExp!("/")(
            expression, target);
        if (expression.isModAssignExp) return storeAssignExp!("%")(
            expression, target);
        if (expression.isAndAssignExp) return storeAssignExp!("&")(
            expression, target);
        if (expression.isOrAssignExp) return storeAssignExp!("|")(
            expression, target);
        if (expression.isXorAssignExp) return storeAssignExp!("^")(
            expression, target);
        if (expression.isShlAssignExp) return storeAssignExp!("<<")(
            expression, target);
        if (expression.isShrAssignExp) return storeAssignExp!(">>")(
            expression, target);
        if (expression.isUshrAssignExp) return storeAssignExp!(">>>")(
            expression, target);
    }

    // The target is looked up once, not once to read and again to write. DMD
    // reads a promoted floating target before its right side; same-width and
    // integral assignments keep the ordinary right-side-first order.
    //
    // `extern(D)`: a string template parameter has no C++ mangling.
    private extern(D) void storeAssignExp(string op)(
        BinAssignExp expression, void* resolvedTarget = null,
    ) {
        import snakebite.frontend.storage: compoundTarget;
        import snakebite.nativevalue: loadFloating, storeFloating;
        import snakebite.nativelayout: loadIntegral, storeIntegral;
        import std.conv: text;

        auto target_ = compoundTarget(expression);
        const operationType = expression.e1.type.toBasetype;
        static if (op == "+" || op == "-" || op == "*" || op == "/"
                || op == "%")
        if (operationType.ty == Tfloat32 || operationType.ty == Tfloat64
                || operationType.ty == Tfloat80) {
            auto target = resolvedTarget;
            if (target is null)
                try {
                    target = addressOf(target_);
                } catch (SnakebiteException) {
                    throw new SnakebiteException(
                        text("interpreter cannot assign to `",
                            expression.e1.toString, "`: ",
                            expression.toString),
                    );
                }

            const targetFacts = factsOf(target_.type);
            const operationFacts = factsOf(expression.e1.type);
            const mixedPromotion = targetFacts.size != operationFacts.size;
            real current;
            if (mixedPromotion)
                current = loadFloating(target, targetFacts.size);
            const step = asFloating(expression.e2);
            if (!mixedPromotion)
                current = loadFloating(target, targetFacts.size);
            real result;
            if (operationType.ty == Tfloat32)
                result = cast(real) mixin(
                    "cast(float) current " ~ op ~ " cast(float) step");
            else if (operationType.ty == Tfloat64)
                result = cast(real) mixin(
                    "cast(double) current " ~ op ~ " cast(double) step");
            else
                result = mixin("current " ~ op ~ " step");

            storeFloating(target, result, targetFacts.size);
            storeFloating(
                _place,
                loadFloating(target, targetFacts.size),
                _facts.size,
            );
            return;
        }

        const targetFacts = factsOf(expression.e1.type);
        if (!targetFacts.isIntegral && expression.e1.type.ty != Tpointer)
            throw new SnakebiteException(
                text("interpreter cannot assign to `",
                    expression.e1.toString, "`: `", expression.toString,
                    "`"),
            );

        auto target = resolvedTarget;
        if (target is null)
            try {
                target = addressOf(expression.e1);
            } catch (SnakebiteException) {
                throw new SnakebiteException(
                    text("interpreter cannot assign to `",
                        expression.e1.toString, "`: `", expression.toString,
                        "`"),
                );
            }

        // A narrow target (`ubyte`, `short`, ...) arrives wrapped in the
        // `CastExp` dmd's `integralPromotions` adds for the operation
        // itself; the field behind it is what is stored to.
        if (auto dot = target_.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field !is null && field.isBitFieldDeclaration !is null) {
                const stepFacts = factsOf(expression.e2.type);
                const step = asIntegral(expression.e2, stepFacts);
                const current = bitfieldValueAtPlace(field, target);
                const result = combine!op(
                    current, step, targetFacts, stepFacts, expression);
                storeBitfieldAt(field, target, result);
                storeIntegral(_place, result, _facts.size);
                return;
            }
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
        if (expression.e1.type.ty == Tpointer) {
            const target = addressOf(expression.e1);
            const current = asPointer(expression.e1);
            const elementSize = factsOf(expression.e1.type.nextOf).size;
            const changed = expression.op == EXP.plusPlus
                ? cast(ubyte*) current + elementSize
                : cast(ubyte*) current - elementSize;

            storeIntegral(_place, cast(size_t) current, _facts.size);
            storeIntegral(cast(void*) target, cast(size_t) changed,
                facts.size);
            return;
        }

        if (!facts.isIntegral)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: `", expression.e1.toString,
                    "` is not an integral lvalue"),
            );

        if (auto dot = expression.e1.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field !is null && field.isBitFieldDeclaration !is null) {
                auto base = fieldBaseAddress(dot.e1);
                const current = bitfieldValueAt(base, field);
                const step = asIntegral(expression.e2);
                const changed = expression.op == EXP.plusPlus
                    ? current + step : current - step;
                storeIntegral(_place, current, _facts.size);
                storeBitfieldAt(field,
                    cast(ubyte*) base + field.offset, changed);
                return;
            }
        }

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

    protected override void visitComparison(
        CmpExp expression, in ComparisonPlan plan,
    ) {
        import std.conv: text;

        with (EXP) switch (expression.op) {
            case lessThan: return storeCmpExp!"<"(expression, plan);
            case lessOrEqual: return storeCmpExp!"<="(expression, plan);
            case greaterThan: return storeCmpExp!">"(expression, plan);
            case greaterOrEqual: return storeCmpExp!">="(expression, plan);
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
    private extern(D) void storeCmpExp(string op)(
        CmpExp expression, in ComparisonPlan plan,
    ) {
        import snakebite.nativelayout: storeIntegral;

        with (ComparisonPlan.Kind) final switch (plan.kind) {
            case floating: {
                const a = asFloating(expression.e1);
                const b = asFloating(expression.e2);
                const answer = mixin("a " ~ op ~ " b");
                storeIntegral(_place, answer ? 1 : 0, _facts.size);
                return;
            }
            case reference: {
                const a = cast(size_t) asReference(expression.e1, plan.facts);
                const b = cast(size_t) asReference(expression.e2, plan.facts);
                const answer = mixin("a " ~ op ~ " b");
                storeIntegral(_place, answer ? 1 : 0, _facts.size);
                return;
            }
            case integral: {
                const a = asIntegral(expression.e1, plan.facts);
                const b = asIntegral(expression.e2, plan.facts);
                const answer = plan.facts.isUnsigned
                    ? mixin("cast(ulong) a " ~ op ~ " cast(ulong) b")
                    : mixin("a " ~ op ~ " b");
                storeIntegral(_place, answer ? 1 : 0, _facts.size);
                return;
            }
        }
    }

    override void visit(LogicalExp expression) {
        import snakebite.nativelayout: storeIntegral;

        const left = truthOf(expression.e1);

        // D allows a `void` right side in a statement context, making
        // the whole expression `void`: dmd guards a conditionally
        // constructed temporary's destructor call with the condition
        // that selected it (`__cond6 && __slT4.~this()`), so the right
        // side runs for its effect and there is no value to produce.
        if (expression.e2.type.ty == Tvoid) {
            const runsRight = expression.op == EXP.andAnd ? left : !left;
            if (runsRight)
                runForEffect(expression.e2);
            return;
        }

        const answer = expression.op == EXP.andAnd
            ? left && truthOf(expression.e2)
            : left || truthOf(expression.e2);

        storeIntegral(_place, answer ? 1 : 0, _facts.size);
    }

    // dmd's usual arithmetic conversions give both operands the same type.
    // Integral equality can therefore compare the common representation,
    // while floating equality must compare values: positive and negative
    // zero have different representations but compare equal in D.
    protected override void visitUnloweredEqual(EqualExp expression) {
        import core.stdc.string: memcmp;
        import snakebite.nativelayout: storeIntegral;
        import dmd.typesem: toBasetype;
        import std.conv: text;

        if (expression.op != EXP.equal && expression.op != EXP.notEqual)
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        // DMD's `Type.nextOf` is not const-correct, so this cannot be const.
        auto type = expression.e1.type.toBasetype;
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

        if (type.ty == Tdelegate) {
            import snakebite.nativelayout:
                delegateContextOffset, delegateFunctionOffset,
                delegateValueSize, loadIntegral;

            align(size_t.sizeof) ubyte[delegateValueSize] left = void;
            align(size_t.sizeof) ubyte[delegateValueSize] right = void;
            const facts = factsOf(type);
            evaluate(expression.e1, type, facts, left.ptr);
            evaluate(expression.e2, type, facts, right.ptr);
            const sameContext = loadIntegral(
                left.ptr + delegateContextOffset,
                size_t.sizeof,
                false,
            ) == loadIntegral(
                right.ptr + delegateContextOffset,
                size_t.sizeof,
                false,
            );
            const sameFunction = loadIntegral(
                left.ptr + delegateFunctionOffset,
                size_t.sizeof,
                false,
            ) == loadIntegral(
                right.ptr + delegateFunctionOffset,
                size_t.sizeof,
                false,
            );
            const equal = sameContext && sameFunction;
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

    // The shared identity plan has already resolved DMD's native operation.
    protected override void visitIdentity(
        IdentityExp expression, in IdentityPlan plan,
    ) {
        import core.stdc.string: memcmp;
        import snakebite.nativelayout: arrayValueSize, storeIntegral;
        import std.conv: text;

        if (expression.op != EXP.identity && expression.op != EXP.notIdentity)
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        if (plan.skipCompare) {
            const answer = expression.op == EXP.identity;
            storeIntegral(_place, answer ? 1 : 0, _facts.size);
            return;
        }

        const facts = factsOf(expression.e1.type);
        const mark = _frames.mark;
        scope (exit)
            _frames.release(mark);
        auto left = _frames.reserve(plan.staticArray
            ? arrayValueSize : facts.size, facts.alignment);
        auto right = _frames.reserve(plan.staticArray
            ? arrayValueSize : facts.size, facts.alignment);
        if (plan.staticArray) {
            import snakebite.nativelayout:
                arrayLengthOffset, arrayPointerOffset, arrayValueSize,
                storeIntegral;
            void* leftAddress;
            if (plan.leftStorage) {
                leftAddress = _frames.reserve(facts.size, facts.alignment);
                evaluate(expression.e1, expression.e1.type, facts,
                    leftAddress);
            } else
                leftAddress = addressOf(expression.e1);
            void* rightAddress;
            if (plan.rightStorage) {
                rightAddress = _frames.reserve(facts.size, facts.alignment);
                evaluate(expression.e2, expression.e2.type, facts,
                    rightAddress);
            } else
                rightAddress = addressOf(expression.e2);
            storeIntegral(left + arrayLengthOffset,
                plan.length, size_t.sizeof);
            storeIntegral(right + arrayLengthOffset,
                plan.length, size_t.sizeof);
            *cast(void**)(left + arrayPointerOffset) = leftAddress;
            *cast(void**)(right + arrayPointerOffset) = rightAddress;
        } else {
            evaluate(expression.e1, expression.e1.type, facts, left);
            evaluate(expression.e2, expression.e2.type, facts, right);
        }
        const equal = plan.width == 0
            || memcmp(left, right, plan.width) == 0;
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
        import snakebite.nativelayout: storeIntegral;

        if (expression.type.ty == Tpointer) {
            const pointer = cast(ubyte*) asPointer(expression.e1);
            const offset = asIntegral(expression.e2);
            storeIntegral(_place, cast(size_t)(pointer - offset), _facts.size);
            return;
        }

        if (expression.e1.type.ty == Tpointer
                && expression.e2.type.ty == Tpointer) {
            const left = cast(ubyte*) asPointer(expression.e1);
            const right = cast(ubyte*) asPointer(expression.e2);
            const difference = left - right;
            storeIntegral(_place, cast(ulong) difference, _facts.size);
            return;
        }

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

        auto type = expression.type.toBasetype;
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

    // `snakebite.backends.casts.classify` has already turned the source
    // and destination types into a `Kind`; this is the adapter that
    // executes each one, with no type inspection of its own beyond the
    // pre-check below that classify does not see: `cast(void) e`, whose
    // meaning is "keep `e`'s effects, produce no value".
    protected override void visitUnloweredCast(CastExp expression) {
        import snakebite.backends.casts: classify, CastPlan;
        import snakebite.nativevalue:
            complexTruth, floatingToBool, floatingToIntegral,
            integralToFloating, loadComplexIm, loadComplexRe, loadFloating,
            storeComplex, storeFloating;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, delegateContextOffset,
            loadIntegral, storeIntegral;
        import std.conv: text;

        auto sourceType = expression.e1.type;

        // `cast(void) e` discards the value but keeps e's effects. DMD
        // emits this around compiler-generated calls whose return value is
        // intentionally ignored, including associative-array iteration.
        if (_type.ty == Tvoid) {
            runForEffect(expression.e1);
            return;
        }

        // `.im` on a `complex` value is dmd's own `e.castTo(sc,
        // timaginaryN)` (`typesem.d`'s `Id.im` case for `Tcomplex*`)
        // with the resulting node's `.type` then overwritten straight to
        // the matching `Tfloat*` - a same-size reinterpret with no
        // `CastExp` of its own, done directly on the expression `castTo`
        // already built. `.type` (`_type` here) is that overwritten
        // field; `.to` still names the cast `castTo` actually performed,
        // so it is the one `classify` has to see to tell that apart from
        // `.re`, whose `.to` and `.type` agree.
        auto destType = expression.to !is null ? expression.to : _type;
        const plan = classify(expression.e1, destType);

        final switch (plan.kind) with (CastPlan.Kind) {
        case copy:
            evaluate(expression.e1, sourceType, factsOf(sourceType), _place);
            return;

        case classReference: {
            evaluate(expression.e1, sourceType, factsOf(sourceType), _place);
            auto reference = cast(ubyte**) _place;
            if (*reference !is null)
                *reference += plan.referenceOffset;
            return;
        }

        case zero: {
            import core.stdc.string: memset;

            if (expression.e1.isNullExp is null)
                runForEffect(expression.e1);
            memset(_place, 0, _facts.size);
            return;
        }

        // `cast(bool) someComplex`: true when either component is
        // nonzero - the same rule `TypeFacts.Truth` gives `if
        // (someComplex)`.
        case complexToBool: {
            align(real.alignof) ubyte[2 * real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeIntegral(
                _place,
                complexTruth(buffer.ptr, plan.sourceFacts.size),
                _facts.size,
            );
            return;
        }

        // `cast(double) someComplex`/`someComplex.re`: the real
        // component alone, converted to the destination's own width.
        case complexToReal: {
            align(real.alignof) ubyte[2 * real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeFloating(
                _place,
                loadComplexRe(buffer.ptr, plan.sourceFacts.size),
                _facts.size,
            );
            return;
        }

        // `someComplex.im`: the imaginary component alone (`classify`'s
        // own doc comment on `destType`/`.to` above is what routes this
        // cast here instead of `complexToReal`).
        case complexToImaginary: {
            align(real.alignof) ubyte[2 * real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeFloating(
                _place,
                loadComplexIm(buffer.ptr, plan.sourceFacts.size),
                _facts.size,
            );
            return;
        }

        // `cast(int) someComplex`: the real component, converted the
        // same way `floatToIntegral` converts a plain real operand - the
        // component's own bytes sit at `buffer`'s first half already, so
        // `floatingToIntegral` reading `sourceFacts.size / 2` bytes from
        // there needs nothing else.
        case complexToIntegral: {
            align(real.alignof) ubyte[2 * real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            floatingToIntegral(
                _place, buffer.ptr, _facts.size, plan.sourceFacts.size / 2,
                _facts.isUnsigned,
            );
            return;
        }

        // `cast(cfloat) someCreal`: both components, independently
        // rounded to the destination's own width.
        case complexWidth: {
            align(real.alignof) ubyte[2 * real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeComplex(
                _place,
                loadComplexRe(buffer.ptr, plan.sourceFacts.size),
                loadComplexIm(buffer.ptr, plan.sourceFacts.size),
                _facts.size,
            );
            return;
        }

        // `cast(cdouble) someDouble`: the real axis carries the value,
        // the imaginary one is zero.
        case realToComplex: {
            align(real.alignof) ubyte[real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeComplex(
                _place, loadFloating(buffer.ptr, plan.sourceFacts.size),
                0.0L, _facts.size,
            );
            return;
        }

        // `cast(cdouble) someInt`: as `realToComplex`, from an integral
        // operand.
        case integralToComplex: {
            align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            const value = loadIntegral(
                buffer.ptr, plan.sourceFacts.size, !plan.sourceFacts.isUnsigned);
            const re = plan.sourceFacts.isUnsigned
                ? cast(real) cast(ulong) value : cast(real) value;
            storeComplex(_place, re, 0.0L, _facts.size);
            return;
        }

        // `cast(cdouble) someIdouble`: the reverse of `complexToImaginary`
        // - the imaginary axis carries the value, the real one is zero.
        case imaginaryToComplex: {
            align(real.alignof) ubyte[real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeComplex(
                _place, 0.0L, loadFloating(buffer.ptr, plan.sourceFacts.size),
                _facts.size,
            );
            return;
        }

        // An explicit pointer-to-integral cast preserves the native
        // address bits.
        case pointerToIntegral:
            storeIntegral(
                _place, cast(size_t) asPointer(expression.e1), _facts.size);
            return;

        // `cast(void*) someDelegate`: the same context word `dg.ptr`
        // itself reads (`visitDelegateWord` below).
        case delegateToPointer:
            visitDelegateWord(expression.e1, delegateContextOffset);
            return;

        case sarrayToSlice: {
            auto bytes = cast(ubyte*) _place;
            storeIntegral(
                bytes + arrayLengthOffset, plan.staticLength, size_t.sizeof);
            *cast(void**) (bytes + arrayPointerOffset) =
                addressOf(expression.e1);
            return;
        }

        case sarrayToPointer:
            storeIntegral(
                _place, cast(size_t) addressOf(expression.e1), _facts.size);
            return;

        // `arr.ptr` is not a real member: `.ptr` is one of the two
        // properties dmd recognises directly on a dynamic array, and its
        // semantic pass lowers a read of it into exactly this cast, over
        // the array itself rather than a `.ptr` access node - reading the
        // array's own pointer word is what this cast means, not an
        // arbitrary reinterpretation of the array's bytes as a `T*`.
        // `_d_arrayappendcTX_`, on the `~=` lowering's own chain, reads
        // `px.ptr` this way to ask the GC what it already knows about the
        // block backing the array being grown.
        case sliceToPointer: {
            const bytes = cast(ubyte*) addressOf(expression.e1);
            const value = *cast(void**) (bytes + arrayPointerOffset);
            storeIntegral(_place, cast(size_t) value, _facts.size);
            return;
        }

        // D reinterprets the same bytes at the new element width, so the
        // byte count - not the element count - is what has to stay the
        // same across the cast. `newLength` is truncated, the same
        // truncation `object.d`'s own `T[] to U[]` cast does, rather than
        // refused on a remainder: a remainder means the source array's
        // byte length is not a whole number of destination elements,
        // which is druntime's call to make, not this interpreter's.
        case reinterpretSlice: {
            const value = evaluateArray(expression.e1, plan.sourceFacts);
            const newLength = value.length * plan.sourceFacts.elementSize
                / plan.destFacts.elementSize;

            auto bytes = cast(ubyte*) _place;
            storeIntegral(bytes + arrayLengthOffset, newLength, size_t.sizeof);
            *cast(const(void)**) (bytes + arrayPointerOffset) =
                value.elements;
            return;
        }

        // dmd classifies `bool` as `integral | unsigned` (`mtype.d`), so
        // this has to be its own kind rather than an ordinary
        // integral-to-integral narrowing: D specifies `cast(bool) x` as
        // `x != 0`, not "keep the low byte" - `cast(bool) 256` is `true`
        // in D, not the `false` a truncation would store. `classify` also
        // reaches this kind for a pointer operand (`cast(bool) somePtr`),
        // which `asIntegral` itself refuses (`Type.isIntegral` is false
        // for `Tpointer`), so this reads the operand's raw bytes directly
        // instead - the same bytes `asPointer` would read for a pointer,
        // or `asIntegral` for an integral, just without either one's own
        // gate on the operand's type.
        case toBool: {
            align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
            evaluate(expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            const value = loadIntegral(buffer.ptr, plan.sourceFacts.size, false);
            storeIntegral(_place, value != 0, _facts.size);
            return;
        }

        // `asIntegral` already sign- or zero-extends the operand to 64
        // bits per its own signedness, so storing the destination's low
        // bytes of that value is correct whichever way the width
        // changes - the same widen-then-truncate the `combine`d binary
        // operators already rely on, just with the two types differing
        // instead of matching.
        case narrow:
        case widenSigned:
        case widenUnsigned:
            storeIntegral(
                _place,
                asIntegral(expression.e1, plan.sourceFacts),
                _facts.size,
            );
            return;

        // The shared operation reads the source's native width and
        // signedness, then rounds once at the destination width.
        case integralToFloat: {
            align(real.alignof) ubyte[real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            integralToFloating(
                _place,
                buffer.ptr,
                plan.destFacts.size,
                plan.sourceFacts.size,
                plan.sourceFacts.isUnsigned,
            );
            return;
        }

        // A floating-to-floating cast rounds the operand's own value to
        // the destination's own precision - `asFloating` already widens
        // any of the three to `real` without loss, so narrowing that back
        // to the destination's width is the one rounding the host's own
        // `cast(float)`/`cast(double)`/`cast(real)` performs.
        // Sized rather than dispatched on `_type.ty`/`sourceType.ty`, so
        // the one kind also carries an imaginary-to-imaginary width
        // change: an imaginary value's native layout is a single
        // `float`/`double`/`real`, the same shape a plain real one is,
        // just at a different offset than `sourceType.ty`'s own family
        // would suggest were this dispatched by type instead of size.
        case floatWidth: {
            align(real.alignof) ubyte[real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            storeFloating(
                _place, loadFloating(buffer.ptr, plan.sourceFacts.size),
                _facts.size,
            );
            return;
        }

        // A pointer reinterpreted as a dynamic array's own
        // `{length, ptr}` header.
        case pointerToArray:
        case unsupported:
            throw new SnakebiteException(
                text("interpreter cannot evaluate a `", expression.op,
                    "` expression: `", expression.toString, "`"),
            );

        case floatToIntegral: {
            align(real.alignof) ubyte[real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            floatingToIntegral(
                _place,
                buffer.ptr,
                plan.destFacts.size,
                plan.sourceFacts.size,
                plan.destFacts.isUnsigned,
            );
            return;
        }

        case floatToBool: {
            align(real.alignof) ubyte[real.sizeof] buffer = void;
            evaluate(
                expression.e1, sourceType, plan.sourceFacts, buffer.ptr);
            floatingToBool(_place, buffer.ptr, plan.sourceFacts.size);
            return;
        }
        }
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
    // so a plain function pointer here has no context word to carry.
    override void visit(SymOffExp expression) {
        import snakebite.nativelayout: storeIntegral;

        import snakebite.frontend.storage: SymbolAddressResolver;

        const address = SymbolAddressResolver!(void*, SymbolAddressAdapter)(
            SymbolAddressAdapter(this),
        ).resolve(expression);
        storeIntegral(_place, cast(size_t) address, _facts.size);
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
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        auto field = expression.var.isVarDeclaration;
        if (field is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only a field read is supported"),
            );

        if (field.isBitFieldDeclaration !is null) {
            storeIntegral(_place,
                bitfieldValue(expression, field),
                _facts.size);
            return;
        }

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

    private long bitfieldValue(DotVarExp expression, VarDeclaration field) {
        return bitfieldValueAt(fieldBaseAddress(expression.e1), field);
    }

    // The storage is read at the field's own width, not at the width of
    // the expression reading it: a compound assignment promotes the
    // operation to `int` while a `ubyte` field still has one byte of
    // storage.
    private long bitfieldValueAt(void* base, VarDeclaration field) {
        return bitfieldValueAtPlace(field,
            cast(ubyte*) base + field.offset);
    }

    private long bitfieldValueAtPlace(
        VarDeclaration field, void* place,
    ) {
        import snakebite.nativelayout: loadIntegral;
        const bits = field.isBitFieldDeclaration;
        const facts = factsOf(field.type);
        const raw = loadIntegral(
            place, facts.size, false);
        const mask = ulong.max >> (64 - bits.fieldWidth);
        auto value = (raw >> bits.bitOffset) & mask;
        if (!facts.isUnsigned && bits.fieldWidth < 64
                && (value & (1UL << (bits.fieldWidth - 1))))
            value |= ulong.max << bits.fieldWidth;
        return cast(long) value;
    }

    private void storeBitfield(
        DotVarExp expression, VarDeclaration field, long value,
    ) {
        const bits = field.isBitFieldDeclaration;
        auto place = cast(ubyte*) fieldBaseAddress(expression.e1) + field.offset;
        storeBitfieldAt(field, place, value);
    }

    private void storeBitfieldAt(
        VarDeclaration field, void* place, long value,
    ) {
        import snakebite.nativelayout: loadIntegral, storeIntegral;
        const bits = field.isBitFieldDeclaration;
        const mask = (ulong.max >> (64 - bits.fieldWidth)) << bits.bitOffset;
        auto storage = loadIntegral(place, factsOf(field.type).size, false);
        storage = (storage & ~mask)
            | ((cast(ulong) value << bits.bitOffset) & mask);
        storeIntegral(place, storage, factsOf(field.type).size);
    }

    override void visit(TypeidExp expression) {
        import dmd.dtemplate: isExpression, isType;
        import snakebite.nativelayout: storeIntegral;
        import std.conv: text;

        if (auto value = isExpression(expression.obj)) {
            auto address = classReferenceOf(value);
            const indirections = 2
                + (value.type.isTypeClass.sym.isInterfaceDeclaration !is null);
            foreach (i; 0 .. indirections)
                address = *cast(void**) address;
            storeIntegral(_place, cast(size_t) address, _facts.size);
            return;
        }

        auto type = isType(expression.obj);
        if (type is null || type.vtinfo is null)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only `typeid` of a resolved type is supported"),
            );

        auto info = _runtimeTypes.get(type);
        if (info is null)
            throw new SnakebiteException(
                text("interpreter cannot resolve `", expression.toString,
                    "`: its type information is not in this process"),
            );
        storeIntegral(_place, cast(size_t) cast(void*) info, _facts.size);
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
        import snakebite.backends.exceptions:
            AssertInvariantPlan, assertInvariantPlanOf;

        if (expression.type !is null && expression.type.ty == Tnoreturn)
            throw new SnakebiteException(
                text("interpreter cannot execute the halt `",
                    expression.toString, "`"),
            );

        // `assertInvariantPlanOf` answers the same question dmd's own
        // glue layer (`e2ir.d`'s `visitAssert`) asks of `e1`'s type alone,
        // gated the same way on `useInvariants`: every other assert - the
        // overwhelming majority - takes the plain path unchanged below.
        auto plan = assertInvariantPlanOf(expression);
        if (plan.kind == AssertInvariantPlan.Kind.none) {
            if (!truthOf(expression.e1))
                throwAssertFailure(expression);
            return;
        }

        // `e1` is a class reference or a struct pointer here - a single
        // pointer-sized value that is its own truth test
        // (`TypeFacts.Truth.of`'s own answer for either shape) - evaluated
        // once and reused for both the condition check and the invariant
        // call below, the same "evaluate once, reuse the same compiler
        // temporary for both" dmd's own glue layer does with its one
        // temporary. A null reference fails the condition here, before
        // ever reaching the invariant call - reaching it first would
        // crash on druntime's own `_d_invariant`'s own null check instead
        // of throwing this guest-visible `AssertError`.
        import snakebite.nativelayout: loadIntegral;

        align(size_t.sizeof) ubyte[size_t.sizeof] buffer = void;
        evaluate(expression.e1, expression.e1.type, buffer.ptr);
        auto object =
            cast(void*) loadIntegral(buffer.ptr, size_t.sizeof, false);
        if (object is null) {
            throwAssertFailure(expression);
            return;
        }

        if (plan.kind == AssertInvariantPlan.Kind.class_)
            callClassInvariant(object);
        else
            callStructInvariant(plan.structInvariant, object);
    }

    // What a failed `assert` throws to the guest, shared by every path
    // through `visit(AssertExp)` above.
    private void throwAssertFailure(AssertExp expression) {
        import core.exception: AssertError;
        import snakebite.backends.exceptions: assertFailureOf;

        // What D does here is throw an `AssertError` the guest can catch.
        // Keep it inside an interpreter-owned wrapper so a guest catch does
        // not also catch the interpreter's own unsupported-node failures.
        const failure = assertFailureOf(expression);
        throw new GuestException(
            new AssertError(failure.message, failure.file, failure.line));
    }

    // A class reference's own invariant is druntime's job, not this
    // project's: `_d_invariant` (`rt.invariant_`) walks every base class's
    // own invariant in turn, resolved purely by its linker symbol through
    // the FFI barrier - the same `rawPlanOf`/`callPlan` shape
    // `visitUnloweredCatDcharAssign` already uses for a druntime hook with
    // no `FuncDeclaration` of its own - and called here with the object
    // reference as its one argument.
    private void callClassInvariant(void* objectPointer) {
        import snakebite.backends.druntimehooks: planOf, specOf;
        import std.conv: text;

        countForeignNameLookup;
        auto plan = planOf(*_plans, DruntimeHook.classInvariant);
        if (plan is null)
            throw new SnakebiteException(
                text("interpreter cannot resolve the symbol `",
                    specOf(DruntimeHook.classInvariant).name,
                    "`: it is not in this process"),
            );

        const(void*)[1] arguments = [cast(const(void)*) &objectPointer];
        callPlan(plan, null, arguments[]);
    }

    // A struct pointer's own invariant is a plain guest function call to
    // its own merged `inv`, the same shape `dmd.func.FuncDeclaration.
    // addInvariant` already builds for a member function's own entry/exit
    // check (`CallExp(DotVarExp(ThisExp, inv))`, see `unresolvedCalleeOf`)
    // - but `assert(&s)` never gives this backend that `CallExp` to walk,
    // so this builds `inv`'s own frame directly instead, with
    // `thisPointer` filling the one hidden `this` slot it declares.
    private void callStructInvariant(
        FuncDeclaration inv, void* thisPointer,
    ) {
        import snakebite.nativelayout: storeIntegral;

        auto layout = layoutOf(inv);
        auto frame = _frames.push(layout.size, layout.alignment);
        storeIntegral(
            frame.base + layout.hiddenThis.parameter.offset,
            cast(size_t) thisPointer, size_t.sizeof,
        );
        _temporaries.withNestedCall({
            executeRaw(inv, null, frame.base, layout, null, null, 0);
        });
    }

    protected override void visitThrowExp(ThrowExp expression) {
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

        throw new GuestException(guest);
    }

    override void visit(ArrayLengthExp expression) {
        import snakebite.nativelayout: storeIntegral;

        auto array = expression.e1;
        const value = evaluateArray(array, factsOf(array.type));

        storeIntegral(_place, value.length, _facts.size);
    }

    override void visit(IndexExp expression) {
        import core.stdc.string: memcpy;
        const element = addressOf(expression);
        memcpy(_place, element, _facts.size);
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
        } else if (sourceType.ty == Tsarray) {
            // A static array's elements are the array's own bytes, not a
            // separately allocated block - `addressOf` already finds that
            // storage the same way any other lvalue's address is found,
            // and the length is part of the type itself rather than
            // something to read back from a run-time value.
            base = cast(ubyte*) addressOf(array);
            const elementSize = factsOf(sourceType.nextOf).size;
            sourceLength = factsOf(sourceType).size / elementSize;
            knownLength = true;
        } else
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: only slicing a pointer, a dynamic array or a ",
                    "static array is supported"),
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

        if (knownLength) {
            if (lo < 0 || hi < lo || cast(size_t) hi > sourceLength) {
                import snakebite.backends.druntimehooks: DruntimeHook;

                const lower = cast(size_t) lo;
                const upper = cast(size_t) hi;
                throwArrayBounds(
                    DruntimeHook.sliceBounds, expression.loc,
                    [cast(const(void)*) &lower, cast(const(void)*) &upper,
                        cast(const(void)*) &sourceLength],
                );
            }
        } else if (lo < 0 || hi < lo)
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
    //
    // The shared LoweringVisitor routes array literals without a lowering
    // here. Lowered literals use the allocation result as their element
    // storage and are completed below.
    protected override void visitUnloweredArrayLiteral(
            ArrayLiteralExp expression) {
        import snakebite.nativelayout: isStoredLiteral;

        if (isStoredLiteral(expression)) {
            _nativeData.write(_type, _facts, expression, _place);
            return;
        }
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
                    expression[i], elementType, elementFacts,
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
                    expression[i], elementType, elementFacts,
                    cast(ubyte*) block.ptr + i * elementFacts.size);
            elements = cast(ubyte*) block.ptr;
        }

        auto bytes = cast(ubyte*) _place;
        storeIntegral(bytes + arrayLengthOffset, length, size_t.sizeof);
        *cast(ubyte**) (bytes + arrayPointerOffset) = elements;
    }

    private struct ArrayLiteralDestination {
        void* place;
        Type type;
        TypeFacts facts;
        size_t mark;
    }

    private ArrayLiteralDestination[] _arrayLiteralDestinations;

    protected override void prepareArrayLiteral(ArrayLiteralExp expression) {
        auto destination = ArrayLiteralDestination(
            _place, _type, _facts, _frames.mark);
        const facts = factsOf(expression.lowering.type);
        auto place = _frames.reserve(facts.size, facts.alignment);
        _arrayLiteralDestinations ~= destination;
        _place = place;
        _type = expression.lowering.type;
        _facts = facts;
    }

    protected override void restoreArrayLiteral() {
        auto destination = _arrayLiteralDestinations[$ - 1];
        _arrayLiteralDestinations.length--;
        _place = destination.place;
        _type = destination.type;
        _facts = destination.facts;
        _frames.release(destination.mark);
    }

    protected override void storeArrayLiteralElement(
        Expression element, Type elementType, in TypeFacts facts,
        in size_t byteOffset,
    ) {
        auto elements = *cast(ubyte**) _place;
        evaluate(element, elementType, facts, elements + byteOffset);
    }

    protected override void storeArrayLiteralCount(
        in size_t count, in size_t byteOffset,
    ) {
        import snakebite.nativelayout: storeIntegral;

        auto destination = _arrayLiteralDestinations[$ - 1];
        storeIntegral(cast(ubyte*) destination.place + byteOffset,
            count, size_t.sizeof);
    }

    protected override void storeArrayLiteralPointer(in size_t byteOffset) {
        auto destination = _arrayLiteralDestinations[$ - 1];
        *cast(void**) (cast(ubyte*) destination.place + byteOffset)
            = *cast(void**) _place;
    }

    protected override void copyArrayLiteralStorage(in size_t width) {
        import core.stdc.string: memcpy;

        auto destination = _arrayLiteralDestinations[$ - 1];
        memcpy(destination.place, *cast(void**) _place, width);
    }

    private struct NewDestination {
        void* place;
        size_t mark;
    }

    private NewDestination[] _newDestinations;

    protected override void prepareNew(NewExp expression) {
        if (expression.placement !is null)
            throw new SnakebiteException(
                text("interpreter cannot allocate `", expression.toString,
                    "` with placement"),
            );

        // Keeps pointed-to storage mutable during destination restoration.
        auto destination = NewDestination(_place, _frames.mark);
        auto place = _frames.reserve(_facts.size, _facts.alignment);
        _newDestinations ~= destination;
        _place = place;
    }

    protected override void restoreNew() {
        auto destination = _newDestinations[$ - 1];
        _newDestinations.length--;
        _place = destination.place;
        _frames.release(destination.mark);
    }

    protected override void visitLoweredNew(NewExp expression) {
        import dmd.astenums: Tpointer;
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: loadIntegral;

        auto structType = expression.newtype.isTypeStruct;
        if (expression.type.ty == Tclass || structType !is null) {
            auto object = cast(ubyte*) loadIntegral(
                _place, size_t.sizeof, false);
            if (object is null)
                throw new SnakebiteException(
                    text("interpreter cannot allocate `", expression.toString,
                        "`: druntime returned null"),
                );

            finishNew(expression, object);
        } else if (expression.type.ty == Tpointer
                && expression.arguments !is null
                && expression.arguments.length != 0) {
            if (expression.arguments.length != 1)
                throw new SnakebiteException(
                    text("interpreter cannot allocate `",
                        expression.toString, "`: expected one initializer"),
                );
            evaluate((*expression.arguments)[0], expression.newtype,
                factsOf(expression.newtype),
                cast(void*) loadIntegral(_place, size_t.sizeof, false));
        }
        memcpy(_newDestinations[$ - 1].place, _place, _facts.size);
    }

    protected override void visitUnloweredNew(NewExp expression) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: storeIntegral;

        auto classType = expression.newtype.isTypeClass;
        if (!expression.onstack || classType is null
                || expression.placement !is null || expression.thisexp !is null)
            return visit(cast(Expression) expression);

        auto declaration = classType.sym;
        auto runtime = classRuntimeInfo(declaration);
        const alignment = declaration.alignsize == 0
            ? 1 : declaration.alignsize;
        auto object = _frames.reserve(declaration.structsize, alignment);
        memcpy(object, runtime.m_init.ptr, runtime.m_init.length);
        finishNew(expression, object);
        storeIntegral(_place, cast(size_t) object, _facts.size);
    }

    private void finishNew(NewExp expression, ubyte* object) {
        import snakebite.backends.aggregateinit:
            InitStep, planClassContext, planPositionalFields;

        auto classType = expression.newtype.isTypeClass;
        if (classType !is null) {
            // A nested class's `vthis` sits inside the allocation at the
            // same native offset a value of that class type would use -
            // filled here, once, ahead of the constructor call, the same
            // order the struct branch below fills its own `vthis`.
            foreach (step; planClassContext(expression).steps)
                applyStep(step, object);

            if (expression.member !is null)
                constructAggregate(expression, object);
            return;
        }

        auto declaration = expression.newtype.isTypeStruct.sym;
        auto plan = planPositionalFields(declaration,
            expression.member is null ? expression.arguments : null);

        foreach (step; plan.steps)
            if (step.kind == InitStep.Kind.vthis)
                applyStep(step, object);

        if (expression.member !is null) {
            constructAggregate(expression, object);
            return;
        }

        foreach (step; plan.steps)
            if (step.kind != InitStep.Kind.vthis)
                applyStep(step, object);
    }

    override void visit(DeleteExp expression) {
        import snakebite.druntime.classfinalizer: _d_callfinalizer;

        if (expression.e1.type.ty != Tclass)
            throw new SnakebiteException(
                text("interpreter cannot delete `", expression.e1.toString,
                    "`: it is not a class reference"),
            );

        auto object = classReferenceOf(expression.e1);
        _d_callfinalizer(object);
    }

    // Parsed guest classes have no emitted native ClassInfo. `Shared`
    // builds the native TypeInfo_Class metadata druntime needs for
    // allocation and classinfo, once per program.
    private TypeInfo_Class classRuntimeInfo(ClassDeclaration declaration) {
        return _shared.classRuntimeInfo(declaration);
    }

    // `Shared.callableAddress` needs no per-thread state (the vtable slot
    // it fills, like the guest method's own callability, does not depend
    // on which thread asks - see `Shared.callableAddress`'s own doc), so
    // this evaluator only forwards to it. `visit(FuncExp)`,
    // `storeDelegateValue`, `Shared.constantSymbolAddress` and
    // `SymOffExp`'s own resolver all go through the same forward, one
    // answer for every caller that turns a guest function into a value
    // host code, or this evaluator's own `calleeOf`, can call.
    extern(D) private void* callableAddress(
        FuncDeclaration method, ptrdiff_t adjustment,
    ) {
        return _shared.callableAddress(method, adjustment);
    }

    // The guest declaration `info` was generated for, or `null` for a
    // native class's own linked `TypeInfo_Class`.
    private ClassDeclaration* declarationOf(const TypeInfo_Class info) {
        return _shared.declarationOf.find(cast(const(void)*) info);
    }

    // A class and a struct constructor call bind `object` to the hidden
    // `this` the same way: dmd gives both an ordinary `vthis` parameter
    // slot in their own `FrameLayout`, so nothing here needs to know
    // which aggregate kind `expression.newtype` names.
    private void constructAggregate(NewExp expression, ubyte* object) {
        auto constructor = expression.member;
        auto layout = layoutOf(constructor);
        auto frame = _frames.push(layout.size, layout.alignment);

        import snakebite.nativelayout: storeIntegral;

        // `layout.hiddenThis.variable`, not `constructor.vthis`: a
        // bodyless constructor - `extern(C++)`, bound to a host library -
        // never gets a real `vthis` (`hasHiddenThis`'s own doc), and
        // `layoutOf` already stands a fabricated one in for it whenever
        // it did reserve a `this` slot (`FrameLayout.of`'s own doc).
        if (layout.hiddenThis.variable is null)
            throw new SnakebiteException(
                text("interpreter cannot call constructor `",
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

        executeCall(constructor, null, frame.base, layout);
    }

    private void bindArguments(
        FuncDeclaration function_,
        Expressions* arguments,
        in Loc loc,
        ubyte* frameBase,
        const(FrameLayout)* layout,
        in bool allowExtra = false,
    ) {
        _bindArguments(typeFunctionOf(function_), arguments, loc,
            frameBase, layout, allowExtra);
    }

    private void _bindArguments(
        TypeFunction type, Expressions* arguments, in Loc loc,
        ubyte* frameBase, const(FrameLayout)* layout,
        in bool allowExtra = false,
    ) {
        import snakebite.backends.calls: arityMismatches;
        import std.conv: text;

        auto parameterList = type.parameterList;
        if (arityMismatches(parameterList, arguments, allowExtra))
            throw new SnakebiteException(
                text("interpreter: `", type.toString, "` expects ",
                    parameterList.length, " argument(s), got ",
                    arguments is null ? 0 : arguments.length),
            );


        auto preparation = CallAdapter.Arguments.of(
            type, arguments,
        );
        preparation.eachDeclared((i, value) {
            auto argument = value.expression; // Frontend expressions remain mutable.
            const parameter = layout.parameters[i];
            auto slot = frameBase + parameter.offset; // Evaluation writes the slot.

            void* address;

            void* argumentAddress() {
                if (argument.type.ty == Tpointer
                        && argument.type.nextOf.equals(value.parameterType))
                    return asPointer(argument);
                address = addressOf(argument);
                return address;
            }

            void evaluateArgument(void* place) {
                evaluate(
                    argument, value.evaluationType, parameter.facts,
                    place,
                );
            }

            value.store(
                slot,
                &argumentAddress,
                &evaluateArgument,
            );

            if (value.isOut)
                initializeDefault(
                    value.parameterType,
                    factsOf(value.parameterType),
                    cast(ubyte*) address,
                    loc,
                );
        });
    }

    private void initializeDefault(
        Type type,
        in TypeFacts facts,
        ubyte* place,
        in Loc loc,
    ) {
        import core.stdc.string: memcpy;

        const bytes = _nativeData.initialValue(type, loc);
        assert(bytes.length == facts.size);
        memcpy(place, bytes.ptr, bytes.length);
    }

    // Executes one step of an `AggregateInitPlan` (`aggregateinit.d`) at
    // `base`, the aggregate's own bytes directly - `visit(StructLiteralExp)`
    // passes `_place`, `finishNew` the fresh allocation, both already plain
    // `ubyte*` here since the interpreter never distinguishes a value
    // place from a pointer the way the bytecode compiler's frame offsets
    // do.
    private void applyStep(
        InitStep step,
        ubyte* base,
    ) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout: loadIntegral, storeIntegral;

        final switch (step.kind) with (InitStep.Kind) {
        case vthis:
            // A nested class's `vthis` reads `NewExp.thisexp` directly
            // (`step.source`), then adds `sourceAdjustment` if `thisexp`'s
            // static type is a base-class view narrower than the nested
            // class's actual lexical parent - see `classVthisStep`'s own
            // doc (`aggregateinit.d`).
            if (step.source !is null) {
                evaluate(step.source, step.type, step.facts,
                    base + step.offset);
                if (step.sourceAdjustment != 0)
                    storeIntegral(
                        base + step.offset,
                        cast(ulong) (loadIntegral(base + step.offset,
                            step.facts.size, false) + step.sourceAdjustment),
                        step.facts.size,
                    );
                return;
            }

            // `parentFunction` is `null` when the struct's lexical parent
            // is not a function - dmd fact, not itself an error: leaving
            // `vthis` at its `.init` zero here matches the language's own
            // treatment of a `static struct` with no captured context.
            if (step.parentFunction !is null)
                storeIntegral(
                    base + step.offset,
                    cast(size_t) contextOf(step.parentFunction),
                    size_t.sizeof,
                );
            return;

        case value:
            evaluate(step.source, step.type, step.facts, base + step.offset);
            return;

        case bitfield:
            auto value = _frames.push(step.facts.size, step.facts.alignment);
            evaluate(step.source, step.type, step.facts, value.base);
            storeBitfieldAt(step.field, base + step.offset,
                loadIntegral(value.base, step.facts.size,
                    !step.facts.isUnsigned));
            return;

        case broadcast:
            auto value = _frames.push(step.facts.size, step.facts.alignment);
            evaluate(step.source, step.type, step.facts, value.base);
            foreach (i; 0 .. step.count)
                memcpy(base + step.offset + i * step.facts.size, value.base,
                    step.facts.size);
            return;
        }
    }

    override void visit(StructLiteralExp expression) {
        import core.stdc.string: memset;
        import snakebite.nativelayout: isStoredLiteral;

        if (isStoredLiteral(expression)) {
            _nativeData.write(_type, _facts, expression, _place);
            return;
        }

        auto structType = _type.isTypeStruct;
        if (structType is null || structType.sym != expression.sd)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: struct literal layout mismatch"),
            );

        if (expression.elements !is null
                && expression.elements.length > expression.sd.fields.length)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: its fields do not match the struct layout"),
            );

        import snakebite.backends.aggregateinit: planStructLiteral;

        auto plan = planStructLiteral(expression);
        if (plan.zeroFill)
            memset(_place, 0, _facts.size);

        foreach (step; plan.steps)
            applyStep(step, cast(ubyte*) _place);
    }

    protected override void visitUnloweredCat(CatExp expression) {
        visit(cast(Expression) expression);
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
    // build would, rather than reimplementing the UTF-8/UTF-16 encoding
    // here, through the same `rawPlanOf`/`callPlan` shape `throwArrayBounds`
    // uses for a druntime hook with no `FuncDeclaration` of its own - the
    // bytecode compiler's own `visitUnloweredCatDcharAssign` does the
    // same. A plain cast of the resolved address to a function pointer
    // would make the D compiler emit the call, and ADR-0001 keeps the
    // assembly stub as the only place a forward call across the barrier
    // is made (issue #334 step 7). The hook takes the array by `ref` and
    // appends into it in place, so its own return value (that same
    // `{length, pointer}` pair) is never read back - the plan declares no
    // return register - and the updated pair is copied out of the array's
    // own storage instead.
    override void visitUnloweredCatDcharAssign(CatDcharAssignExp expression) {
        import core.stdc.string: memcpy;
        import snakebite.backends.druntimehooks: planOf, specOf;
        import std.conv: text;

        auto elementType = expression.e1.type.nextOf;
        if (elementType.ty != Tchar && elementType.ty != Twchar)
            throw new SnakebiteException(
                text("interpreter cannot evaluate `", expression.toString,
                    "`: appending a `dchar` to `", expression.e1.type.toString,
                    "` is neither `char[]` nor `wchar[]`"),
            );
        const hook = elementType.ty == Tchar
            ? DruntimeHook.arrayAppendChar : DruntimeHook.arrayAppendWchar;

        countForeignNameLookup;
        auto plan = planOf(*_plans, hook);
        if (plan is null)
            throw new SnakebiteException(
                text("interpreter cannot resolve the symbol `",
                    specOf(hook).name, "` for `", expression.toString,
                    "`: it is not in this process"),
            );

        auto array = addressOf(expression.e1);
        const value = cast(dchar) asIntegral(expression.e2);
        const(void*)[2] arguments = [
            cast(const(void)*) &array, cast(const(void)*) &value,
        ];
        callPlan(plan, null, arguments[]);

        memcpy(_place, array, _facts.size);
    }

    // An associative-array literal has no glue-layer codegen of its own to
    // interpret: dmd never leaves `AssocArrayLiteralExp.lowering` null once
    // it finds `object._d_assocarrayliteralTX!(K, V)`, so reaching here
    // means that lookup itself failed.
    protected override void visitUnloweredAssocArrayLiteral(
            AssocArrayLiteralExp expression) {
        import std.conv: text;

        throw new SnakebiteException(
            text("interpreter cannot evaluate `", expression.toString,
                "`: only a lowered associative-array literal is ",
                "supported"),
        );
    }

    override void visit(CommaExp expression) {
        // A struct constructor call's rvalue temporary (see
        // `structLiteralAddress`) may already have its fields written by
        // the constructor `expression.e1` runs - visiting the literal
        // again here, the ordinary way, would instead overwrite them with
        // the literal's own default fields. Routing through the same
        // slot and copying its bytes into `_place` keeps the constructor's
        // writes; every other `CommaExp` shape is unaffected, since
        // `structLiteralAddress` only ever does what `expression.e2.accept`
        // would have anyway when nothing bound the literal's address first.
        if (auto literal = expression.e2.isStructLiteralExp) {
            import core.stdc.string: memcpy;

            runForEffect(expression.e1);
            auto address = structLiteralAddress(literal);
            memcpy(_place, address, _facts.size);
            return;
        }

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
        _executeCallExpression(expression, _place);
    }

    private CallResult _executeCallExpression(
        CallExp expression, void* returnPlace,
    ) {
        import core.stdc.string: memcpy;
        import snakebite.frontend.dmd.functions: unresolvedCalleeOf;
        import std.conv: text;

        auto resolved = expression.f is null
            ? unresolvedCalleeOf(expression) : expression.f;
        auto callee = resolved is null
            ? calleeOf(expression)
            : Callee(resolved, null, false);
        if (callee.address !is null) {
            const target = _plans.guestTarget(callee.address);
            if (target.word is null)
                return _callIndirect(expression, callee.type,
                    callee.address, callee.context, callee.fromDelegate,
                    returnPlace);
            callee.function_ = cast(FuncDeclaration) cast(void*) target.word;
            callee.context = cast(ubyte*) callee.context + target.adjustment;
        }
        auto function_ = callee.function_;


        auto funcType = typeFunctionOf(function_);
        if (funcType.parameterList.varargs == VarArg.variadic
                && (!funcType.isDstyleVariadic
                    || function_.fbody is null
                    || !_program.isInterpreted(function_)
                    || _plans.hasNativeSymbol(function_))) {
            callVariadicNative(expression, function_, funcType);
            return CallResult.init;
        }

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
            if (!expression.directcall && receiver.isSuperExp is null
                    && function_.isVirtualMethod) {
                const address = _virtualAddress(function_, classReceiver);
                const target = _plans.guestTarget(address);
                if (target.word is null)
                    return _callIndirect(expression, funcType,
                        address, classReceiver, true, returnPlace);
                function_ = cast(FuncDeclaration) cast(void*) target.word;
                classReceiver = cast(ubyte*) classReceiver + target.adjustment;
            }
        }

        auto layout = layoutOf(function_);
        auto frame = bindFrame(
            expression,
            function_,
            layout,
            funcType.isDstyleVariadic,
            classReceiver,
            hasClassReceiver,
            callee.context,
            callee.fromDelegate,
        );

        return executeCall(
            function_, returnPlace, frame.base, layout, expression,
        );
    }

    private void bindVariadicArguments(
        CallExp expression, ubyte* frame, const(FrameLayout)* layout,
    ) {
        import snakebite.backends.variadic: VariadicLayout;
        import snakebite.nativelayout: storeIntegral;

        auto arguments = expression.arguments;
        const firstExtra = 1 + layout.parameters.length;
        TypeFacts[] facts;
        foreach (argument; (*arguments)[firstExtra .. $])
            facts ~= factsOf(argument.type);
        const plan = VariadicLayout.of(facts);
        auto storage = _frames.reserve(plan.size, plan.alignment);
        plan.initialize(storage);
        foreach (i, offset; plan.offsets) {
            auto argument = (*arguments)[firstExtra + i];
            evaluate(argument, argument.type, facts[i], storage + offset);
        }
        storeIntegral(frame + layout.variadicCursor, cast(size_t) storage,
            size_t.sizeof);
        auto types = (*arguments)[0];
        evaluate(types, types.type, factsOf(types.type),
            frame + layout.variadicTypes);
    }

    // Build the plan before evaluating arguments, so an unsupported call
    // cannot run guest argument effects before its refusal.
    private void callVariadicNative(
        CallExp expression,
        FuncDeclaration function_,
        TypeFunction funcType,
    ) {

        auto preparation = CallAdapter.Arguments.of(
            funcType, expression.arguments,
        );
        const plan = cachedCallPlan(expression, function_,
            () => preparation.prepare(*_plans, function_));
        auto layout = layoutOf(function_);
        auto frame = bindFrame(expression, function_, layout, true);
        bindArguments(function_, expression.arguments, expression.loc,
            frame.base, layout, true);

        const mark = _frames.mark;
        scope(exit) _frames.release(mark);
        auto slots = preparation.bind(
            layout.hiddenThis.variable is null ? null
                : frame.base + layout.hiddenThis.parameter.offset,
            (i) => frame.base + layout.parameters[i].offset,
            &evaluateBarrierArgument,
        );
        callPlan(plan, _place, slots.values);
    }

    extern(D) private void* evaluateBarrierArgument(
        CallAdapter.Arguments.Value value,
    ) {
        auto storage = _frames.reserve(value.facts.size, value.facts.alignment);
        evaluate(value.expression, value.expression.type, value.facts, storage);
        if (!value.readsField)
            return storage;

        import core.stdc.string: memcpy;

        const field = *cast(ubyte**) storage + value.fieldOffset;
        auto result = _frames.reserve(
            value.fieldFacts.size, value.fieldFacts.alignment,
        );
        memcpy(result, field, value.fieldFacts.size);
        return result;
    }

    private void* _virtualAddress(
        FuncDeclaration method, void* receiver,
    ) {
        auto table = *cast(void***) receiver;
        return table[method.vtblIndex];
    }

    private CallResult _callIndirect(
        CallExp expression, TypeFunction type, const(void)* address,
        void* context, bool hasContext, void* returnPlace,
    ) {
        const layout = FrameLayout.ofParameters(type, hasContext);
        auto frame = _frames.push(layout.size, layout.alignment);
        _bindArguments(type, expression.arguments, expression.loc,
            frame.base, &layout);
        auto arguments = CallArguments(layout.parameters.length + hasContext);
        auto values = arguments.values;
        if (hasContext)
            values[0] = &context;
        foreach (i, parameter; layout.parameters)
            values[i + hasContext] = frame.base + parameter.offset;
        return CallAdapter.ofType(type).invoke(returnPlace, values,
            (place, arguments) {
                _plans.signatureOf(type, hasContext).callAt(
                    address, place, arguments);
            });
    }

    private struct Callee {
        FuncDeclaration function_;
        void* context;
        bool fromDelegate;
        void* address;
        TypeFunction type;
    }

    // The callee of a call dmd left unresolved: one reached through a
    // value rather than a name, which for this interpreter means either a
    // delegate or a plain function pointer. Stored values hold callable
    // addresses; callback writeback can also return a registered guest
    // word. A delegate's context word is passed directly into
    // the callee's hidden context slot, since the delegate may be called
    // after the function that created it has returned; a function pointer
    // has no context word, so it never carries one.
    //
    // dmd lowers `fn(args)` on a function-pointer-typed `fn` to
    // `(*fn)(args)`, so the call's `e1` is a `PtrExp` whose own type is the
    // pointed-to `Tfunction`, not `Tpointer` - `deref.e1` is the pointer
    // expression itself, read with `asPointer` the same way any other
    // dereference reads what it points at.
    //
    // The callee kind comes from `callee.type`, not from whether `callee`
    // is a `PtrExp` (`isIndirectDelegateCall`'s own doc): a pointer to a
    // delegate (`key in aa` on a delegate-valued associative array, or
    // `&someDelegateVariable`) dereferences with the same `(*p)(args)`
    // syntax dmd's own function-pointer-call lowering produces, but
    // `callee.type` there is `Tdelegate`, not the `Tfunction` a
    // dereferenced function pointer's type always is.
    private Callee calleeOf(CallExp expression) {
        import snakebite.backends.calls: isIndirectDelegateCall;
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, delegateValueSize,
            loadIntegral;
        import std.conv: text;

        auto callee = expression.e1;
        if (!isIndirectDelegateCall(callee.type)) {
            auto deref = callee.isPtrExp;
            if (deref is null)
                throw new SnakebiteException(
                    text("interpreter cannot call an unresolved function: `",
                        expression.toString, "`"),
                );

            auto function_ = cast(FuncDeclaration) asPointer(deref.e1);
            if (function_ is null)
                throw new SnakebiteException(
                    text("interpreter cannot call `", expression.toString,
                        "`: the function pointer is null"),
                );

            if (auto declaration =
                    cast(void*) function_ in _shared.callableDeclarations)
                return Callee(*declaration, null, false);
            if (!_plans.isGuestWord(cast(void*) function_))
                return Callee(null, null, false, cast(void*) function_,
                    deref.type.isTypeFunction);
            return Callee(function_, null, false);
        }

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

        if (auto declaration =
                cast(void*) function_ in _shared.callableDeclarations)
            return Callee(*declaration, cast(void*) context, true);
        if (!_plans.isGuestWord(cast(void*) function_))
            return Callee(null, cast(void*) context, true,
                cast(void*) function_, callee.type.nextOf.isTypeFunction);
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

    // The receiver is evaluated before argument binding starts. The shared
    // construction operation can then protect that receiver while arguments
    // and the callee run.
    private FrameStack.Frame bindFrame(
        CallExp expression,
        FuncDeclaration function_,
        const(FrameLayout)* layout,
        in bool allowExtra = false,
        void* classReceiver = null,
        bool hasClassReceiver = false,
        void* delegateContext = null,
        bool fromDelegate = false,
    ) {
        import snakebite.nativelayout: storeIntegral;
        import snakebite.backends.calls: arityMismatches;
        import std.conv: text;
        import dmd.astenums: STC;

        // The callee's parameter types, which a body-less declaration has
        // just as much as one with a body - unlike `parameters`, which
        // only a body has.
        auto parameterList = typeFunctionOf(function_).parameterList;
        auto arguments = expression.arguments;
        if (arityMismatches(parameterList, arguments, allowExtra))
            throw new SnakebiteException(
                text("interpreter: `", function_.toString, "` expects ",
                    parameterList.length, " argument(s), got ",
                    arguments is null ? 0 : arguments.length),
            );

        auto frame = _frames.push(layout.size, layout.alignment);

        // `vthis` is dmd's one declaration for both hidden context
        // kinds: a method's `this`, and a nested function's static
        // chain. Which one this callee has is what `isThis` says.
        // The shared layout excludes unused lambda contexts even when
        // dmd retains their `vthis` declarations.
        if (layout.hiddenThis.variable !is null) {
            if (fromDelegate)
                storeIntegral(
                    frame.base + layout.hiddenThis.parameter.offset,
                    cast(size_t) delegateContext,
                    size_t.sizeof,
                );
            else if (function_.isThis !is null) {
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
                else {
                    auto receiver = addressOf(dot.e1);
                    storeIntegral(
                        frame.base + layout.hiddenThis.parameter.offset,
                        cast(size_t) receiver,
                        size_t.sizeof,
                    );
                }
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

                const context = cast(size_t) tryContextOf(enclosing);
                storeIntegral(
                    frame.base + layout.hiddenThis.parameter.offset,
                    context, size_t.sizeof);
            }
        }

        return frame;
    }

    // The address a call hands back for `addressOf` when the call itself is
    // the lvalue - `pick(a, b, true) = 5;`'s left side, or a `ref` argument
    // bound to another call's `ref` result. The FFI call adapter validates
    // that the result is a reference.
    private void* refCallAddress(CallExp expression) {
        return _executeCallExpression(expression, null).address;
    }

    // The address of a call's own return value, for `addressOf` when the
    // call returns by value rather than by `ref` - a function returning a
    // struct that another constructor call takes by address, with no
    // variable of its own to hold it. A frame slot sized for the return
    // type stands in for that missing variable, and the call fills it the
    // same way it would fill any other destination.
    //
    // The slot itself outlives this function: whatever `addressOf` this
    // ran for (ordinarily binding another call's `this` or a by-address
    // argument) keeps using the address after this returns. The statement
    // that owns the enclosing full expression is what releases it
    // (`releaseTemporariesSince`) - not this function, and not `Frame`'s
    // own RAII, which would pop it the instant this returns instead.
    private void* valueCallAddress(
        CallExp expression,
    ) {
        const facts = factsOf(expression.type);
        auto base = _temporaries.reserveValue(
            facts.size,
            facts.alignment,
        );

        _executeCallExpression(expression, base);
        return base;
    }

    // A struct constructor call's rvalue temporary reaches its frame slot
    // here, whichever of its two visits (the constructor's hidden `this`,
    // or the `CommaExp` naming the result) runs first - see `_temporaries`.
    // The first visit reserves the slot and default-initializes the
    // literal's own fields into it, exactly as a plain struct literal
    // would into `_place`; the constructor that runs next (in
    // `CommaExp.e1`) then writes its own fields on top.
    //
    // Recursion can revisit the same node before the outer visit's slot
    // is released - a constructor whose body calls back into the
    // function that is itself mid-construction of this same literal (see
    // the re-entrancy test in `structs.d`). Without `_temporariesFloor`,
    // a plain search over every entry would find the outer, still-live
    // slot instead of reserving a fresh one for the inner activation, and
    // the two activations would clobber each other's fields. Bounding
    // the search to `_temporariesFloor .. $` keeps each activation's
    // pairing within its own full expression: the outer entry sits below
    // the floor the inner activation's full expression raised, so it is
    // invisible until that inner full expression ends and lowers the
    // floor again.
    private void* structLiteralAddress(StructLiteralExp literal) {
        const facts = factsOf(literal.type);

        return _temporaries.structLiteralAddress(
            literal,
            facts.size,
            facts.alignment,
            facts,
            &initializeTemporary,
        );
    }

    private extern(C++) void initializeTemporary(
        StructLiteralExp literal,
        in TypeFacts facts,
        ubyte* base,
    ) {
        evaluate(literal, literal.type, facts, base);
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
// A (nested function, enclosing function) pair, by address: which chain of
// hops leads from the one's frame to the other's context is fixed for
// the pair.
private struct StaticChainKey {
    const(void)* from;
    const(void)* to;
}

// One evaluator's view of a shared table (ADR-0006): an answer worked
// out on a cold path, under the compiler lock, kept for the life of the
// program, and read back by key on a hot one without a lock. The number
// of times this evaluator has probed it is counted.
//
// The count is what makes it a type rather than a table declaration.
// Every probe of one of these is a hash of a pointer on a path the
// evaluator takes per node it visits, so how many of them a guest
// construct needs is a property worth asserting on, and a probe of a
// table that is already a `Cache` is counted without whoever adds it
// having to know the count exists.
//
// That is the whole of what the count covers: reads of the tables that
// are `Cache`s. A probe made inside `FrameLayout` or `PlanCache` to
// answer one query, and `build` below - itself a probe, though only ever
// on a cold path - are outside it. What this feeds is a budget on the
// paths it does cover, not a fence around the evaluator.
//
// The count itself is `bin/ut` only: an unconditional increment here
// would be exactly the per-node cost it exists to measure.
private struct Cache(Key, Value) {
    import snakebite.sharedtable: SharedTable;

    private SharedTable!(Key, Value)* _table;
    version(unittest) private size_t _lookups;

    public Value* opBinaryRight(string op: "in")(Key key) {
        version(unittest) ++_lookups;

        return key in *_table;
    }

    // The slow path: runs `make` and stores its answer, unless another
    // thread's own `build` for the same key already stored one first -
    // `_table.insert` (`SharedTable`, ADR-0006) keeps the first value
    // and hands every caller that same one back, under its own table
    // lock, so two threads racing the same miss cannot corrupt this
    // cache or disagree about the answer.
    //
    // `make` is never wrapped in the frontend compiler lock here: this
    // cache's own data is a `SharedTable`, which brings its own lock, so
    // nothing about *this* table needs the frontend one. The dmd forward
    // references a particular `make` (`buildLayout`, `buildCallShape`,
    // ...) can still need to resolve are its own concern, taken only
    // where they happen and only while dmd has not already resolved
    // them (`snakebite.frontend.compiler.forceIfNeeded`), not a blanket
    // lock around every `build` regardless of whether this key's own
    // `make` still needs one. A `make` that races another thread's
    // `make` for the same key redoes the same (by then always safe,
    // read-only) work twice; `insert` below throws the loser's answer
    // away, never both.
    public Value* build(Key key, scope Value delegate() make) {
        return _table.insert(key, make());
    }

    version(unittest)
    public size_t lookups() @safe @nogc nothrow pure const scope {
        return _lookups;
    }
}
