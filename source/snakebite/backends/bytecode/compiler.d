module snakebite.backends.bytecode.compiler;


private:

import dmd.mtype: Type;
import object: TypeInfo_Class;
import snakebite.backends.argumentflow: Shape;
import snakebite.backends.loweringvisitor: LoweringVisitor;
import snakebite.backends.identity: IdentityPlan;
import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;
import snakebite.backends.switchplan:
    switchPlan, gotoCaseTarget, gotoDefaultTarget;
import snakebite.backends.fullexpression:
    FullExpressionKind, FullExpressionScope;
import snakebite.backends.controlflow:
    ScopeFrame, ScopePaths, scopePathsOf;
import snakebite.backends.exceptionplan:
    UnwindPlan, catchPlanOf, unwindPlanOf;
import snakebite.backends.checkplan: BoundsCheck, hookOf;
import snakebite.backends.druntimehooks: DruntimeHook, planOf;
import snakebite.backends.sliceplan: planSlice;
import snakebite.backends.exceptions: AssertFailure, CAssertCall;
import snakebite.ffi: CallbackBridge, CallbackCall, PlanCache;


// A pointer-sized temporary's facts: the shape every address this compiler
// computes at run time - a `ref` binding, an array element's, an
// allocation's result - shares, whatever the value living behind it
// eventually is.
private imported!"snakebite.nativelayout".TypeFacts pointerFactsOf() {
    import snakebite.nativelayout: TypeFacts;

    return TypeFacts(size_t.sizeof, size_t.sizeof, false, true);
}

public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import core.time: Duration;
    import dmd.dclass: ClassDeclaration;
    import dmd.declaration: Declaration;
    import dmd.func: FuncDeclaration;
    import dmd.root.string: toDString;
    import snakebite.backends.backend: CompilationStatistics, Program;
    import snakebite.backends.calls: CallSelection;
    import snakebite.backends.classinfo;
    import snakebite.backends.bytecode.vm: Function, Vm;
    import snakebite.backends.layout: FrameLayout;
    import snakebite.frontend.checks: Checks;
    import snakebite.sharedtable: SharedTable;
    import snakebite.exception: SnakebiteException;
    import snakebite.framestack: defaultFrameCapacity;
    import snakebite.hostthreads: heapNew, PerThread;
    import snakebite.nativelayout: NativeData, nativeSymbolName;
    import snakebite.backends.runtimetypes: RuntimeTypes;

    // Each native stack needs its own guest frame stack. Fibers can resume
    // out of nesting order, so they cannot share one LIFO stack.
    // Entries are owned and released by their host thread (ADR-0006).
    private PerThread!(Vm*, true) _vms;
    private NativeData _nativeData;
    private PlanCache _plans;
    private CallSelection _callSelection;
    // Keyed by pointer, not by value: a call site compiled while
    // `function_` itself is still mid-compile - direct or mutual
    // recursion - embeds this pointer in its `CallSite` before the body
    // this AA slot points at has been filled in. The slot's address must
    // therefore never move once handed out, which is why this holds a
    // `Function*` rather than a `Function` - a heap block `new` allocates
    // once and never relocates, unlike an associative array's own
    // storage, which can rehash as more entries go in.
    private Function*[FuncDeclaration] _compiled;
    // The functions in `_compiled` whose body is complete, read without a
    // lock: the first guest call of a thread can be the one that a GC
    // finalizer makes, and it cannot wait for a lock that another thread
    // holds while it waits for the GC.
    private SharedTable!(FuncDeclaration, const(Function)*) _complete;
    private const(Function)*[] _callbackRoots;
    private bool _preparingCallbacks;
    // The prepared FFI plan for druntime's own allocator, built once and
    // reused by every `new T[](n)`/array literal any function compiles -
    // the same `rawPlanOf` a bounds hook already goes through, so this
    // costs nothing new besides the one symbol lookup.
    private const(void)* _allocatorPlan;
    private RuntimeTypes _runtimeTypes;
    // Guest classes never reach dmd's own code generator, so nothing ever
    // emits their `TypeInfo_Class`, instance vtable or `.init` bytes as
    // real linked data - this builds the same shapes by hand instead, once
    // per `ClassDeclaration`, and every later `new`/virtual call/`typeid`
    // reuses the one already built.
    private snakebite.backends.classinfo.ClassRuntimeCache _classRuntime;
    private size_t _compilationDepth;
    private size_t _cacheMisses;
    private Duration _compilationTime;
    // The frame layout of every guest function reached through
    // `runHostToGuest`, built once per declaration and shared by the
    // program runner's top-level call and a callback's re-entry.
    // `SharedTable` (not a plain AA): several threads reach this cache
    // through the same object, one thread's call and another thread's
    // callback among them (ADR-0006).
    private SharedTable!(FuncDeclaration, FrameLayout) _hostLayouts;

    public this(const Program program) {
        super(program);
        _plans = PlanCache(program.dependencyImage);
        _callSelection.linksFunctions = program.definesLinkableFunctions;
        _nativeData = NativeData(&_program.isRootOwned,
            (variable) => _program.linkedVariableOf(variable),
            &constantSymbolAddress,
            (name) => _plans.resolveThreadLocal(name),
            &classRuntimeInfo, &callLowering);
        _runtimeTypes = RuntimeTypes(&_program.isRootOwned,
            (name) => _plans.resolve(name), &callableAddress,
            &classRuntimeInfo,
            (type, loc) => _nativeData.initialValue(type, loc));
        _vms = PerThread!(Vm*, true)(() {
            return heapNew!Vm(defaultFrameCapacity, _nativeData.tlsSlots);
        });
        _plans.useCallbacks(
            new CallbackBridge(&invokeCallback, cast(void*) this));
    }

    protected override void release() {
        _vms.release;
        _nativeData.release;
    }

    private void* constantSymbolAddress(
        Declaration symbol,
    ) {
        if (auto function_ = symbol.isFuncDeclaration)
            return callableAddress(function_, 0);

        return _plans.resolve(nativeSymbolName(symbol));
    }

    private void callLowering(
        FuncDeclaration function_,
        void* returnPlace,
        scope void*[] arguments,
    ) {
        _callSelection.callLowering(function_, returnPlace, arguments,
            &isGuestFunction, hasNativeSymbol(function_),
            hasIndependentNativeSymbol(function_), &call,
            (callee, place, args) => _plans.of(callee).call(place, args));
    }

    public override CompilationStatistics compilationStatistics() const {
        return CompilationStatistics(
            true,
            _cacheMisses,
            _compilationTime,
        );
    }

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        // `compileFunction` takes the frontend (compiler) lock itself,
        // for its own whole compile, the same lock every other
        // dmd-touching entry point on every backend takes
        // (`snakebite.frontend.compiler.withCompilerLock`) - see
        // `compileFunction`'s own doc for why a second, backend-local
        // lock cannot give class-runtime building and function
        // compilation one consistent order.
        auto complete = function_ in _complete;
        const(Function)* compiled = complete is null
            ? compileFunction(function_) : *complete;
        runHostToGuest(compiled, function_, returnPlace, args);
    }

    public override void[] staticStorage(
        imported!"dmd.declaration".VarDeclaration variable,
    ) {
        return _nativeData.storageOf(variable);
    }

    // The bytecode backend's one host-to-guest entry. The program
    // runner's top-level call (`call`) and a callback's re-entry
    // (`callGuestFromHost`) both reach the compiled body only here -
    // neither binds arguments on its own. `args` are host-to-guest
    // arguments in native layout, one pointer per parameter, per
    // `Backend.call`'s own contract - each pointer holds the address of
    // storage for that parameter's native bytes, which for a `ref`/`out`
    // parameter are the target's own address. When the callee has a
    // hidden `this`, `args[0]` is that same shape one more time, before
    // the declared parameters: the address of a pointer-sized word
    // holding the context - the one convention `CallPlan.call` and a
    // callback's own `addresses` already use for it.
    //
    // A `ref`-returning callee hands back the result's own address, not
    // its value - the same word compiled D returns in `rax`.
    //
    // `compiled` is already built, and `function_`'s frame layout below
    // is read from a cache built under the compiler lock the first time
    // any thread needs it (`hostLayoutOf`): binding `args` into
    // `Vm.HostArgument`s and running the compiled body touch no dmd
    // state, so this takes no lock of its own. A thread that held the
    // compiler lock here while it waited for another thread's callback -
    // the way `Thread.join` waits in `otherThread`/`concurrentThreads`
    // guest code - would never see that callback return, since the
    // callback's own slow path (`hostLayoutOf`'s miss branch) needs that
    // same, recursive lock to build a layout the first time (ADR-0006).
    private void runHostToGuest(
        const(Function)* compiled,
        FuncDeclaration function_,
        void* returnPlace,
        scope const(void*)[] args,
        void* variadicCursor = null,
        const(void)* variadicTypes = null,
    ) {
        const layout = hostLayoutOf(function_);
        layout.checkHostArgumentCount(args.length, function_, "bytecode");

        Vm.HostArgument[16] inlineArguments = void;
        const count = layout.parameters.length
            + (layout.hiddenThis.variable !is null)
            + (variadicCursor !is null)
            + (variadicTypes !is null);
        auto arguments = count <= inlineArguments.length
            ? inlineArguments[0 .. count] : new Vm.HostArgument[count];
        size_t filled;

        scope const(void*)[] declaredArguments = args;
        if (layout.hiddenThis.variable !is null) {
            arguments[filled++] = Vm.HostArgument(
                layout.hiddenThis.parameter.offset, args[0],
                size_t.sizeof,
            );
            declaredArguments = args[1 .. $];
        }

        foreach (i, parameter; layout.parameters)
            arguments[filled++] = Vm.HostArgument(
                parameter.offset, declaredArguments[i],
                parameter.facts.size);

        if (variadicCursor !is null) {
            assert(layout.variadicCursor != size_t.max);
            arguments[filled++] = Vm.HostArgument(
                layout.variadicCursor, &variadicCursor, size_t.sizeof);
        }
        if (variadicTypes !is null) {
            assert(layout.variadicTypes != size_t.max);
            arguments[filled++] = Vm.HostArgument(
                layout.variadicTypes, &variadicTypes, size_t.sizeof);
        }

        _vms.current.call(*compiled, returnPlace, arguments[0 .. filled]);
    }

    // `function_`'s frame layout, read without a lock once built
    // (ADR-0006): both host-to-guest entries share this cache instead of
    // each keeping its own, and its value is a pure function of the
    // declaration, worked out - no frontend lock needed, see below - the
    // first time any thread needs it.
    private const(FrameLayout)* hostLayoutOf(FuncDeclaration function_) {
        if (auto found = function_ in _hostLayouts)
            return found;

        // No frontend lock: `FrameLayout.of` forces whatever dmd forward
        // reference it still needs itself, only while it is still
        // unresolved (`hasHiddenThis`'s own `forceIfNeeded` guard), and
        // `_hostLayouts` is a `SharedTable`, which brings its own insert
        // lock (ADR-0006) - the same reasoning `snakebite.backends.
        // interpreter.walker`'s `Cache.build` already applies to its own
        // `FrameLayout` cache.
        return _hostLayouts.insert(function_, FrameLayout.of(function_));
    }

    public override string eval(FuncDeclaration function_) {
        string result;
        call(function_, &result, []);
        return result;
    }

    package bool hasNativeSymbol(FuncDeclaration function_) {
        return _plans.hasNativeSymbol(function_);
    }

    package bool hasIndependentNativeSymbol(FuncDeclaration function_) {
        return _plans.hasIndependentNativeSymbol(function_);
    }

    package bool isGuestFunction(FuncDeclaration function_) const {
        return _program.isInterpreted(function_);
    }

    package FuncDeclaration definitionOf(FuncDeclaration function_) {
        return _callSelection.definitionOf(
            function_, (declaration) => _program.linkedFunctionOf(declaration));
    }

    package Checks checks() const {
        return _program.checks;
    }

    package imported!"snakebite.backends.haltprocess".HaltAction
    haltAction() const {
        return _program.haltAction;
    }

    // Records that `compiled` is the word this backend stores for
    // `function_`'s address - what the plan swaps for a pool entry
    // (ADR-0003) when the word crosses to host code, and what
    // `invokeCallback` gets back when host code calls that entry.
    package void registerGuestWord(
        FuncDeclaration function_, const(Function)* compiled,
    ) {
        // A callback can first run during GC finalization, when allocating
        // its argument layout is forbidden.
        hostLayoutOf(function_);
        _plans.registerGuestFunction(compiled, function_);
    }

    extern(C) private static void invokeCallback(
        void* context,
        CallbackCall* call,
    ) {
        auto bytecode = cast(Bytecode) context;
        bytecode.callGuestFromHost(call);
    }

    // The re-entry a pool entry (ADR-0003) reaches when host code calls a
    // guest function pointer or delegate. It shares `runHostToGuest` with
    // the program runner's top-level call: neither binds arguments on its
    // own, and `call.function_` - the word `registerGuestWord` recorded
    // when the callee was first compiled - is already built, so this
    // takes no compiler lock of its own, on whichever thread's VM is
    // calling (ADR-0006). A `Throwable` the body throws unwinds through
    // the host frames untouched (ADR-0004).
    private void callGuestFromHost(CallbackCall* call) {
        runHostToGuest(cast(const(Function)*) call.function_,
            call.declaration, call.returnPlace, call.arguments,
            call.variadicCursor, call.variadicTypes);
    }

    // The prepared FFI plan for druntime's own `gc_malloc`, the real
    // allocator a `new T[](n)`/array literal calls through the same
    // `rawPlanOf` a bounds hook already goes through - never a private
    // bump allocator or free list of this compiler's own, and never a
    // signature this module hardcodes: the VM that runs the plan reads
    // it back only as an opaque `CallSite.native` payload.
    package const(void)* allocatorPlan() {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;

        if (auto found = atomicLoad!(MemoryOrder.acq)(_allocatorPlan))
            return found;

        // `rawPlanOf` hands back the same address for "gc_malloc" no
        // matter which thread asks (`PlanCache._rawPlans` is a
        // `SharedTable`, ADR-0006), so two threads racing here store the
        // same value; the store just needs to be visible to a later
        // reader.
        auto plan = planOf(_plans, DruntimeHook.gcMalloc);
        atomicStore!(MemoryOrder.rel)(_allocatorPlan, plan);
        return plan;
    }

    // The native metadata a guest class needs at run time: an instance
    // vtable, a per-interface vtable and the `.init` bytes `_d_newclassT`'s
    // real body would otherwise copy from a linked symbol this project's
    // compiler never emits. Built by `snakebite.backends.classinfo`,
    // shared with the interpreter's own version of this same question;
    // only how a vtable slot gets its callable value is this backend's
    // own.
    package TypeInfo_Class classRuntimeInfo(
        ClassDeclaration declaration,
    ) {
        import snakebite.backends.classinfo:
            classRuntimeInfo_ = classRuntimeInfo, Hooks;

        if (auto found = _classRuntime.find(declaration))
            return *found;

        return _classRuntime.build(() => classRuntimeInfo_(
            declaration,
            _classRuntime,
            Hooks(
                &callableAddress,
                &fillFieldInits,
                &_runtimeTypes.linkedClassInfo,
                (decl) => _runtimeTypes.rtInfo(decl),
            ),
        ));
    }

    // Function pointers can reach host code inside aggregates or through
    // pointers to guest data, where the call barrier cannot replace them.
    private void* callableAddress(FuncDeclaration method, ptrdiff_t adjustment) {
        import dmd.dsymbolsem: isAbstract;

        // getOverloads can leave an alias in a function-pointer constant.
        method = definitionOf(method.toAliasFunc);
        if (method.isAbstract)
            return null;
        const(void)* word;
        const hasNativeSymbol = _plans.hasNativeSymbol(method);
        const isVariadicGuest =
            _callSelection.isVariadicGuest(method, hasNativeSymbol);
        if (_callSelection.usesNativeVariadicAddress(
                method, hasNativeSymbol))
            return _plans.addressOf(method);
        if (isVariadicGuest || _callSelection.usesGuestBody(method, &isGuestFunction,
                hasNativeSymbol, hasIndependentNativeSymbol(method))) {
            word = compileFunction(method);
            registerGuestWord(method, cast(const(Function)*) word);
            _callbackRoots ~= cast(const(Function)*) word;
            if (_compilationDepth == 0)
                prepareCallbackBodies;
            if (_callSelection.storesGuestWord(
                    method, hasNativeSymbol, adjustment))
                return cast(void*) word;
        }
        return _plans.callableAddress(word, method, adjustment);
    }

    // A callback can first execute during GC finalization. Compile every
    // guest function reachable from it before exposing it to host
    // execution, while allocation is allowed. Wait for recursive
    // placeholders to have complete bodies. A callee whose body this
    // compiler rejects stays deferred: compiled D compiles a callee it
    // never runs, so only a call that executes may fail on it.
    private void prepareCallbackBodies() {
        import snakebite.backends.bytecode.vm: CallSite;

        if (_preparingCallbacks || !_callbackRoots.length)
            return;
        _preparingCallbacks = true;
        scope(exit) _preparingCallbacks = false;
        bool[const(Function)*] visited;
        void prepare(const(Function)* function_) {
            if (function_ in visited)
                return;
            visited[function_] = true;
            foreach (ref site; function_.callSites) {
                // Temporary-cleanup entries also occupy this table, but
                // have neither a callee nor a compilation callback.
                if (site.kind != CallSite.Kind.guest
                        || (site.callee is null && site.prepareGuest is null))
                    continue;
                if (site.callee !is null) {
                    prepare(site.callee);
                    continue;
                }
                // Preparing is speculative: the site may never execute. A
                // rejected callee leaves no compiled form behind, so the
                // site rejects it again if it does execute. The compiler
                // rejects with a `SnakebiteException`, but a native call
                // it plans for a callee that the call barrier cannot pass
                // fails with a plain `Exception`. Both are rejections; only
                // an `Error` is a fault, and that ends the process. Nothing
                // that reaches here therefore drops the roots queued
                // behind this one.
                const(Function)* prepared;
                try
                    prepared = site.prepareGuest();
                catch (Exception) {
                    continue;
                }
                prepare(prepared);
            }
        }
        while (_callbackRoots.length) {
            const roots = _callbackRoots;
            _callbackRoots = null;
            foreach (root; roots)
                prepare(root);
        }
    }

    private void fillFieldInits(
        ClassDeclaration declaration, ubyte* base,
    ) {
        _nativeData.fillFields(declaration, base);
    }
    // `function_`'s compiled form, compiling its body on first use.
    // Reused on every later call to the
    // same function, the way compiled code only ever compiles a function
    // once. Returns a stable pointer (see `_compiled`) so a call site
    // reached while this very function is still being compiled can point
    // at it too.
    //
    // Locked on the frontend (compiler) lock (`snakebite.frontend.
    // compiler.withCompilerLock`), not a lock of this backend's own: a
    // guest class's runtime info (`snakebite.backends.classinfo.
    // ClassRuntimeCache.build`) already runs its `make` callback under
    // this same lock, and `make` can reach `callableAddress` -> here,
    // compiling a method for the first time to fill a vtable slot. A
    // second, backend-local lock taken here (`_compileLock`, this
    // function's own mutex before this fix) gave the two paths opposite
    // orders: `build` held the compiler lock and waited on
    // `_compileLock`, while this, walking a body, could hold
    // `_compileLock` and wait on the compiler lock instead - through a
    // forced dmd forward reference (`TypeFacts.of`, `FrameLayout.of`,
    // ... - `forceIfNeeded`) or through `visitUnloweredNew` reaching
    // `classRuntimeInfo` -> `build` for a class not yet built. Two
    // threads, one in each order, could deadlock forever - the same
    // shape `ClassRuntimeCache`'s own lock used to hit against this
    // same compiler lock before it was removed in favour of this one
    // (`classinfo.d`'s own history). The compiler lock's recursion
    // (`core.sync.mutex.Mutex`'s default) makes reusing it here free of
    // extra cost on every path that already holds it - `build`'s `make`
    // reaching back in here nests for free, and this function's own
    // recursive reach of itself through `callableAddress`'s call for a
    // variadic function that takes its own address inside its own body
    // nests for free too - at the cost of serialising every unrelated
    // `Bytecode` instance's first compile of any function against every
    // other's, which the removed backend-local lock did not.
    //
    // `_compiled` is a plain AA, not a `SharedTable`: it needs the
    // placeholder registered below to keep one fixed address for as
    // long as a recursive or concurrent reach of the same function
    // might already be holding a `CallSite` that points at it (this
    // function's own first doc paragraph), which a `SharedTable`'s
    // "first write wins, never overwritten" insert does not provide -
    // so both the miss check and the whole compile stay under the one
    // lock, held for this one function's own duration.
    package const(Function)* compileFunction(FuncDeclaration function_) {
        import dmd.astenums: STC, Tvoid;
        import dmd.funcsem: needsClosure;
        import dmd.typesem: nextOf;
        import snakebite.backends.layout: FrameLayout;
        import snakebite.frontend.compiler: withCompilerLock;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.nativelayout: TypeFacts;
        import std.conv: text;

        if (function_ is null)
            assert(0, "callers pass a resolved function");

        const(Function)* result;
        withCompilerLock({
            if (auto found = function_ in _compiled) {
                result = *found;
                return;
            }

            import std.datetime.stopwatch: AutoStart, StopWatch;

            const outermost = _compilationDepth == 0;
            ++_compilationDepth;
            ++_cacheMisses;
            auto stopWatch = StopWatch(AutoStart.yes);
            scope (exit) {
                --_compilationDepth;
                if (outermost)
                    _compilationTime += stopWatch.peek;
            }

            // A struct method's hidden `this` is a pointer to the receiver,
            // and a class method's is a class reference - both are one
            // pointer wide in `FrameLayout.of`, so a class method's own body
            // compiles the same way. A nested function uses the same DMD
            // slot for its static chain, which the bytecode frame carries
            // as a context pointer.

            auto functionType = typeFunctionOf(function_);
            auto returnType = function_.type.nextOf;
            const isVoidReturn = returnType !is null && returnType.ty == Tvoid;
            // A `ref` return hands the caller the returned storage's own
            // address rather than a copy of its value - see
            // `visitReturnOperand` and `compileAddress` - so the frame slot
            // a caller reads it into is one pointer wide regardless of what
            // the returned type
            // itself would otherwise need, the same convention `snakebite.
            // ffi.plan` already uses for a native `ref`-returning callee.
            const isRefReturn = functionType.isRef;
            const pointeeFacts =
                isVoidReturn ? TypeFacts.init : TypeFacts.of(returnType);
            const returnFacts = isRefReturn ? pointerFactsOf : pointeeFacts;

            auto body_ = function_.fbody;
            if (body_ is null)
                assert(0, "`CallSelection` routes a bodyless function to "
                    ~ "FFI or a builtin, never to the compiler");

            auto layout = FrameLayout.of(function_);

            // Registered before the body is walked, not after: a call
            // inside this very body to `function_` itself finds this
            // placeholder through `_compiled` above instead of recompiling
            // forever. Its fields are filled in below, once `build`
            // returns; nothing reads them before then, since a `CallSite`'s
            // callee is only ever dereferenced when the VM actually runs
            // the call, which cannot happen before `compile`/`call` returns
            // from the top-level compile that reached here.
            auto placeholder = new Function;
            _compiled[function_] = placeholder;
            // A rejected body must not stay cached as an empty function
            // that a later call would run.
            scope(failure) _compiled.remove(function_);
            registerGuestWord(function_, placeholder);

            scope compiler = new FunctionCompiler(
                this, function_, layout, returnFacts, isVoidReturn,
                isRefReturn);
            *placeholder = compiler.build(body_);
            _complete.insert(function_, placeholder);
            if (outermost)
                prepareCallbackBodies;

            result = placeholder;
        });
        return result;
    }
}


// Compiles one function's body into bytecode against its already-computed
// declared-storage layout (`_layout`, shared with the interpreter). Beyond
// that layout's own `size`, this owns every byte the compiled function
// needs for its own temporaries - a call's arguments, a return value on
// its way out, an operand of a nested expression - by growing
// `_tempSize`/`_tempAlignment` past it; nothing about a temporary slot is
// ever handed back through `FrameLayout` itself.
extern(C++) private final class FunctionCompiler: LoweringVisitor {
    import snakebite.ffi.call: CallAdapter;
    import dmd.arraytypes: Expressions;
    import dmd.declaration: VarDeclaration;
    import dmd.identifier: Identifier;
    import dmd.init: ExpInitializer;
    import dmd.location: Loc;
    import dmd.expression;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type, TypeFunction;
    import dmd.statement:
        BreakStatement, CaseStatement, CompoundStatement, ContinueStatement,
        DefaultStatement, DoStatement, ExpStatement, ForStatement,
        GotoCaseStatement, GotoDefaultStatement, GotoStatement, IfStatement,
        ImportStatement, LabelStatement, ReturnStatement, ScopeStatement, Statement,
        SwitchErrorStatement, SwitchStatement, ThrowStatement,
        TryCatchStatement, ScopeGuardStatement, TryFinallyStatement,
        UnrolledLoopStatement, WithStatement;
    import dmd.tokens: EXP;
    import snakebite.backends.bytecode.vm:
        Arg, AssertSite, CallSite, ClosureSlot, castSizeWithSignedness,
        discardResult, indirectStorage,
        ExceptionHandler, Function,
        Instruction,
        opAdd, opAssert, opBitAnd, opBitOr, opBitXor, opBranchFalse,
        opBranchTrue, opCall,
        opCastAs, opCastFixedAs,
        opCastToBool, opCastWidenSigned, opCastWidenUnsigned, opComplement,
        opAlloca, opArrayEqual, opComplex, opComplexNegate, opConstant, opCopy,
        opCopyFixed, opThenReturn,
        opDivideSigned, opDivideSigned32, opDivideUnsigned,
        opEqual, opEqualBranch, opGreaterOrEqualSignedBranch,
        opGreaterOrEqualUnsignedBranch, opGreaterThanSignedBranch,
        opGreaterThanUnsignedBranch, opLessOrEqualSignedBranch,
        opLessOrEqualUnsignedBranch, opLessThanSignedBranch,
        opLessThanUnsignedBranch, opNotEqualBranch,
        opFloatAdd, opFloatDivide, opFloatEqual, opFloatGreaterOrEqual,
        opFloatGreaterThan, opFloatLessOrEqual, opFloatLessThan,
        opFloatModulo, opFloatMultiply, opFloatNegate, opFloatNotEqual,
        opFloatSubtract, opFloatToBool,
        opFloatWidthCast, opFrameAddress, opGreaterOrEqualSigned,
        opGreaterOrEqualUnsigned, opGreaterThanSigned, opGreaterThanUnsigned,
        opJump, opLessOrEqualSigned, opLessOrEqualUnsigned, opLessThanSigned,
        opLessThanUnsigned, opLoadBitfield, opLoadIndirect, opLogicalNot,
        opModuloSigned, opModuloSigned32,
        opModuloUnsigned, opMultiply, opNegate, opNotEqual,
        opReturn,
        opReturnVoid, opShiftLeft, opShiftRightArithmetic, opShiftRightLogical,
        opTemporaryArm, opTemporaryArmAddress, opTemporaryBegin,
        opTemporaryEnd,
        opTemporaryRegister, opTemporarySuspend,
        opSliceCopy, opSliceFill, opSlicesConform,
        opStaticAddress, opStaticArrayEqual, opStaticLoad, opStaticStore,
        opStoreBitfield, opStoreIndirect, opSubtract, opThrow, opZero,
        opTlsAddress, opTlsLoad, opTlsStore;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf, toBasetype;
    import snakebite.frontend.dmd.delegates:
        DelegateTarget, delegateTargetOf, outerFunctionOf;
    import snakebite.backends.aggregateinit: InitStep, NewPlan;
    import snakebite.nativelayout: bitfieldAccess, fieldOffset;
    import snakebite.backends.builtins: BuiltinCall;
    import snakebite.backends.calls: CallSelection;
    import snakebite.backends.casts: CastPlan;
    import snakebite.backends.closureplan: ClosurePlan;
    import snakebite.backends.compoundassign:
        CompoundConversion, compoundConversion;
    import snakebite.backends.dualcontext:
        ContextSource, PairPlan, calleeContextSourceOf, contextSourceOf,
        pairPlanOf;
    import snakebite.backends.layout: ClosureLayout, FrameLayout;
    import snakebite.backends.temporary: TemporaryPlan, constructTemporary;
    import snakebite.exception: SnakebiteException;
    import snakebite.nativelayout:
        alignUp, initializerRunsForEffect, initializerValueOf,
        isIntegralSize, isThreadLocalStorage, TypeFacts;
    import snakebite.nativevalue: CastKind;

    alias visit = LoweringVisitor.visit;

    extern(D):

    private Bytecode _bytecode;
    private FuncDeclaration _function;
    private const FrameLayout _layout;
    private ClosureLayout _closureLayout;
    private ClosurePlan[FuncDeclaration] _closurePlans;
    private TypeFacts _returnFacts;
    private bool _isVoidReturn;
    // Whether this function returns by `ref`: `visitReturnOperand` then
    // compiles its own returned storage's address instead of its value, and a
    // caller's own `opCall` result slot holds that address rather than a
    // copy - see `compileAddress`'s own `CallExp` case, the one place that
    // address is read back out.
    private bool _isRefReturn;
    // Where `visitReturnOperand` left the value, or the address of the
    // returned storage, for `visitReturnTransfer` to return.
    private size_t _returnOffset;

    private Instruction[] _instructions;
    private long[] _constants;
    private CallSite[] _callSites;
    private AssertSite[] _assertSites;
    private size_t _haltSite = size_t.max;
    private PendingExceptionHandler[] _exceptionHandlers;
    private size_t _tempSize;
    private uint _tempAlignment;
    private struct Temporary {
        size_t base;
        size_t site;
        Expression destructor;
    }
    private Temporary[] _temporaries;
    private size_t[] _lifetimeMarkers;
    private size_t[] _lifetimeFirstTemporaries;
    private FullExpressionScope _expressions;
    private bool _emittingCleanup;
    private size_t _closureOffset = size_t.max;
    // Set once nothing after the statement just compiled can run: a
    // `return`, a `continue`, or an `if`/loop whose every path already
    // ends one of those. Every statement kind after one in the same block
    // is dead code dmd itself only warns about, so nothing is compiled
    // for it, and none of its own kinds need this compiler to recognise
    // them. Reset by whichever construct (`if`, a loop) knows execution
    // can still reach past it - a `continue` inside a loop body, say,
    // does not end the loop itself.
    private bool _finished;
    // The `finalbody` of every `TryFinallyStatement` this compiler is
    // currently inside the `_body` of, outermost first - what
    // `visitReturnTransfer` inlines, innermost first, before a `return`
    // inside one of these actually leaves the function. Pushed/popped around
    // `_body` alone (see `visit(TryFinallyStatement)`): a `return` inside
    // `finalbody` itself must not re-run the `finally` it is already in.
    private Statement[] _pendingFinallyBodies;
    private ScopePaths _scopePaths;
    // The loop or unrolled `foreach` this compiler is currently inside the
    // body of, innermost last - what a `continue` targets, labelled or
    // not. A `do` knows its own continue target (the condition it
    // re-checks) before it compiles its body; a `for`'s increment and an
    // unrolled `foreach`'s next element are both only known once the body
    // ahead of them is already compiled, so a `continue` reached first
    // queues its own instruction index in `pendingContinueJumps` instead,
    // and `resolveContinues` patches every one of them in once the target
    // is known.
    private struct LoopContext {
        Identifier label;
        size_t continueTarget = size_t.max;
        size_t[] pendingContinueJumps;
        ScopeFrame[] scopePath;
    }

    private struct PendingExceptionHandler {
        private TypeInfo_Class _type;
        private size_t _bodyStart;
        private size_t _bodyEnd;
        private size_t _handler;
        private size_t _catchOffset;
        private size_t _cleanupEnd = size_t.max;
    }

    // Where `runPendingFinallyBodies` last inlined a `finally` for a
    // `return`, and which `try`/`finally` (by its index into
    // `_pendingFinallyBodies` at the moment it was pushed) it belongs to.
    // `visit(TryCatchStatement)` reads this to keep an inlined `finally`'s
    // own instructions out of a `catch` nested inside that same
    // `try`/`finally`'s `_body` - see `protectedRanges`'s own doc for why
    // a `catch` further out still needs to keep protecting them.
    private struct FinallyHole {
        size_t start;
        size_t end;
        size_t finallyIndex;
    }
    private FinallyHole[] _finallyHoles;

    // The sub-ranges of a `catch`'s own `[bodyStart, bodyEnd)` that are
    // still genuinely inside its protection, once every `FinallyHole`
    // punched into it by a `return` further in is cut back out.
    //
    // A `finally` runs after its own `try`/`finally` statement is left, so
    // nothing it throws can be caught by a `catch` nested inside that same
    // `try`/`finally`'s `_body` - `finallyIndex < finallyDepthAtStart`
    // below is exactly that nesting test, `finallyDepthAtStart` being how
    // many `try`/`finally`s were already open when this `catch`'s own body
    // started. A `catch` further out, one that itself encloses the whole
    // `try`/`finally` statement, was not yet inside it at that point -
    // `finallyDepthAtStart` is smaller than the hole's own index then, so
    // the hole is left untouched and that `catch` keeps protecting it, the
    // same as a real stack unwind reaching it once the `finally` is done.
    private struct ProtectedRange {
        size_t start;
        size_t end;
    }
    private ProtectedRange[] protectedRanges(
        size_t bodyStart, size_t bodyEnd, size_t finallyDepthAtStart,
    ) {
        import std.algorithm: filter, sort;
        import std.array: array;

        auto holes = _finallyHoles
            .filter!(hole =>
                hole.finallyIndex < finallyDepthAtStart &&
                hole.start >= bodyStart && hole.end <= bodyEnd)
            .array;
        sort!((a, b) => a.start < b.start)(holes);

        ProtectedRange[] ranges;
        size_t cursor = bodyStart;
        foreach (hole; holes) {
            if (hole.start > cursor)
                ranges ~= ProtectedRange(cursor, hole.start);
            if (hole.end > cursor)
                cursor = hole.end;
        }
        if (cursor < bodyEnd)
            ranges ~= ProtectedRange(cursor, bodyEnd);
        return ranges;
    }

    // What a `break` targets: the innermost loop, `switch`, or unrolled
    // `foreach` this compiler is currently inside the body of, or - given
    // a label - whichever of those an enclosing `LabelStatement` names.
    // `pendingBreakJumps` collects every `break` that targets this one,
    // patched once this construct's own compiled code ends.
    private struct Breakable {
        Identifier label;
        size_t[] pendingBreakJumps;
        ScopeFrame[] scopePath;
    }
    private Breakable[] _breakables;

    // A label of a `LabelStatement` this compiler is currently inside,
    // not yet claimed by the loop/`switch`/unrolled `foreach` it labels.
    // dmd does not resolve `break ident`/`continue ident` to a target
    // itself - only `findLoopIndex`/`findBreakableIndex` below do, by
    // identifier - but it does resolve which statement a label names:
    // `_pendingLabelTarget` holds that resolved `Statement` (see
    // `compileLabel`), since a labelled `for` with an init is rewritten
    // to put the label on the generated `ForStatement` alone, not on
    // whatever the init itself also compiles (a `switch`, say).
    private Identifier _pendingLabel;
    private Statement _pendingLabelTarget;

    // The `switch` a `default:` inside its body belongs to - needed only
    // because, unlike `GotoDefaultStatement`, dmd's `DefaultStatement`
    // does not itself carry a pointer back to its own `SwitchStatement`.
    private SwitchStatement[] _switchStack;

    // Where a `CaseStatement` this compiler has already compiled starts -
    // filled in by `recordCaseTarget` the moment that case's own first
    // instruction is known. A `goto case`, or the head of the `switch`
    // itself, reached before that point instead queues its own jump in
    // `_pendingCaseJumps`, resolved once the target is recorded.
    private size_t[CaseStatement] _caseTargets;
    private struct PendingCaseJump {
        size_t instructionIndex;
        CaseStatement case_;
    }
    private PendingCaseJump[] _pendingCaseJumps;

    // As `_caseTargets`/`_pendingCaseJumps`, for a `switch`'s own
    // `default:` - always present by the time this compiler sees a
    // `SwitchStatement`, since dmd itself synthesises one (see
    // `compileSwitch`'s own doc) whenever the source had none.
    private size_t[SwitchStatement] _defaultTargets;
    private struct PendingDefaultJump {
        size_t instructionIndex;
        SwitchStatement switch_;
    }
    private PendingDefaultJump[] _pendingDefaultJumps;
    private size_t[LabelStatement] _labelTargets;
    private struct PendingLabelJump {
        size_t instructionIndex;
        LabelStatement label;
    }
    private PendingLabelJump[] _pendingLabelJumps;
    private LoopContext[] _loops;
    private size_t _destination;
    private size_t _width;
    private Type _valueType;
    // The `$` currently in scope, if any: the `VarDeclaration` dmd hands
    // out for it (`IndexExp.lengthVar`) and where its value - the
    // enclosing array's own length, already evaluated - sits in this
    // frame. The shared storage resolver binds this around compiling an
    // index's own expression and restores whatever was there before once
    // it is done, the same way a nested `$` inside that index (a call's
    // own argument, say) must see its own array's length rather than this
    // one's.
    private VarDeclaration _dollarVariable;
    private size_t _dollarOffset;

    public this(
        Bytecode bytecode,
        FuncDeclaration function_,
        in FrameLayout layout,
        in TypeFacts returnFacts,
        in bool isVoidReturn,
        in bool isRefReturn,
    ) {
        _bytecode = bytecode;
        _function = function_;
        _layout = layout;
        _returnFacts = returnFacts;
        _isVoidReturn = isVoidReturn;
        _isRefReturn = isRefReturn;
        _tempSize = layout.size;
        _tempAlignment = layout.alignment;

        auto closurePlan = closurePlanOf(function_);
        if (closurePlan.needsClosure) {
            _closureLayout = closurePlan.layout;
            _closureOffset = reserveTemp(pointerFacts);
        }
    }

    public Function build(Statement body_) {
        _scopePaths = scopePathsOf(body_);
        compileStatement(body_);

        if (!_finished) {
            if (_isVoidReturn)
                emit(&opReturnVoid, 0, 0, 0);
            else
                emitUnreachableTrap;
        }

        // A `goto case`, or the `switch` itself, jumping to a
        // `CaseStatement` this compiler never reached leaves that jump's
        // target at 0, a valid instruction index - `resolveBranches`
        // below would not catch it. Unpatched, the jump runs at 0 every
        // time, an infinite loop instead of a compile error. A skipped
        // `CaseStatement` is the bug this guards; `reachable` exists to
        // stop it happening in the first place.
        if (_pendingCaseJumps.length != 0)
            assert(0, "every `case` a jump targets was compiled");
        if (_pendingDefaultJumps.length != 0)
            assert(0, "every `default` a jump targets was compiled");

        removeEmptyLifetimes;
        resolveBranches();

        ExceptionHandler[] exceptionHandlers;
        foreach (pending; _exceptionHandlers) {
            if (!(pending._handler < _instructions.length
                    || pending._cleanupEnd != size_t.max))
                assert(0, "a catch handler is followed by the code after "
                    ~ "the statement, or by the function's closing "
                    ~ "instruction");

            exceptionHandlers ~= ExceptionHandler(
                pending._type,
                instructionAt(pending._bodyStart),
                instructionAt(pending._bodyEnd),
                instructionAt(pending._handler),
                pending._catchOffset,
                pending._cleanupEnd == size_t.max
                    ? null : instructionAt(pending._cleanupEnd),
            );
        }

        optimizeStaticLoads;
        fuseReturns;

        foreach (ref site; _callSites)
            if (site.cleanupStartIndex != size_t.max) {
                site.cleanupStart = cast(void*) instructionAt(
                    site.cleanupStartIndex);
                site.cleanupEnd = cast(void*) instructionAt(
                    site.cleanupEndIndex);
            }

        ClosureSlot[] closureSlots;
        if (_closureOffset != size_t.max)
            foreach (variable; _function.closureVars) {
                const slot = _closureLayout.slotOf(variable);
                closureSlots ~= ClosureSlot(
                    _layout.offsetOf(variable), slot.offset, slot.facts.size,
                );
            }

        const contextOffset = _layout.hiddenThis.variable is null
            ? size_t.max : _layout.hiddenThis.parameter.offset;
        size_t[] parameterOffsets;
        foreach (parameter; _layout.parameters)
            parameterOffsets ~= parameter.offset;
        if (_layout.variadicTypes != size_t.max)
            parameterOffsets ~= _layout.variadicTypes;
        if (_layout.variadicCursor != size_t.max)
            parameterOffsets ~= _layout.variadicCursor;
        auto result = Function(
            _instructions, _constants, _callSites, _assertSites,
            exceptionHandlers,
            _tempSize, _tempAlignment,
            _closureOffset, contextOffset,
            _closureOffset == size_t.max ? 0 : _closureLayout.size,
            _closureOffset == size_t.max ? 1 : _closureLayout.alignment,
            closureSlots,
            parameterOffsets,
            _layout.variadicTypes == size_t.max
                ? _layout.variadicCursor : size_t.max,
            _layout.parameters.length,
            _layout.signature,
        );
        return result;
    }

    // dmd normally rejects a non-void function whose end is reachable, but
    // the compiler's own `_finished` tracking is less precise than dmd's.
    // Trap at the end instead of rejecting.
    private void emitUnreachableTrap() {
        import std.string: fromStringz;

        const zero = reserveTemp(pointerFacts);
        emit(&opConstant, zero, addConstant(0), size_t.sizeof);
        _assertSites ~= AssertSite(
            "internal error: control reached the end of a non-void function",
            _function.loc.filename.fromStringz.idup,
            _function.loc.linnum,
        );
        emit(&opAssert, zero, _assertSites.length - 1, size_t.sizeof);
    }

    private const(Instruction)* instructionAt(in size_t index) const {
        return cast(const(Instruction)*) (_instructions.ptr + index);
    }

    private void emit(
        Instruction.Handler handler,
        in size_t destination,
        in size_t source,
        in size_t width,
        in size_t sourceWidth = 0,
    ) {
        if (width == int.sizeof) {
            if (handler is &opDivideSigned)
                handler = &opDivideSigned32;
            else if (handler is &opModuloSigned)
                handler = &opModuloSigned32;
        }
        if (handler is &opCopy) {
            static foreach (size; [1, 2, 4, 8, 16]) {
                if (width == size)
                    handler = &opCopyFixed!size;
            }
        }
        // `narrow`/`widenSigned`/`widenUnsigned`/`toBool` only ever see
        // `width`/`sourceWidth` in `1`/`2`/`4`/`8` - every D integral's
        // own byte count - so this is the same peephole as `opCopy`'s
        // own above, just over both sizes `opCastFixedAs` takes as
        // template parameters instead of reading off the instruction.
        static foreach (kind; [
            CastKind.narrow, CastKind.widenSigned, CastKind.widenUnsigned,
            CastKind.toBool,
        ]) {
            if (handler is &opCastAs!kind) {
                static foreach (destSize; [1UL, 2, 4, 8])
                    static foreach (sourceSize; [1UL, 2, 4, 8])
                        if (width == destSize && sourceWidth == sourceSize)
                            handler =
                                &opCastFixedAs!(kind, destSize, sourceSize);
            }
        }
        _instructions ~= Instruction(
            handler, destination, source, width, sourceWidth);
    }

    private size_t addConstant(in long value) {
        _constants ~= value;
        return _constants.length - 1;
    }

    private void optimizeStaticLoads() {
        foreach (ref instruction; _instructions) {
            if (instruction.handler is &opStaticLoad) {
                static foreach (width; 1 .. 17)
                    if (instruction.width == width)
                        instruction.handler = &opCopyFixed!(width, true);
            }
        }
    }

    private void fuseReturns() {
        import std.meta: AliasSeq;

        foreach (index, ref instruction; _instructions) {
            if (index + 1 == _instructions.length)
                break;
            const next = &_instructions[index + 1];
            if (next.handler !is &opReturn
                    || next.source != instruction.destination
                    || next.width != instruction.width)
                continue;

            // Keep the separate return as a possible branch target. The
            // fused path must still write the producer's destination.
            static foreach (operation; AliasSeq!(
                opConstant, opCopy, opLoadIndirect, opFrameAddress,
                opCopyFixed!1, opCopyFixed!2, opCopyFixed!4,
                opCopyFixed!8, opCopyFixed!16,
            )) {
                if (instruction.handler is &operation)
                    instruction.handler = &opThenReturn!operation;
            }
            static foreach (width; 1 .. 17) {
                if (instruction.handler is &opCopyFixed!(width, true))
                    instruction.handler = &opThenReturn!(
                        opCopyFixed!(width, true));
            }
        }
    }

    // Empty lifetimes have no runtime work. Remove their placeholders
    // before indices become pointers, including exception and cleanup bounds.
    private void removeEmptyLifetimes() {
        auto offsets = new size_t[_instructions.length + 1];
        size_t count;
        foreach (index, instruction; _instructions) {
            offsets[index] = count;
            if (instruction.handler !is null) {
                _instructions[count++] = instruction;
            }
        }
        offsets[$ - 1] = count;
        _instructions.length = count;

        foreach (ref instruction; _instructions) {
            auto target = branchTargetField(instruction);
            if (target !is null)
                *target = offsets[*target];
        }
        foreach (ref handler; _exceptionHandlers) {
            handler._bodyStart = offsets[handler._bodyStart];
            handler._bodyEnd = offsets[handler._bodyEnd];
            handler._handler = offsets[handler._handler];
            if (handler._cleanupEnd != size_t.max)
                handler._cleanupEnd = offsets[handler._cleanupEnd];
        }
        foreach (ref site; _callSites)
            if (site.cleanupStartIndex != size_t.max) {
                site.cleanupStartIndex = offsets[site.cleanupStartIndex];
                site.cleanupEndIndex = offsets[site.cleanupEndIndex];
            }
    }

    // Grows this compiled function's own frame past whatever `_layout`
    // already reserved, for a value only this compiler's own generated
    // code ever reads or writes - a call's argument, a return value on
    // its way to `returnPlace`, an expression's operand. Never reachable
    // through `_layout.offsetOf`, which only ever answers for a declared
    // parameter or local.
    private size_t reserveTemp(in TypeFacts facts) {
        const offset = alignUp(_tempSize, facts.alignment);
        _tempSize = offset + facts.size;
        if (facts.alignment > _tempAlignment)
            _tempAlignment = facts.alignment;

        return offset;
    }

    // Every `opJump`/`opBranchFalse`/`opBranchTrue` this compiler emitted
    // still names its target by a plain instruction index at this point -
    // `compileIf`/`compileFor`/`compileContinue` patch
    // that index in once they know it, but never resolve it to an
    // address themselves, since `_instructions` can still grow (and so
    // move, on a reallocation) at any point before `build` returns. Once
    // it has stopped growing, invalid indices are refused so the VM
    // cannot execute memory outside the function. A cleanup may branch
    // to its exclusive end, even one past the last instruction: the VM
    // stops at that address before it reads an instruction.
    private void resolveBranches() {
        import std.conv: text;

        foreach (index, ref instruction; _instructions) {
            auto target = branchTargetField(instruction);
            if (target is null)
                continue;

            if (!(*target < _instructions.length
                    || (*target == _instructions.length
                        && isCleanupEndBranch(index, *target))))
                assert(0, text("branch target ", *target,
                    " is out of range in `", _function.toString, "`"));

            *target = cast(size_t) instructionAt(*target);
        }
    }

    private bool isCleanupEndBranch(in size_t index, in size_t target) const {
        foreach (handler; _exceptionHandlers)
            if (handler._cleanupEnd == target
                    && index >= handler._handler && index < target)
                return true;

        return false;
    }

    private size_t* branchTargetField(ref Instruction instruction) {
        if (instruction.handler is &opJump)
            return &instruction.destination;

        if (instruction.handler is &opBranchFalse
                || instruction.handler is &opBranchTrue)
            return &instruction.source;

        if (isComparisonBranch(instruction.handler))
            return &instruction.sourceWidth;

        return null;
    }

    private bool isComparisonBranch(Instruction.Handler handler) {
        return handler is &opLessThanSignedBranch
            || handler is &opLessThanUnsignedBranch
            || handler is &opLessOrEqualSignedBranch
            || handler is &opLessOrEqualUnsignedBranch
            || handler is &opGreaterThanSignedBranch
            || handler is &opGreaterThanUnsignedBranch
            || handler is &opGreaterOrEqualSignedBranch
            || handler is &opGreaterOrEqualUnsignedBranch
            || handler is &opEqualBranch
            || handler is &opNotEqualBranch;
    }

    private void compileStatement(Statement statement) {
        if (_finished || statement is null)
            return;

        statement.accept(this);
    }

    // A statement is live in two cases. The one before it fell through.
    // Or a jump from somewhere else can land on it. `_finished` answers
    // the first question. `comeFrom` answers the second: it is true for
    // a `case`, a `default`, a label, or an `asm` block, since each of
    // those is a target dmd itself may jump to from outside this
    // sequence. A `continue` queued from an earlier point of the
    // innermost active loop is the same kind of jump, queued rather than
    // already resolved, so it counts too. dmd's own `blockexit` applies
    // this same rule (`Statement.comeFrom`) to decide what code after an
    // unconditional jump is still reachable. A null `statement` - a
    // `static if` branch with no `else`, elided at semantic time - holds
    // no code and is never a jump target itself, so `comeFrom` is not
    // called on it; `compileStatement` already treats a null statement
    // as a no-op.
    private bool reachable(Statement statement) {
        return !_finished
            || (_loops.length > 0 && _loops[$ - 1].pendingContinueJumps.length > 0)
            || (statement !is null && statement.comeFrom());
    }

    // Skip only the statements this block's own dead code makes
    // unreachable. See `reachable` for the rule; `visit(UnrolledLoopStatement)`
    // uses the same one for the elements of an unrolled `foreach`.
    private void compileStatements(Statements)(Statements* statements) {
        if (statements is null)
            return;

        foreach (child; *statements) {
            if (!reachable(child))
                continue;

            _finished = false;
            compileStatement(child);
        }
    }

    extern(C++):

    override void visit(Statement statement) {
        import std.conv: text;

        assert(0, text("Statement ", statement.stmt,
            ": no `visit` override, and not in `UnreachableNodes`"));
    }

    override void visit(CompoundStatement statement) {
        compileStatements(statement.statements);
    }

    // dmd unrolls a `foreach` over a tuple (an `AliasSeq`, `static
    // foreach`'s own arguments) into one statement per element at
    // semantic time - see `makeTupleForeach` in `statementsem.d` - so
    // there is no run time loop left to compile, only this fixed sequence
    // of already-distinct statements. A `continue` there still needs a
    // real jump, the same as `compileFor`'s: it must skip only the rest
    // of the current element, landing on the next element's own first
    // instruction (or, from the last element, after the whole
    // statement) rather than falling into whatever the current element
    // was itself about to skip (an `else`, a `catch` handler, the next
    // `case`).
    //
    // The elements run in sequence, like the statements of a block. Once
    // one element ends every path, every element after it is dead code
    // (see `reachable`). Two things keep a later element live anyway. A
    // `continue` from an earlier element can land on it. A jump from
    // outside the whole sequence can land inside it: a `case` of the
    // enclosing `switch`, or a `goto`. dmd's `blockexit` applies the same
    // rule to this statement.
    override void visit(UnrolledLoopStatement statement) {
        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        if (statement.statements is null) {
            _finished = false;
            return;
        }

        _loops ~= LoopContext(label, size_t.max, null, _scopePaths.enclosing(statement));
        _breakables ~= Breakable(label, null, _scopePaths.enclosing(statement));

        _finished = false;
        foreach (child; *statement.statements) {
            // A dead element is skipped, not stopped at: a later
            // element can still be live (see `reachable`) even when
            // this one is not.
            if (!reachable(child))
                continue;

            resolveContinues(_instructions.length);
            _finished = false;
            compileStatement(child);
        }
        const hadContinue = _loops[$ - 1].pendingContinueJumps.length > 0;
        resolveContinues(_instructions.length);

        const breakable = _breakables[$ - 1];
        _breakables = _breakables[0 .. $ - 1];
        _loops = _loops[0 .. $ - 1];

        const afterLoop = _instructions.length;
        foreach (index; breakable.pendingBreakJumps)
            patchTarget(index, afterLoop);

        _finished = _finished && !hadContinue
            && breakable.pendingBreakJumps.length == 0;
    }

    // `do`-`while` always runs its own body once before the condition is
    // ever checked, so - unlike `compileFor` - there is no upfront branch
    // to skip the body with, only a trailing one that decides whether to
    // run it again. `continue` still needs a target distinct from that
    // trailing branch itself: the spec sends it to the condition check,
    // not back to the body's own start, so a `continue` reached before
    // the condition is compiled queues its own jump the same way
    // `compileFor`'s does for its increment.
    override void visit(DoStatement statement) {
        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        const bodyStart = _instructions.length;

        _loops ~= LoopContext(label, size_t.max, null, _scopePaths.enclosing(statement));
        _breakables ~= Breakable(label, null, _scopePaths.enclosing(statement));
        compileStatement(statement._body);
        const bodyFinished = _finished;
        const breakable = _breakables[$ - 1];
        _breakables = _breakables[0 .. $ - 1];
        const hadContinue = _loops[$ - 1].pendingContinueJumps.length > 0;
        _finished = false;

        const conditionIndex = _instructions.length;
        resolveContinues(conditionIndex);
        _loops = _loops[0 .. $ - 1];

        // See `compileFor`'s own doc for why a trivially-true condition
        // is never guarded - here that means the trailing check becomes
        // an unconditional jump back to the body instead of a real test.
        const guarded = !isTriviallyTrueCondition(statement.condition);
        if (guarded) {
            const conditionOffset = compileCondition(statement.condition);
            const width = conditionWidth(statement.condition);
            emit(&opBranchTrue, conditionOffset, bodyStart, width);
        } else {
            emit(&opJump, bodyStart, 0, 0);
        }

        const afterLoop = _instructions.length;
        foreach (index; breakable.pendingBreakJumps)
            patchTarget(index, afterLoop);

        // A body that returns on every path, with nothing left to
        // `continue` past it, never reaches the condition at all - the
        // whole loop is then finished the same way the body is, the
        // condition's own instructions being dead code nothing jumps
        // into.
        const hadBreak = breakable.pendingBreakJumps.length > 0;
        _finished = !hadBreak && (bodyFinished && !hadContinue || !guarded);
    }

    // `gotoTarget` is unset when dmd did not need to rewrite the labelled
    // statement, so the label names `statement.statement` itself then.
    override void visit(LabelStatement statement) {
        const target = _instructions.length;
        _labelTargets[statement] = target;
        size_t remaining;
        foreach (pending; _pendingLabelJumps)
            if (pending.label is statement)
                patchTarget(pending.instructionIndex, target);
            else
                _pendingLabelJumps[remaining++] = pending;
        _pendingLabelJumps = _pendingLabelJumps[0 .. remaining];

        auto outerLabel = _pendingLabel; // auto: const(Identifier) will not implicitly convert back
        auto outerTarget = _pendingLabelTarget;
        _pendingLabel = statement.ident;
        _pendingLabelTarget = statement.gotoTarget !is null
            ? statement.gotoTarget : statement.statement;
        compileStatement(statement.statement);
        _pendingLabel = outerLabel;
        _pendingLabelTarget = outerTarget;
    }

    override void visit(ScopeStatement statement) {
        compileStatement(statement.statement);
    }

    override void visit(ImportStatement statement) {
    }

    // Semantic analysis resolves every member access in a `with` body
    // through its compiler-generated `wthis` temporary, the same way the
    // interpreter's own `visit(WithStatement)` describes: initialise that
    // temporary once, then compile the body as-is - the body's own
    // `DotVarExp`/`PtrExp` nodes already name `wthis` directly, needing no
    // support beyond what a hand-written pointer-typed local already gets.
    // `with (Scope)` and `with (EnumType)` leave `wthis` null: they only
    // change name lookup, which semantic analysis already resolved, so
    // only the body needs compiling.
    override void visit(WithStatement statement) {
        if (statement.wthis !is null)
            compileVariableInitializer(statement.wthis);

        if (statement._body !is null)
            compileStatement(statement._body);
    }

    // Statement semantic rewrites a scope guard in a compound or scope
    // statement. A scope guard that is a whole `catch` handler stays, and
    // dmd's glue generates no code for it.
    override void visit(ScopeGuardStatement statement) {
    }

    override void visit(TryCatchStatement statement) {
        // DMD AST nodes stay mutable through this plan for code generation.
        auto plan = catchPlanOf(
            statement,
            catch_ => _bytecode._runtimeTypes.unqualifiedClassInfo(catch_.type),
        );
        const finallyDepthAtStart = _pendingFinallyBodies.length;
        const bodyStart = _instructions.length;
        compileStatement(statement._body);
        const bodyFinished = _finished;
        const bodyEnd = _instructions.length;

        size_t skipHandlers = size_t.max;
        if (!bodyFinished) {
            skipHandlers = _instructions.length;
            emit(&opJump, 0, 0, 0);
        }

        bool allHandlersFinished = true;
        // A handler that falls off its own end (no `return`/`throw`/...)
        // would otherwise run straight into the next catch clause's own
        // instructions - the compiled catches sit back to back in the
        // instruction stream, with nothing between them but this jump.
        // The last handler needs none: whatever follows the whole
        // statement already sits right after it.
        size_t[] skipRemainingHandlers;
        const catchCount = plan.clauses.length;
        foreach (i, clause; plan.clauses) {
            auto catch_ = clause.syntax;
            const handler = _instructions.length;
            const catchOffset = catch_.var is null
                ? size_t.max
                : _layout.offsetOf(catch_.var);
            foreach (range; protectedRanges(bodyStart, bodyEnd, finallyDepthAtStart))
                _exceptionHandlers ~= PendingExceptionHandler(
                    clause.type, range.start, range.end, handler, catchOffset,
                );

            _finished = false;
            // The VM stores the exception into the frame slot; a captured
            // variable reads from its closure slot instead.
            if (catch_.var !is null && isClosureVariable(catch_.var)) {
                const slot = _closureLayout.slotOf(catch_.var);
                emit(&opStoreIndirect, closureSlotAddress(slot.offset),
                    catchOffset, size_t.sizeof);
            }
            compileStatement(catch_.handler);
            allHandlersFinished &= _finished;

            if (!_finished && i + 1 != catchCount) {
                skipRemainingHandlers ~= _instructions.length;
                emit(&opJump, 0, 0, 0);
            }
        }

        const afterHandlers = _instructions.length;
        if (skipHandlers != size_t.max)
            _instructions[skipHandlers].destination = afterHandlers;
        foreach (index; skipRemainingHandlers)
            _instructions[index].destination = afterHandlers;

        _finished = bodyFinished && allHandlersFinished;
    }

    override void visit(TryFinallyStatement statement) {
        _pendingFinallyBodies ~= statement.finalbody;
        const finallyDepth = _pendingFinallyBodies.length;
        const bodyStart = _instructions.length;
        compileStatement(statement._body);
        const bodyEnd = _instructions.length;
        const bodyFinished = _finished;
        _pendingFinallyBodies.length -= 1;

        // Exceptional entry runs this range inside native try/finally so
        // druntime owns exception chaining and Error precedence.
        const handler = _instructions.length;
        _finished = false;
        compileFinallyBody(statement.finalbody);
        const cleanupFinished = _finished;
        const cleanupEnd = _instructions.length;
        foreach (range; protectedRanges(bodyStart, bodyEnd, finallyDepth))
            _exceptionHandlers ~= PendingExceptionHandler(
                typeid(Throwable), range.start, range.end, handler,
                size_t.max, cleanupEnd,
            );
        _finished = bodyFinished || cleanupFinished;
    }

    protected override void visitReturnOperand(ReturnStatement statement) {
        // A `void` return's own expression, when it has one, is only the
        // synthetic `0` dmd appends to `main` - nowhere to write it, so it
        // is discarded the same way the interpreter discards it.
        if (_isVoidReturn || statement.exp is null)
            return;

        if (_isRefReturn) {
            _returnOffset = compileAddress(statement.exp);
            return;
        }

        // The return value is computed before any enclosing `finally`
        // runs, exactly as a compiled `return` inside a `try` does: the
        // finally can go on to use its own temporaries without disturbing
        // the value already on its way out.
        _returnOffset = reserveTemp(_returnFacts);
        compileValue(statement.exp, _returnOffset, _returnFacts.size);
    }

    protected override void visitReturnTransfer(ReturnStatement statement) {
        const returnOffset = _returnOffset;
        runPendingFinallyBodies(unwindPlanOf(
            _scopePaths.enclosing(statement)));
        if (_finished)
            return;

        if (_isVoidReturn || statement.exp is null)
            emit(&opReturnVoid, 0, 0, 0);
        else
            emit(
                &opReturn, 0, returnOffset,
                _isRefReturn ? size_t.sizeof : _returnFacts.size,
            );
        _finished = true;
    }

    protected override void visitThrowStatement(ThrowStatement statement) {
        compileThrow(statement.exp);
    }

    protected override void visitThrowExp(ThrowExp expression) {
        compileThrow(expression.e1);
    }

    private void compileThrow(Expression expression) {
        import dmd.astenums: Tclass;

        if (!(expression !is null
                && expression.type.toBasetype.ty == Tclass))
            assert(0,
                "`throwSemantic` only accepts a `Throwable` class reference");

        const facts = TypeFacts.of(expression.type);
        const offset = reserveTemp(facts);
        evalInto(expression, offset, facts.size);
        emit(&opThrow, offset, 0, 0, 0);
        _finished = true;
    }

    override void visit(ExpStatement statement) {
        if (statement.exp !is null)
            compileEffect(statement.exp);
    }

    override void visit(IfStatement statement) {
        compileIf(statement);
    }

    override void visit(ForStatement statement) {
        compileFor(statement);
    }

    override void visit(ContinueStatement statement) {
        compileContinue(statement);
    }

    // A `switch` on a string is fully gone by the time this compiler ever
    // sees the `SwitchStatement`: dmd's own semantic pass rewrites
    // `condition` into a call to druntime's `object.__switch`, which
    // returns the matching case's index as a plain `int`, and rewrites
    // every `case` expression into that same index - see
    // `visitSwitch`/`visitCase` in dmd's `statementsem.d`. That call
    // compiles through the ordinary `CallExp` path below like any other
    // native call, so nothing here treats a string `switch` differently
    // from an integral one. A `CaseRangeStatement` is gone the same way,
    // replaced by one `CaseStatement` per value in the range, chained by
    // fallthrough - this compiler never sees that node either.
    //
    // dmd also always resolves `hasDefault`/`sdefault` before semantic
    // returns: a `switch` with no `default:` of its own gets one
    // synthesised (an `assert(0)`, or a call to `object.__switch_error`),
    // so `statement.sdefault` is never null here, final or not.
    //
    // Case dispatch is a linear chain of equality tests against the
    // already-evaluated condition, each branching straight into its own
    // case's body once that body's own position is known (see
    // `recordCaseTarget`) - no jump table, since nothing about this
    // compiler's `Instruction` stream supports one.
    override void visit(SwitchStatement statement) {
        import snakebite.nativelayout: TypeFacts;

        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        auto plan = switchPlan(statement);
        const facts = TypeFacts.of(statement.condition.type);
        assert(facts.isIntegral && isIntegralSize(facts.size));

        const conditionOffset = reserveTemp(facts);
        compileValue(statement.condition, conditionOffset, facts.size);

        foreach (case_; plan.cases) {
            const testOffset = reserveTemp(facts);
            emit(&opCopy, testOffset, conditionOffset, facts.size);
            const literalOffset = reserveTemp(facts);
            compileValue(case_.exp, literalOffset, facts.size);
            emit(&opEqual, testOffset, literalOffset, facts.size);

            const branchIndex = _instructions.length;
            emit(&opBranchTrue, testOffset, 0, 1);
            jumpToCase(case_, branchIndex);
        }

        assert(plan.defaultTarget !is null);

        const defaultJumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);
        jumpToDefault(statement, defaultJumpIndex);

        _breakables ~= Breakable(label, null, _scopePaths.enclosing(statement));
        _switchStack ~= statement;
        compileSwitchBody(statement._body);
        const bodyFinished = _finished;
        const hadBreak = _breakables[$ - 1].pendingBreakJumps.length > 0;

        const afterSwitch = _instructions.length;
        foreach (index; _breakables[$ - 1].pendingBreakJumps)
            patchTarget(index, afterSwitch);

        _switchStack = _switchStack[0 .. $ - 1];
        _breakables = _breakables[0 .. $ - 1];

        // A `goto case`/`goto default` can only name a case of the
        // `switch` it sits in, so every jump to one of this switch's
        // cases is resolved by now. Forget the targets recorded for
        // this switch so a second compile of the same AST (a `finally`
        // inlined at a `return` and again at its own fall-through, say)
        // records its own targets instead of jumping into this copy's
        // bodies.
        if (statement.cases !is null)
            foreach (case_; *statement.cases)
                _caseTargets.remove(case_);
        _defaultTargets.remove(statement);

        _finished = !hadBreak && bodyFinished;
    }

    override void visit(CaseStatement statement) {
        recordCaseTarget(statement);
        _finished = false;
        compileSwitchBody(statement.statement);
    }

    override void visit(DefaultStatement statement) {
        if (_switchStack.length == 0)
            assert(0, "`visitDefault` rejects a `default` outside a `switch`");

        recordDefaultTarget(_switchStack[$ - 1]);
        _finished = false;
        compileSwitchBody(statement.statement);
    }

    override void visit(GotoCaseStatement statement) {
        auto target = gotoCaseTarget(statement);
        assert(target !is null);

        // Finalizer bodies stay mutable DMD statements for code generation.
        auto unwind = unwindPlanOf(
            _scopePaths.enclosing(statement),
            _scopePaths.enclosing(target),
        );
        runPendingFinallyBodies(unwind);

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        jumpToCase(target, index);
        _finished = true;
    }

    override void visit(GotoDefaultStatement statement) {
        auto target = gotoDefaultTarget(statement);
        assert(statement.sw !is null && target !is null);
        auto plan = switchPlan(statement.sw);
        assert(target is plan.defaultTarget);

        // Finalizer bodies stay mutable DMD statements for code generation.
        auto unwind = unwindPlanOf(
            _scopePaths.enclosing(statement),
            _scopePaths.enclosing(target),
        );
        runPendingFinallyBodies(unwind);

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        jumpToDefault(statement.sw, index);
        _finished = true;
    }

    override void visit(GotoStatement statement) {
        if (!(statement.label !is null && statement.label.statement !is null))
            assert(0, "semantic3 rejects a `goto` to an undefined label");

        auto target = statement.label.statement;
        // Finalizer bodies stay mutable DMD statements for code generation.
        auto unwind = unwindPlanOf(
            _scopePaths.enclosing(statement),
            _scopePaths.enclosing(target),
        );
        runPendingFinallyBodies(unwind);
        if (_finished)
            return;

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        if (auto known = target in _labelTargets)
            patchTarget(index, *known);
        else
            _pendingLabelJumps ~= PendingLabelJump(index, target);

        // A goto only leaves the path that reaches it. Other paths still
        // fall through to the statements after it, including its target.
    }

    // dmd's own synthesised "no case matched" default (see
    // `visit(SwitchStatement)`'s own doc) wraps a call to
    // `object.__switch_error` already resolved to a real
    // `FuncDeclaration` - compiled the same way any other call to a
    // function this compiler did not itself compile is, through the
    // native FFI boundary in `compileCall`.
    override void visit(SwitchErrorStatement statement) {
        if (statement.exp is null)
            assert(0, "dmd always gives a `SwitchErrorStatement` its "
                ~ "`__switch_error` call");
        compileEffect(statement.exp);

        _finished = true;
    }

    override void visit(BreakStatement statement) {
        if (_breakables.length == 0)
            assert(0,
                "`visitBreak` rejects a `break` outside a loop or `switch`");

        const target = findBreakableIndex(statement.ident);
        if (target == size_t.max)
            assert(0, "`visitBreak` rejects a `break` to an unknown label");

        runPendingFinallyBodies(unwindPlanOf(
            _scopePaths.enclosing(statement), _breakables[target].scopePath,
        ));
        if (_finished)
            return;

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        _breakables[target].pendingBreakJumps ~= index;
        _finished = true;
    }

    extern(D):

    // Each exit emits the shared scope plan's cleanup sequence. Temporarily
    // leave each pending `finally` before compiling it: a `return` inside
    // that cleanup must not run the `finally` it is already in.
    private void runPendingFinallyBodies(UnwindPlan plan) {
        if (plan.finalizers.length == 0)
            return;

        auto bodies = _pendingFinallyBodies.dup; // Restored to mutable compiler state.
        scope (exit)
            _pendingFinallyBodies = bodies;
        foreach (offset, finalizer; plan.finalizers) {
            const index = bodies.length - offset - 1;
            assert(bodies[index] is finalizer.body);
            _pendingFinallyBodies = bodies[0 .. index].dup;
            const start = _instructions.length;
            compileFinallyBody(finalizer.body);
            _finallyHoles ~= FinallyHole(start, _instructions.length, index);
            if (_finished)
                return;
        }
    }

    private void compileFinallyBody(Statement body_) {
        // D forbids transfers across a finally boundary. Each emitted copy
        // therefore owns its labels, independent of the surrounding code.
        auto targets = _labelTargets; // Restored to mutable compiler state.
        auto pending = _pendingLabelJumps; // Restored to mutable compiler state.
        _labelTargets = null;
        _pendingLabelJumps = null;
        scope (exit) {
            _labelTargets = targets;
            _pendingLabelJumps = pending;
        }
        compileStatement(body_);
    }

    // The condition of an `if`, a `while`/`for`, or a ternary: read at its
    // own type's width, not necessarily `bool` - `if (one())`, `one()`
    // returning `int`, is truthy exactly when its low bytes are nonzero,
    // the same test `opBranchFalse`/`opBranchTrue` already make of
    // whatever width they are handed.
    //
    // `TypeFacts.Truth` decides which bytes of the compiled-in value
    // those are - the whole value for a pointer, a class reference, an
    // associative array's handle, or an integral; only the pointer word
    // for a dynamic array (a zero-length array over real storage is
    // still `true`); both words, combined here with one `opBitOr`, for a
    // delegate (`ptr !is null || funcptr !is null`) - so this backend
    // carries no case of its own for any of them; `conditionWidth` below
    // reports that same shared width back to this method's callers.
    private size_t compileCondition(Expression condition) {
        import snakebite.nativelayout: TypeFacts;

        const truth = TypeFacts.Truth.of(condition.type);

        const facts = TypeFacts.of(condition.type);
        const valueOffset = reserveTemp(facts);
        compileValue(condition, valueOffset, facts.size);
        const offset = valueOffset + truth.offset;

        if (truth.isFloat) {
            emit(&opFloatToBool, offset, offset, truth.size);
            // A complex condition's second word is its own component,
            // not an integral one `opBitOr` alone could combine
            // straight - `re != 0 || im != 0`, each tested the same way
            // `truth.offset`'s own word just was, before the two 1-byte
            // answers are combined.
            if (truth.secondOffset != TypeFacts.Truth.noSecondWord) {
                const secondOffset = valueOffset + truth.secondOffset;
                emit(&opFloatToBool, secondOffset, secondOffset, truth.size);
                emit(&opBitOr, offset, secondOffset, bool.sizeof);
            }
            return offset;
        }

        if (truth.secondOffset != TypeFacts.Truth.noSecondWord)
            emit(&opBitOr, offset, valueOffset + truth.secondOffset,
                truth.size);

        return offset;
    }

    // Emits one integral comparison and its false branch. This path is only
    // used when the comparison result is consumed by an enclosing statement;
    // value-producing comparisons keep the existing lowering.
    private size_t compileIntegralComparisonBranch(
        BinExp expression,
    ) {
        const facts = TypeFacts.of(expression.e1.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            return size_t.max;

        auto handler = comparisonBranchHandler(
            expression, facts.isUnsigned);
        if (handler is null)
            return size_t.max;
        const leftOffset = reserveTemp(facts);
        const rightOffset = reserveTemp(facts);
        withFullExpression(FullExpressionKind.value, expression, {
            evalInto(expression.e1, leftOffset, facts.size);
            evalInto(expression.e2, rightOffset, facts.size);
        });
        const index = _instructions.length;
        emit(handler, leftOffset, rightOffset, facts.size, 0);
        return index;
    }

    private size_t compileConditionBranch(Expression condition) {
        auto comparison = condition.isBinExp;
        const comparisonIndex = comparison is null
            ? size_t.max : compileIntegralComparisonBranch(comparison);
        if (comparisonIndex != size_t.max)
            return comparisonIndex;

        const offset = compileCondition(condition);
        const index = _instructions.length;
        emit(&opBranchFalse, offset, 0, conditionWidth(condition));
        return index;
    }

    private Instruction.Handler comparisonBranchHandler(
        BinExp expression, in bool unsigned,
    ) {
        import dmd.tokens: EXP;

        with (EXP) switch (expression.op) {
            case lessThan:
                return unsigned
                    ? &opLessThanUnsignedBranch : &opLessThanSignedBranch;
            case lessOrEqual:
                return unsigned
                    ? &opLessOrEqualUnsignedBranch
                    : &opLessOrEqualSignedBranch;
            case greaterThan:
                return unsigned
                    ? &opGreaterThanUnsignedBranch
                    : &opGreaterThanSignedBranch;
            case greaterOrEqual:
                return unsigned
                    ? &opGreaterOrEqualUnsignedBranch
                    : &opGreaterOrEqualSignedBranch;
            case equal:
                return &opEqualBranch;
            case notEqual:
                return &opNotEqualBranch;
            default:
                return null;
        }
    }

    private size_t conditionWidth(Expression condition) {
        import snakebite.nativelayout: TypeFacts;

        const truth = TypeFacts.Truth.of(condition.type);
        // `opFloatToBool` (in `compileCondition`) always writes a 1-byte
        // `bool` at its destination, whatever the floating source's own
        // width was.
        return truth.isFloat ? bool.sizeof : truth.size;
    }

    // `assert(cond)`: evaluated the same way an `if`'s own condition is,
    // then handed to `opAssert`, which throws a real `AssertError` at run
    // time when it is false and otherwise falls through - the only two
    // things D's own assertion semantics call for.
    //
    private void compileAssert(AssertExp expression) {
        import dmd.astenums: Tnoreturn;
        import dmd.typesem: toBasetype;
        import snakebite.backends.checkplan:
            assertPlanOf, FailurePlan, isUnanalysed;
        import snakebite.backends.exceptions: assertFailureOf;

        const plan = assertPlanOf(_bytecode.checks);
        if (plan.kind == FailurePlan.Kind.ignore)
            return;

        const conditionOffset = compileCondition(expression.e1);
        const width = conditionWidth(expression.e1);
        const never = isUnanalysed(expression)
            || expression.type.toBasetype.ty == Tnoreturn;

        final switch (plan.kind) with (FailurePlan.Kind) {
            case ignore:
                assert(0);
            case halt:
                emit(&opAssert, conditionOffset, haltSite, width);
                break;
            case cAssert:
                compileUnlessHolds(conditionOffset, width, never,
                    () => compileCAssert(expression));
                break;
            case raise:
                // `auto`: dmd's nodes are not `const`, and
                // `messageExpression` would be if `failure` were.
                auto failure = assertFailureOf(expression, _function);
                if (failure.messageExpression is null) {
                    _assertSites ~= AssertSite(
                        failure.message, failure.file, failure.line);
                    emit(&opAssert, conditionOffset,
                        _assertSites.length - 1, width);
                } else
                    compileUnlessHolds(conditionOffset, width, never,
                        () => compileAssertMessage(expression, failure));
                break;
        }
        _finished = never;

        if (!_finished)
            compileAssertInvariant(expression, conditionOffset);
    }

    // The one `AssertSite` a function needs for every halt: a halt reports
    // nothing.
    private size_t haltSite() {
        if (_haltSite == size_t.max) {
            _assertSites ~= AssertSite("", "", 0, _bytecode.haltAction);
            _haltSite = _assertSites.length - 1;
        }

        return _haltSite;
    }

    // Runs `failure` unless the `width` bytes at `conditionOffset` are
    // nonzero. `never` says that they are known to be zero, so that there
    // is nothing to branch over.
    private void compileUnlessHolds(
        in size_t conditionOffset,
        in size_t width,
        in bool never,
        scope void delegate() failure,
    ) {
        if (never) {
            failure();
            return;
        }

        const branchIndex = _instructions.length;
        emit(&opBranchTrue, conditionOffset, 0, width);
        failure();
        *branchTargetField(_instructions[branchIndex]) = _instructions.length;
    }

    // `assert(c, m())`: druntime's own `_d_assert_msg` builds and throws the
    // `AssertError`, once the message has run.
    private void compileAssertMessage(
        AssertExp expression, AssertFailure failure,
    ) {
        import core.stdc.string: strlen;
        import snakebite.backends.druntimehooks: DruntimeHook, planOf;
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        const message = compileMessage(failure.messageExpression);
        const file = expression.loc.filename;
        Arg[] args = [
            Arg(message + arrayLengthOffset, 0, size_t.sizeof),
            Arg(message + arrayPointerOffset, 0, size_t.sizeof),
            constantArgument(strlen(file), size_t.sizeof),
            constantArgument(cast(size_t) file, size_t.sizeof),
            constantArgument(expression.loc.linnum, uint.sizeof),
        ];
        auto plan = planOf(_bytecode._plans, DruntimeHook.assertMessage);
        _callSites ~= CallSite.native(cast(const(void)*) plan, args, 0);
        emit(&opCall, discardResult, _callSites.length - 1, 0);
    }

    // `-checkaction=C`: the C runtime aborts the process.
    private void compileCAssert(AssertExp expression) {
        import snakebite.backends.exceptions:
            cAssertCallOf, cAssertionOf, messageExpressionOf;
        import snakebite.nativelayout: arrayPointerOffset;

        auto messageExpression = messageExpressionOf(expression);
        if (messageExpression is null) {
            const call = cAssertCallOf(
                cAssertionOf(expression), expression.loc, _function);
            compileCAssertCall(call, constantArgument(
                cast(size_t) call.assertion, size_t.sizeof));
        } else {
            const call = cAssertCallOf(null, expression.loc, _function);
            const message = compileMessage(messageExpression);
            compileCAssertCall(call, Arg(
                message + arrayPointerOffset, 0, size_t.sizeof));
        }
    }

    private void compileCAssertCall(in CAssertCall call, in Arg assertion) {
        import snakebite.backends.druntimehooks: DruntimeHook, planOf;

        Arg[] args = [
            assertion,
            constantArgument(cast(size_t) call.file, size_t.sizeof),
            constantArgument(call.line, uint.sizeof),
            constantArgument(cast(size_t) call.function_, size_t.sizeof),
        ];
        auto plan = planOf(_bytecode._plans, DruntimeHook.cAssertFail);
        _callSites ~= CallSite.native(cast(const(void)*) plan, args, 0);
        emit(&opCall, discardResult, _callSites.length - 1, 0);
    }

    // The message of a failed assertion runs only then.
    private size_t compileMessage(Expression message) {
        const facts = TypeFacts.of(message.type);
        const offset = reserveTemp(facts);
        evalInto(message, offset, facts.size);
        return offset;
    }

    private Arg constantArgument(in size_t value, in size_t width) {
        const offset = reserveTemp(pointerFacts);
        emit(&opConstant, offset, addConstant(cast(long) value), width);
        return Arg(offset, 0, width);
    }

    // `assert(e1)`'s own invariant call, reached only once `opAssert` above
    // already let the condition through: `objectOffset` already holds
    // `e1`'s own value - the class reference or struct pointer itself, not
    // merely its truthiness, since `compileCondition` reads a class
    // reference's or a pointer's own whole width to decide that
    // truthiness in the first place - so it is reused here rather than
    // compiling `e1` a second time, the same "evaluate once, reuse the
    // same compiler temporary for both the condition and the invariant"
    // dmd's own glue layer (`e2ir.d`'s `visitAssert`) does. `assert(0)`
    // (`_finished`, this method's one caller already having returned by
    // then) never reaches here: its own condition is never one of the two
    // shapes `assertInvariantPlanOf` recognises anyway.
    private void compileAssertInvariant(
        AssertExp expression, in size_t objectOffset,
    ) {
        import snakebite.backends.exceptions:
            AssertInvariantPlan, assertInvariantPlanOf;

        auto plan = assertInvariantPlanOf(expression, _bytecode.checks);
        final switch (plan.kind) with (AssertInvariantPlan.Kind) {
            case none:
                return;
            case class_:
                compileClassInvariantCall(objectOffset);
                return;
            case struct_:
                compileResolvedCall(plan.structInvariant, null,
                    expression.loc, expressionText(expression), true,
                    () => objectOffset, discardResult);
                return;
        }
    }

    // A class reference's own invariant is druntime's job, not this
    // project's: `_d_invariant` (`rt.invariant_`) walks every base class's
    // own invariant in turn, reached the same way `visit(DeleteExp)`
    // already reaches `_d_callfinalizer` - a druntime hook with no
    // `FuncDeclaration` of its own, resolved purely by its linker symbol
    // through the FFI barrier - and called here with the object reference
    // as its one argument.
    private void compileClassInvariantCall(
        in size_t objectOffset,
    ) {
        auto plan = planOf(_bytecode._plans, DruntimeHook.classInvariant);

        _callSites ~= CallSite.native(
            plan, [Arg(objectOffset, 0, size_t.sizeof)], 0);
        emit(&opCall, discardResult, _callSites.length - 1, 0);
    }

    // Only the branch taken at run time ever executes - the other one, if
    // there is one, does not even get instructions emitted for it that
    // never run, the same way an untaken `if` skips them at run time in
    // the interpreter. Finished (see `_finished`'s own doc) only when
    // there is an `else` and both branches are.
    private void compileIf(IfStatement statement) {
        // dmd's own glue (`s2ir.d`) never emits the true body of an
        // `if (__ctfe) { ... }` block: `Scope.ctfeBlock` is set only for
        // this exact shape, and its only effect is to leave statements
        // in the body unlowered (e.g. a `.length` assign keeps no
        // `_d_arraysetlengthT` call) because dmd's CTFE engine interprets
        // the body directly instead. At run time the `if` never enters the
        // body, but a `case` or `default` label in it is still a target
        // for the `switch` that holds it, so such a body is compiled
        // behind a jump. dmd rejects a `goto` to any other label in it.
        if (statement.isIfCtfeBlock) {
            if (statement.ifbody !is null && statement.ifbody.comeFrom)
                return compileCtfeBlockWithLabels(statement);

            if (statement.elsebody !is null)
                compileStatement(statement.elsebody);
            return;
        }

        const branchIndex = compileConditionBranch(statement.condition);

        compileStatement(statement.ifbody);
        const ifFinished = _finished;

        if (statement.elsebody is null) {
            *branchTargetField(_instructions[branchIndex]) =
                _instructions.length;
            _finished = false;
            return;
        }

        _finished = false;
        // Skipped when the `if` branch already ended in a `return`/
        // `continue`: nothing would ever reach this jump, so emitting it
        // would leave a dead instruction whose target - one past the
        // `else` branch's own last instruction - does not exist at all
        // when the `else` branch also always ends its own path, since
        // then nothing follows this whole `if` either and `build` never
        // appends a trailing instruction for it to land on.
        size_t jumpIndex = size_t.max;
        if (!ifFinished) {
            jumpIndex = _instructions.length;
            emit(&opJump, 0, 0, 0);
        }
        *branchTargetField(_instructions[branchIndex]) =
            _instructions.length;

        compileStatement(statement.elsebody);
        const elseFinished = _finished;
        if (jumpIndex != size_t.max)
            _instructions[jumpIndex].destination = _instructions.length;

        _finished = ifFinished && elseFinished;
    }

    private void compileCtfeBlockWithLabels(IfStatement statement) {
        const skipIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);

        _finished = false;
        compileStatement(statement.ifbody);
        const bodyFinished = _finished;

        size_t endIndex = size_t.max;
        if (statement.elsebody !is null && !bodyFinished) {
            endIndex = _instructions.length;
            emit(&opJump, 0, 0, 0);
        }
        patchTarget(skipIndex, _instructions.length);

        _finished = false;
        if (statement.elsebody !is null)
            compileStatement(statement.elsebody);
        const elseFinished = _finished;

        if (endIndex != size_t.max)
            patchTarget(endIndex, _instructions.length);

        _finished = bodyFinished && statement.elsebody !is null && elseFinished;
    }

    // A condition that is a nonzero literal - `1`, in place of `true`,
    // dmd's own way of spelling an infinite `for`/`while` - is always
    // taken, so a loop headed by one, or by no condition at all
    // (`for (;;)`), never falls out of its own bottom the way one whose
    // condition can become false does.
    private bool isTriviallyTrueCondition(Expression condition) {
        if (condition is null)
            return true;

        auto integer = condition.isIntegerExp;
        return integer !is null && integer.toInteger != 0;
    }

    // Claims the pending label only when `statement` is what dmd resolved
    // it to, not merely the first breakable construct compiled while one
    // is pending.
    private Identifier consumeLabel(Statement statement) {
        if (_pendingLabelTarget !is statement)
            return null;

        auto label = _pendingLabel;
        _pendingLabel = null;
        _pendingLabelTarget = null;
        return label;
    }

    private void compileFor(ForStatement statement) {
        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        if (statement._init !is null)
            compileStatement(statement._init);

        // A condition that can never be false - `while (1)`, always
        // rewritten by dmd to a `for` (see `visitWhile` in
        // `statementsem.d`), or a bare `for (;;)` - is never guarded: the
        // check itself would still compile correctly, but its false
        // branch would then target the position right after this loop's
        // own last instruction, which exists only when something follows
        // the loop in source. Nothing does when a trivially-true loop is
        // a function's own last statement (its body returns
        // unconditionally instead), and a branch aimed one past the last
        // instruction is exactly what `resolveBranches` exists to catch.
        // A `break` inside such a loop still lands somewhere real:
        // `build` appends a trailing `opReturnVoid` at that exact
        // position whenever nothing else already made it reachable.
        const guarded = statement.condition !is null
            && !isTriviallyTrueCondition(statement.condition);
        const conditionIndex = _instructions.length;
        size_t branchIndex = size_t.max;
        if (guarded)
            branchIndex = compileConditionBranch(statement.condition);

        _loops ~= LoopContext(label, size_t.max, null, _scopePaths.enclosing(statement));
        _breakables ~= Breakable(label, null, _scopePaths.enclosing(statement));
        compileStatement(statement._body);
        const breakable = _breakables[$ - 1];
        _breakables = _breakables[0 .. $ - 1];
        _finished = false;

        const incrementIndex = _instructions.length;
        resolveContinues(incrementIndex);
        _loops = _loops[0 .. $ - 1];

        if (statement.increment !is null)
            compileEffect(statement.increment);

        emit(&opJump, conditionIndex, 0, 0);

        const afterLoop = _instructions.length;
        if (branchIndex != size_t.max)
            *branchTargetField(_instructions[branchIndex]) = afterLoop;

        foreach (index; breakable.pendingBreakJumps)
            patchTarget(index, afterLoop);

        _finished = !guarded && breakable.pendingBreakJumps.length == 0;
    }

    // dmd resolves neither `break ident` nor `continue ident` to a
    // target itself, only confirming one exists (`checkLabeledLoop` in
    // `statementsem.d`), so this compiler searches outward by identifier
    // for the entry a legally-typed program guarantees is there.
    private size_t findLoopIndex(Identifier label) {
        if (label is null)
            return _loops.length - 1;

        foreach_reverse (i, ref loop; _loops)
            if (loop.label is label)
                return i;

        return size_t.max;
    }

    private size_t findBreakableIndex(Identifier label) {
        if (label is null)
            return _breakables.length - 1;

        foreach_reverse (i, ref breakable; _breakables)
            if (breakable.label is label)
                return i;

        return size_t.max;
    }

    private void compileContinue(ContinueStatement statement) {
        if (_loops.length == 0)
            assert(0, "`visitContinue` rejects a `continue` outside a loop");

        const index = findLoopIndex(statement.ident);
        if (index == size_t.max)
            assert(0,
                "`visitContinue` rejects a `continue` to an unknown label");

        runPendingFinallyBodies(unwindPlanOf(
            _scopePaths.enclosing(statement), _loops[index].scopePath,
        ));
        if (_finished)
            return;

        const target = _loops[index].continueTarget;
        if (target != size_t.max) {
            emit(&opJump, target, 0, 0);
        } else {
            _loops[index].pendingContinueJumps ~= _instructions.length;
            emit(&opJump, 0, 0, 0);
        }

        _finished = true;
    }

    private void resolveContinues(in size_t target) {
        foreach (index; _loops[$ - 1].pendingContinueJumps)
            _instructions[index].destination = target;
        _loops[$ - 1].pendingContinueJumps = [];
    }

    // A `switch`'s own body is, once every `ScopeStatement`/
    // `CompoundStatement` wrapper around it is looked through, a flat
    // sequence of `CaseStatement`/`DefaultStatement` (and, when dmd had
    // to synthesise a missing `default:`, a plain statement or two
    // alongside them - see `visit(SwitchStatement)`'s own doc) each
    // holding only its own case's statements - fallthrough is simply the
    // next one's instructions following on directly, with nothing to jump
    // over.
    // `parseStatement`'s own `ParseStatementFlags.scope_` wraps every
    // curly-braced body in a `ScopeStatement`, the same as a
    // `while`/`for`'s own body, and dmd's synthesised default wraps the
    // original body and its own `DefaultStatement` in one more
    // `CompoundStatement` that never itself goes through semantic's
    // usual flattening - so this looks through as many layers of either
    // as are actually there, rather than assuming exactly one.
    // `compileStatement`/`compileStatements` on their own would skip a
    // sibling, at any of these layers, once `_finished` was left set by
    // an earlier one (a `break`, a `return`) - exactly wrong here, since
    // an earlier case ending that way must not hide a later one's own
    // instructions, which a jump from elsewhere in the `switch` may
    // still target.
    private void compileSwitchBody(Statement body_) {
        if (body_ is null)
            return;

        if (auto scope_ = body_.isScopeStatement()) {
            compileSwitchBody(scope_.statement);
            return;
        }

        if (auto with_ = body_.isWithStatement()) {
            if (with_.wthis is null) {
                // A name-lookup scope must not hide later case labels
                // after an earlier case returns or breaks.
                compileSwitchBody(with_._body);
                return;
            }
        }

        if (auto compound = body_.isCompoundStatement()) {
            foreach (child; *compound.statements) {
                _finished = false;
                compileSwitchBody(child);
            }
            return;
        }

        _finished = false;
        compileStatement(body_);
    }

    private void jumpToCase(CaseStatement case_, in size_t instructionIndex) {
        if (auto target = case_ in _caseTargets) {
            patchTarget(instructionIndex, *target);
            return;
        }

        _pendingCaseJumps ~= PendingCaseJump(instructionIndex, case_);
    }

    private void recordCaseTarget(CaseStatement case_) {
        const target = _instructions.length;
        _caseTargets[case_] = target;

        size_t i = 0;
        while (i < _pendingCaseJumps.length) {
            if (_pendingCaseJumps[i].case_ !is case_) {
                ++i;
                continue;
            }

            patchTarget(_pendingCaseJumps[i].instructionIndex, target);
            _pendingCaseJumps =
                _pendingCaseJumps[0 .. i] ~ _pendingCaseJumps[i + 1 .. $];
        }
    }

    private void jumpToDefault(
        SwitchStatement switch_, in size_t instructionIndex,
    ) {
        if (auto target = switch_ in _defaultTargets) {
            patchTarget(instructionIndex, *target);
            return;
        }

        _pendingDefaultJumps ~= PendingDefaultJump(instructionIndex, switch_);
    }

    private void recordDefaultTarget(SwitchStatement switch_) {
        const target = _instructions.length;
        _defaultTargets[switch_] = target;

        size_t i = 0;
        while (i < _pendingDefaultJumps.length) {
            if (_pendingDefaultJumps[i].switch_ !is switch_) {
                ++i;
                continue;
            }

            patchTarget(_pendingDefaultJumps[i].instructionIndex, target);
            _pendingDefaultJumps =
                _pendingDefaultJumps[0 .. i] ~ _pendingDefaultJumps[i + 1 .. $];
        }
    }

    // Patches a still-pending `opJump`/`opBranchTrue`/`opBranchFalse`
    // this compiler itself emitted with the instruction index its own
    // target is now known to start at - the same instruction-index
    // currency `resolveBranches` later turns into a real address, via
    // the same field each opcode keeps it in (`branchTargetField`).
    private void patchTarget(in size_t instructionIndex, in size_t target) {
        auto field = branchTargetField(_instructions[instructionIndex]);
        assert(field !is null);
        *field = target;
    }

    // Runs `expression` for effect, at statement level: whatever value it
    // produces (a call's return, an assignment's own value) is never read.
    private void compileEffect(Expression expression) {
        discardingResult({
            withFullExpression(FullExpressionKind.effect, expression,
                { expression.accept(this); },
            );
        });
    }

    // `NewExp.argprefix` stages constructor arguments before the call. Its
    // declarations and any destructible values must stay alive until the
    // enclosing `NewExp` finishes, so execute it in the current full
    // expression instead of opening a nested one that would clean them up
    // before the constructor reads its arguments.
    private void compileEffectInCurrentLifetime(Expression expression) {
        discardingResult({ expression.accept(this); });
    }

    private void discardingResult(scope void delegate() compile) {
        const destination = _destination;
        const width = _width;
        auto valueType = _valueType;
        scope (exit) {
            _destination = destination;
            _width = width;
            _valueType = valueType;
        }

        _destination = discardResult;
        _width = 0;
        compile();
    }

    private void compileValue(
        Expression expression, in size_t destination, in size_t width,
    ) {
        if (_emittingCleanup)
            return evalInto(expression, destination, width);

        withFullExpression(FullExpressionKind.value, expression,
            { evalInto(expression, destination, width); },
        );
    }

    private void withFullExpression(
        FullExpressionKind kind,
        Expression root,
        scope void delegate() evaluate,
    ) {
        _expressions.run(kind, cast(const(void)*) root,
            { beginLifetime; }, evaluate, { endLifetime; });
    }

    private void beginLifetime() {
        _lifetimeMarkers ~= _instructions.length;
        emit(null, 0, 0, 0);
        _lifetimeFirstTemporaries ~= _temporaries.length;
    }

    private void endLifetime() {
        const marker = _lifetimeMarkers[$ - 1];
        const firstTemporary = _lifetimeFirstTemporaries[$ - 1];
        _lifetimeMarkers.length -= 1;
        _lifetimeFirstTemporaries.length -= 1;
        if (_temporaries.length == firstTemporary)
            return;

        const slot = reserveTemp(pointerFacts);
        _instructions[marker] = Instruction(&opTemporaryBegin, slot, 0, 0);
        finishLifetime(slot, firstTemporary);
    }

    private void finishLifetime(
        in size_t marker,
        in size_t firstTemporary,
    ) {
        const jump = _instructions.length;
        emit(&opJump, 0, 0, 0);
        foreach_reverse (temporary; _temporaries[firstTemporary .. $]) {
            _callSites[temporary.site].cleanupStartIndex = _instructions.length;
            _emittingCleanup = true;
            compileEffect(temporary.destructor);
            _emittingCleanup = false;
            _callSites[temporary.site].cleanupEndIndex = _instructions.length;
        }
        _temporaries.length = firstTemporary;
        _instructions[jump].destination = _instructions.length;
        emit(&opTemporaryEnd, marker, 0, 0);
    }

    protected extern(C++) override void visitTupleElement(
        Expression expression,
    ) {
        compileEffect(expression);
    }

    private size_t registerTemporary(
        VarDeclaration variable,
        Expression destructor,
    ) {
        const base = _layout.offsetOf(variable);
        const site = _callSites.length;
        _callSites ~= CallSite.temporary;
        _temporaries ~= Temporary(base, site, destructor);
        emit(&opTemporaryRegister, base, site, 0);
        return base;
    }

    // Runs a local's initialiser into the frame slot `_layout` already
    // gave it - `int sum = 0;` is a `DeclarationExp` here, the same as in
    // the interpreter.
    private void compileDeclaration(DeclarationExp expression) {
        import snakebite.backends.declaration: forEachRuntimeVariable;

        forEachRuntimeVariable(expression.declaration, (variable) {
            compileDeclaredVariable(variable, expression);
        });
    }

    private void compileDeclaredVariable(
        VarDeclaration variable, DeclarationExp expression,
    ) {
        if (variable.isDataseg) {
            staticAddressOf(variable);
            return;
        }

        // Zero-length static arrays can have no initializer at all.
        if (variable._init is null)
            return;

        if (variable._init.isVoidInitializer !is null)
            return;

        const emitDeclaration = () {
            const plan = TemporaryPlan.of(variable, expression,
                _emittingCleanup ? null : cast(Expression) _expressions.root,
                _expressions.rootOwnsTemporary);
            size_t temporary;
            plan.initialize((Expression destructor) {
                temporary = registerTemporary(variable, destructor);
            }, {
                compileVariableInitializer(variable);
            }, {
                emit(&opTemporaryArmAddress, 0, temporary, 0);
            });
        };

        if (_emittingCleanup)
            return emitDeclaration();

        withFullExpression(FullExpressionKind.effect, expression,
            emitDeclaration,
        );
    }

    // Runs `variable`'s own initialiser into whichever storage its layout
    // gave it: a closure slot, a frame slot holding an address (a `ref`
    // local), or a frame slot holding a value. `with (aggregate) ...`'s
    // own `wthis` takes the last path: its slot holds the pointer or
    // class reference value its initialiser evaluates to, not a `ref`
    // local's address. Shared by local declarations and with-statement
    // temporaries.
    private void compileVariableInitializer(VarDeclaration variable) {
        auto expInitializer = variable._init.isExpInitializer;
        assert(expInitializer !is null,
            "a runtime variable initializer is an expression initializer");

        if (initializerRunsForEffect(expInitializer, variable))
            return compileEffect(expInitializer.exp);

        const facts = TypeFacts.of(variable.type);
        auto initializer = initializerValueOf(expInitializer);
        import snakebite.nativelayout: isStoredLiteral;

        const storedLiteral = isStoredLiteral(initializer);
        if (isClosureVariable(variable)) {
            const slot = _closureLayout.slotOf(variable);
            const target = closureSlotAddress(slot.offset);
            if (slot.isRef) {
                const addressOffset = compileAddress(initializerValueOf(
                    expInitializer));
                emit(&opStoreIndirect, target, addressOffset,
                    size_t.sizeof);
            } else {
                evalInto(
                    storedLiteral ? initializer : expInitializer.exp,
                    indirectStorage(target), facts.size, variable.type,
                );
            }
            return;
        }

        const offset = _layout.offsetOf(variable);

        // `foreach (ref value; values) ...` declares `value` afresh each
        // iteration, bound to `values[i]`'s own storage - the same `ref`
        // local shape a `ref int x = y;` written by hand has. Its own
        // slot holds `y`'s address, not `y`'s value, so this stores the
        // address `compileAddress` computes rather than evaluating the
        // initialiser as a value the way a by-value local's is. `with`'s
        // `wthis` is not laid out this way: `FrameLayout.collectVariable`
        // sets `isRef` only for `STC.ref_`, and `wthis` is `STC.temp`, so
        // it falls through to the plain `evalInto` path below instead.
        if (_layout.isRef(variable)) {
            const addressOffset = compileAddress(initializerValueOf(expInitializer));
            emit(&opCopy, offset, addressOffset, size_t.sizeof);
            return;
        }

        evalInto(
            storedLiteral ? initializer : expInitializer.exp,
            offset,
            facts.size,
            variable.type,
        );
    }

    // For a `shared`/`__gshared` variable, the storage address itself -
    // stable for the process, so a compile-time constant. For a
    // thread-local variable, the address of its `TlsDescriptor` instead
    // (finding 1.3): `opTls*` resolves that, on every access, to
    // whichever thread is running - never this compiling thread's own
    // storage, which is what a resolved address here would bake in.
    private size_t staticAddressOf(VarDeclaration variable) {
        if (variable.isThreadLocalStorage)
            return cast(size_t) _bytecode._nativeData.tlsDescriptorOf(variable);
        return cast(size_t) _bytecode._nativeData.storageOf(variable).ptr;
    }

    private Instruction.Handler staticLoadHandler(VarDeclaration variable) {
        return variable.isThreadLocalStorage ? &opTlsLoad : &opStaticLoad;
    }

    private Instruction.Handler staticStoreHandler(VarDeclaration variable) {
        return variable.isThreadLocalStorage ? &opTlsStore : &opStaticStore;
    }

    private Instruction.Handler staticAddressHandler(VarDeclaration variable) {
        return variable.isThreadLocalStorage ? &opTlsAddress : &opStaticAddress;
    }

    // A plain `=` to a local or parameter. `destOffset` is where the
    // assignment's own value (D specifies an assignment as an expression)
    // goes too, `discardResult` when a caller at statement level has
    // nowhere for it and does not want it.
    private void compileAssign(AssignExp expression, in size_t destOffset) {
        const target = compileAddress(expression);
        if (destOffset != discardResult) {
            if (auto dot = expression.e1.isDotVarExp) {
                auto field = dot.var.isVarDeclaration;
                if (field !is null
                        && field.isBitFieldDeclaration !is null) {
                    const facts = TypeFacts.of(field.type);
                    emit(&opLoadBitfield, destOffset, target, facts.size,
                        bitfieldAccess(field).encode(facts.size));
                    return;
                }
            }
            emit(&opLoadIndirect, destOffset, target,
                TypeFacts.of(expression.type).size);
        }
    }

    private void emitStaticStore(
        VarDeclaration variable,
        in size_t sourceOffset,
        in size_t width,
    ) {
        emit(staticStoreHandler(variable), staticAddressOf(variable), sourceOffset, width);
    }

    // Whether a bare identifier names a field reached implicitly through
    // `this` - a struct has no base to search, so `aggregate` must be
    // `this`'s own declaration exactly, but a class method inherited
    // unchanged from a base (`describe`'s own `base` field, declared on
    // `Base` and read from `Derived.describe`) needs the whole base chain
    // walked, the same declaration `field.offset` already lays out at a
    // fixed spot regardless of which class in the chain declared it.
    private bool isThisField(VarDeclaration variable) const {
        auto aggregate = variable.toParent2;
        auto thisAggregate = _function.isThis;
        if (thisAggregate is null)
            return false;

        if (thisAggregate.isStructDeclaration !is null)
            return aggregate is thisAggregate;

        for (auto c = cast() thisAggregate.isClassDeclaration; c !is null;
                c = c.baseClass)
            if (c is aggregate)
                return true;

        return false;
    }

    private bool isClosureVariable(VarDeclaration variable) const {
        return _closureOffset != size_t.max
            && _closureLayout.hasSlot(variable);
    }

    private size_t addPointerOffset(
        in size_t pointerOffset,
        in long byteOffset,
    ) {
        const result = reserveTemp(pointerFacts);
        emit(&opCopy, result, pointerOffset, size_t.sizeof);
        if (byteOffset == 0)
            return result;

        const offset = reserveTemp(pointerFacts);
        emit(&opConstant, offset, addConstant(cast(long) byteOffset),
            size_t.sizeof);
        emit(&opAdd, result, offset, size_t.sizeof);
        return result;
    }

    // The context of `owner`, as a pointer value in a temporary frame slot.
    // `staticChainPath` decides which hops that takes; this only folds them
    // into loads. The first hop is a plain copy out of the current frame -
    // that frame's own hidden `this` slot is already addressable by offset
    // at compile time - every later hop indirects through a pointer value
    // already sitting in `result`.
    private size_t contextAddressOf(FuncDeclaration owner) {
        if (owner is _function) {
            if (_closureOffset != size_t.max)
                return _closureOffset;

            const result = reserveTemp(pointerFacts);
            emit(&opFrameAddress, result, 0, size_t.sizeof);
            return result;
        }

        const path = ClosurePlan.staticChainPath(_function, owner);
        if (path is null)
            assert(0, "dmd rejects a reference to a frame the function has "
                ~ "no context chain to (`checkNestedReference`)");

        auto result = reserveTemp(pointerFacts);
        emit(&opCopy, result, path[0].offset, size_t.sizeof);

        foreach (const hop; path[1 .. $]) {
            result = addPointerOffset(result, hop.offset);
            emit(&opLoadIndirect, result, result, size_t.sizeof);
        }

        return result;
    }

    private ref ClosurePlan closurePlanOf(FuncDeclaration function_) {
        if (auto cached = function_ in _closurePlans)
            return *cached;

        _closurePlans[function_] = ClosurePlan.of(function_);
        return _closurePlans[function_];
    }

    // The address of a variable's storage as a pointer value in a frame
    // slot. A ref variable is indirected here, so all callers see the
    // storage it refers to rather than its pointer slot.
    private size_t addressOfVariable(VarDeclaration variable) {
        if (isClosureVariable(variable)) {
            const slot = _closureLayout.slotOf(variable);
            auto result = closureSlotAddress(slot.offset);
            if (slot.isRef)
                emit(&opLoadIndirect, result, result, size_t.sizeof);
            return result;
        }

        auto owner = outerFunctionOf(variable);
        if (owner is _function) {
            if (_layout.isRef(variable))
                return _layout.offsetOf(variable);

            const result = reserveTemp(pointerFacts);
            emit(&opFrameAddress, result, _layout.offsetOf(variable),
                size_t.sizeof);
            return result;
        }

        if (owner is null)
            assert(0,
                "a local variable belongs to a function");

        auto context = contextAddressOf(owner);
        const closurePlan = closurePlanOf(owner);
        if (closurePlan.needsClosure) {
            const closure = closurePlan.layout;
            if (closure.hasSlot(variable)) {
                const slot = closure.slotOf(variable);
                context = addPointerOffset(context, slot.offset);
                if (slot.isRef)
                    emit(&opLoadIndirect, context, context, size_t.sizeof);
                return context;
            }
        }

        const layout = FrameLayout.of(owner);
        if (!layout.hasSlot(variable))
            assert(0,
                "a frame layout reserves a slot for each of its locals");

        context = addPointerOffset(context, layout.offsetOf(variable));
        if (layout.isRef(variable))
            emit(&opLoadIndirect, context, context, size_t.sizeof);
        return context;
    }

    // The raw slot for a reference declaration. Unlike addressOfVariable,
    // this must not load the pointer stored in that slot: referenceInit is
    // the first write to the slot.
    private size_t referenceSlotAddress(VarDeclaration variable) {
        if (isClosureVariable(variable)) {
            const slot = _closureLayout.slotOf(variable);
            return closureSlotAddress(slot.offset);
        }

        auto owner = outerFunctionOf(variable);
        if (owner is _function)
            return _layout.offsetOf(variable);

        if (owner is null)
            assert(0,
                "a local variable belongs to a function");

        auto context = contextAddressOf(owner);
        const closurePlan = closurePlanOf(owner);
        if (closurePlan.needsClosure) {
            const closure = closurePlan.layout;
            if (!closure.hasSlot(variable))
                assert(0,
                    "a closure's layout holds every variable captured from it");
            return addPointerOffset(context, closure.slotOf(variable).offset);
        }

        const layout = FrameLayout.of(owner);
        if (!layout.hasSlot(variable))
            assert(0,
                "a frame layout reserves a slot for each of its locals");
        return addPointerOffset(context, layout.offsetOf(variable));
    }

    private size_t closureSlotAddress(in size_t offset) {
        const closure = reserveTemp(pointerFacts);
        emit(&opCopy, closure, _closureOffset, size_t.sizeof);
        return addPointerOffset(closure, offset);
    }

    // The this-slot's own frame offset - for a struct method, a `ref`
    // slot whose runtime content is the receiver's address; for a class
    // method, a plain slot whose runtime content already *is* the
    // receiver, a class reference being one pointer either way. Every
    // caller here already reads that runtime content as an address either
    // way (`compileThisFieldAddress`'s `opAdd`, `visit(ThisExp)`'s own
    // class branch below) - `FrameLayout.isRef` only decides whether this
    // slot needs one more `opLoadIndirect` first to reach it, for a
    // struct's own hidden `this` alone.
    //
    // `variable` names `_function`'s own `vthis` for an ordinary member
    // method, but a lambda or nested function reading `this` implicitly
    // (`dmd`'s own `hasThis` resolves such a read to the nearest
    // enclosing *member* function's `vthis`, not the lambda's own) names
    // an outer function's `vthis` instead - one this compiler's own frame
    // never reserved a slot for. `contextThisOffset` reaches that one
    // through the static chain, the same way any other captured variable
    // is reached.
    private size_t hiddenThisOffset(VarDeclaration variable = null) {
        auto hiddenThis = variable is null
            ? cast() _layout.hiddenThis.variable
            : variable;
        if (hiddenThis is null)
            assert(0, "a function that reads `this` reserves a slot for it");

        const hidden = hiddenSlotOffset(hiddenThis);
        return receiverOffsetFrom(
            hiddenThis is _layout.hiddenThis.variable
                ? _function : outerFunctionOf(hiddenThis),
            hidden,
        );
    }

    // The slot that holds the value of `hiddenThis`, before the hops of
    // `ClosurePlan.receiverHops` that reach the receiver.
    private size_t hiddenSlotOffset(VarDeclaration hiddenThis) {
        if (hiddenThis is _layout.hiddenThis.variable)
            return _layout.offsetOf(hiddenThis);

        return contextThisOffset(hiddenThis);
    }

    // As `hiddenThisOffset`, when `hiddenThis` belongs to an outer
    // function reached through the static chain rather than to
    // `_function`'s own frame - the same reach `addressOfVariable` gives
    // any other captured variable, except `hiddenThis`'s own slot is
    // always read exactly once here regardless of `FrameLayout.isRef`:
    // a frame slot read (the own-frame branch above) costs no
    // instruction at all, whatever it holds, so the one memory read this
    // performs to cross into another frame or closure is the equivalent
    // cost, not an extra dereference layered on top of it.
    private size_t contextThisOffset(VarDeclaration hiddenThis) {
        auto owner = outerFunctionOf(hiddenThis);
        if (owner is null)
            assert(0, "a `this` variable belongs to a function");

        auto context = contextAddressOf(owner);
        const closurePlan = closurePlanOf(owner);
        if (closurePlan.needsClosure) {
            const closure = closurePlan.layout;
            if (!closure.hasSlot(hiddenThis))
                assert(0,
                    "a closure's layout holds every `this` captured from it");

            context = addPointerOffset(context, closure.slotOf(hiddenThis).offset);
        } else {
            const layout = FrameLayout.of(owner);
            if (!layout.hasSlot(hiddenThis))
                assert(0,
                    "an owner's frame layout reserves a slot for its `this`");

            context = addPointerOffset(context, layout.offsetOf(hiddenThis));
        }

        emit(&opLoadIndirect, context, context, size_t.sizeof);
        return context;
    }

    // The receiver of `function_`, from the frame slot `hidden` that holds
    // the value of its hidden `this` argument, by the hops
    // `ClosurePlan.receiverHops` says.
    private size_t receiverOffsetFrom(
        FuncDeclaration function_, in size_t hidden,
    ) {
        // `auto` would give `const`, which the loop reassigns.
        size_t value = hidden;
        foreach (const hop; ClosurePlan.receiverHops(function_)) {
            const address = hop.offset == 0
                ? value : addPointerOffset(value, hop.offset);
            value = reserveTemp(pointerFacts);
            emit(&opLoadIndirect, value, address, size_t.sizeof);
        }
        return value;
    }

    private size_t compileThisFieldAddress(VarDeclaration field) {
        return addFieldOffset(hiddenThisOffset, field);
    }

    // `*p = value` in every guise this compiler reaches it through: a `ref`
    // variable's own target, or a `ref`-returning call's own result.
    // `compileAddress` already knows how to compile either lvalue's
    // address; this only adds the store once that address is in hand, using
    // the same storage path as `visit(IndexExp)` for an array element.
    private void compileIndirectAssign(
        AssignExp expression, Expression target, in size_t destOffset,
    ) {
        const addressOffset = compileAddress(target);
        compileAssignmentAt(expression, addressOffset, destOffset);
    }

    private void compileAssignmentAt(
        AssignExp expression, in size_t addressOffset,
        in size_t destOffset = discardResult,
    ) {
        if (auto dot = expression.e1.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field !is null && field.isBitFieldDeclaration !is null) {
                const facts = TypeFacts.of(field.type);
                const valueOffset = reserveTemp(facts);
                evalInto(expression.e2, valueOffset, facts.size,
                    expression.e1.type);
                emitBitfieldStore(field, addressOffset, valueOffset,
                    facts.size);
                if (destOffset != discardResult)
                    emit(&opCopy, destOffset, valueOffset, facts.size);
                return;
            }
        }

        const facts = TypeFacts.of(expression.e1.type);
        import snakebite.backends.assignment: executeAssignment;

        const valueOffset = executeAssignment!size_t(
            expression.isConstructExp !is null,
            indirectStorage(addressOffset), facts.size, facts.alignment,
            (size, alignment) => reserveTemp(facts),
            (value) {
                evalInto(expression.e2, value, facts.size,
                    expression.e1.type);
            },
            (value) {
                emit(&opStoreIndirect, addressOffset, value, facts.size);
            });

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, facts.size);
    }

    // `s.field = value`, with the target address computed from the receiver
    // lvalue. This also covers a method's implicit field (`_bytes`) and a
    // field reached through `this`, so writes update the caller's struct.
    private void compileFieldAssign(
        AssignExp expression, DotVarExp target, in size_t destOffset,
    ) {
        auto field = target.var.isVarDeclaration;
        assert(field !is null, "an assignable field is a variable");

        if (auto bitfield = field.isBitFieldDeclaration) {
            const facts = TypeFacts.of(field.type);
            const valueOffset = reserveTemp(facts);
            evalInto(expression.e2, valueOffset, facts.size, expression.e1.type);
            emitBitfieldStore(field, target, valueOffset, facts.size);
            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

        const facts = TypeFacts.of(target.type);

        const addressOffset = compileFieldAddress(target);
        const valueOffset = reserveTemp(facts);
        evalInto(expression.e2, valueOffset, facts.size, expression.e1.type);
        emit(&opStoreIndirect, addressOffset, valueOffset, facts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, facts.size);
    }

    private size_t compileFieldAddress(DotVarExp expression) {
        import dmd.astenums: Tclass, Tpointer;

        auto field = expression.var.isVarDeclaration;
        assert(field !is null, "a field address names a variable");

        size_t addressOffset;
        auto aggregateType = expression.e1.type.toBasetype;
        if (aggregateType.ty == Tclass || aggregateType.ty == Tpointer) {
            addressOffset = reserveTemp(pointerFacts);
            evalInto(expression.e1, addressOffset, size_t.sizeof);
            compileNullCheck(addressOffset, expression.e1.loc);
        } else {
            assert(aggregateType.isTypeStruct !is null,
                "a struct field has a struct or class receiver");
            addressOffset = compileAddress(expression.e1);
        }

        return addFieldOffset(addressOffset, field);
    }

    // The address of `field` in the aggregate at `addressOffset`; for a bit
    // field, the address of its storage unit.
    private size_t addFieldOffset(
        in size_t addressOffset, VarDeclaration field,
    ) {
        const offset = fieldOffset(field);
        if (offset == 0)
            return addressOffset;

        const result = reserveTemp(pointerFacts);
        emit(&opConstant, result,
            addConstant(cast(long) offset), size_t.sizeof);
        emit(&opAdd, result, addressOffset, size_t.sizeof);
        return result;
    }

    private void emitBitfieldStore(
        VarDeclaration field, DotVarExp target, in size_t valueOffset,
        in size_t valueWidth,
    ) {
        const addressOffset = compileFieldAddress(target);
        emitBitfieldStore(field, addressOffset, valueOffset, valueWidth);
    }

    // `valueWidth` is the width of the slot the value comes from, which a
    // compound assignment promotes to `int` while the field's own storage
    // stays as wide as its declared type. `opStoreBitfield` reads and
    // writes the storage at the width the metadata carries, so that
    // width is always the field's own.
    private void emitBitfieldStore(
        VarDeclaration field, in size_t addressOffset, in size_t valueOffset,
        in size_t valueWidth,
    ) {
        const metadata = bitfieldAccess(field).encode(
            TypeFacts.of(field.type).size);
        emit(&opStoreBitfield, addressOffset, valueOffset, valueWidth,
            metadata);
    }

    // The assignment's value is the slice itself:
    // `int[] s = (a[] = b[]);` is legal D.
    private void compileSliceAssign(
        AssignExp expression, SliceExp target, in size_t destOffset,
        in size_t resolvedTarget = size_t.max,
    ) {
        import dmd.astenums: Tsarray;

        // A bounded slice - whether of a dynamic array, a pointer, or a
        // static array's own sub-range - has no compile-time-fixed
        // element count to unroll a loop over the way a static array's
        // own *whole* slice does below. Evaluating `target` computes its
        // `{length, pointer}` pair at run time either way: for a static
        // array's own sub-range, through `visit(SliceExp)`'s own
        // `compileBoundedSlice`, the same machinery a bare read of that
        // sub-range already goes through, bounds checks included.
        auto targetType = target.e1.type.toBasetype;
        if (targetType.ty != Tsarray
                || target.lwr !is null || target.upr !is null)
            return compileDynamicSliceAssign(
                expression, target, destOffset, resolvedTarget);

        import dmd.astenums: Tarray;
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        auto sarrayType = targetType.isTypeSArray;
        const elementFacts = TypeFacts.of(sarrayType.next);

        const dim = cast(size_t) sarrayType.dim.toInteger;

        // A local's own default-init blit reaches here with `destOffset`
        // set to that same local's own frame slot - not a distinct place
        // to receive the assignment's value, but the very storage this
        // fill already writes through `baseOffset`. Writing the slice
        // pair there too would overwrite the elements just filled, the
        // same hazard `compileAssign`'s plain-variable path already
        // avoids by comparing `destOffset` against the target's own
        // offset.
        auto targetVarExp = target.e1.isVarExp;
        auto targetVariable = targetVarExp is null
            ? null : targetVarExp.var.isVarDeclaration;
        const targetOffset = targetVariable !is null
                && !targetVariable.isDataseg
                && !isClosureVariable(targetVariable)
                && !_layout.isRef(targetVariable)
                && _layout.hasSlot(targetVariable)
            ? _layout.offsetOf(targetVariable) : size_t.max;

        const baseOffset = resolvedTarget == size_t.max
            ? compileAddress(target.e1)
            : loadSlicePointer(resolvedTarget, TypeFacts.of(target.type));

        const rightTy = expression.e2.type.toBasetype.ty;
        import snakebite.nativelayout: isStoredLiteral;

        if (isStoredLiteral(expression.e2)) {
            const facts = TypeFacts.of(sarrayType);
            const valueOffset = reserveTemp(facts);
            evalInto(expression.e2, valueOffset, facts.size, sarrayType);
            emit(&opStoreIndirect, baseOffset, valueOffset, facts.size);
        } else {
            import snakebite.nativelayout: arrayValueSize;

            const sliceFacts = TypeFacts(
                arrayValueSize, size_t.alignof, false, false, true,
                elementFacts.size,
            );
            const destSliceOffset = reserveTemp(sliceFacts);
            emit(&opConstant, destSliceOffset + arrayLengthOffset,
                addConstant(cast(long) dim), size_t.sizeof);
            emit(&opCopy, destSliceOffset + arrayPointerOffset, baseOffset,
                size_t.sizeof);

            // A static array on the right has the target's length by its
            // type, but a dynamic array has whatever length it has.
            size_t sourceSliceOffset;
            if (rightTy == Tsarray) {
                const sourceOffset = compileAddress(expression.e2);
                sourceSliceOffset = reserveTemp(sliceFacts);
                emit(&opConstant, sourceSliceOffset + arrayLengthOffset,
                    addConstant(cast(long) dim), size_t.sizeof);
                emit(&opCopy, sourceSliceOffset + arrayPointerOffset,
                    sourceOffset, size_t.sizeof);
            } else {
                sourceSliceOffset = reserveTemp(sliceFacts);
                evalInto(
                    expression.e2, sourceSliceOffset, arrayValueSize);
            }

            compileSliceCopy(
                destSliceOffset, sourceSliceOffset, elementFacts.size,
                sliceFacts, expression.loc);
        }

        if (destOffset != discardResult && destOffset != targetOffset) {
            emit(&opConstant, destOffset + arrayLengthOffset,
                addConstant(cast(long) dim), size_t.sizeof);
            emit(&opCopy, destOffset + arrayPointerOffset, baseOffset,
                size_t.sizeof);
        }
    }

    private size_t loadSliceDescriptor(
        in size_t address, in TypeFacts facts,
    ) {
        const descriptor = reserveTemp(facts);
        emit(&opLoadIndirect, descriptor, address, facts.size);
        return descriptor;
    }

    private size_t loadSlicePointer(
        in size_t address, in TypeFacts facts,
    ) {
        import snakebite.nativelayout: arrayPointerOffset;

        const descriptor = loadSliceDescriptor(address, facts);
        const pointer = reserveTemp(pointerFacts);
        emit(&opCopy, pointer,
            descriptor + arrayPointerOffset,
            size_t.sizeof);
        return pointer;
    }

    // dmd lowers elements with a postblit or destructor to
    // `_d_arrayassign_*`, so a raw byte copy is safe here. Druntime owns
    // the equal-length and overlap checks.
    private void compileDynamicSliceAssign(
        AssignExp expression, SliceExp target, in size_t destOffset,
        in size_t resolvedTarget = size_t.max,
    ) {
        import dmd.astenums: Tarray, Tpointer, Tsarray, Tvoid;
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        const targetKind = target.e1.type.toBasetype.ty;
        assert(targetKind == Tarray || targetKind == Tpointer
                || targetKind == Tsarray);

        auto elementType = target.type.nextOf;
        assert(elementType !is null);
        const elementBase = elementType.toBasetype;
        const elementSize =
            elementBase.ty == Tvoid ? 1 : TypeFacts.of(elementType).size;

        const arrayFacts = TypeFacts.of(target.type);
        const destSliceOffset = resolvedTarget == size_t.max
            ? reserveTemp(arrayFacts)
            : loadSliceDescriptor(resolvedTarget, arrayFacts);
        if (resolvedTarget == size_t.max)
            evalInto(target, destSliceOffset, arrayFacts.size);

        auto sourceElementType = expression.e2.type.nextOf;
        assert(sourceElementType !is null);
        const sourceElementBase = sourceElementType.toBasetype;

        const sourceElementSize = sourceElementBase.ty == Tvoid
            ? 1 : TypeFacts.of(sourceElementType).size;
        assert(elementSize == sourceElementSize);

        const sourceFacts = TypeFacts.of(expression.e2.type);
        const sourceSliceOffset = reserveTemp(sourceFacts);
        evalInto(expression.e2, sourceSliceOffset, sourceFacts.size);

        compileSliceCopy(
            destSliceOffset, sourceSliceOffset, elementSize, arrayFacts,
            expression.loc);

        if (destOffset != discardResult) {
            emit(&opCopy, destOffset + arrayLengthOffset,
                destSliceOffset + arrayLengthOffset, size_t.sizeof);
            emit(&opCopy, destOffset + arrayPointerOffset,
                destSliceOffset + arrayPointerOffset, size_t.sizeof);
        }
    }

    // The equal-length and no-overlap check of `to[] = from[]` is a bounds
    // check in dmd's glue layer, so it follows the program's flags like an
    // index check does, and what it raises is `RangeError`.
    private void compileSliceCopy(
        in size_t to,
        in size_t from,
        in size_t elementSize,
        in TypeFacts sliceFacts,
        in Loc loc,
    ) {
        import snakebite.backends.checkplan: boundsPlanOf, FailurePlan;
        import snakebite.nativelayout: arrayValueSize;

        const plan = boundsPlanOf(_bytecode.checks, _function);
        if (plan.kind != FailurePlan.Kind.ignore) {
            const conforms = reserveTemp(sliceFacts);
            emit(&opCopy, conforms, to, arrayValueSize);
            emit(&opSlicesConform, conforms, from, elementSize);
            compileBoundsHook(conforms, BoundsCheck.sliceCopy, null, loc);
        }

        emit(&opSliceCopy, to, from, elementSize);
    }

    // dmd's `blockAssign` gives `v` the element type, even when the
    // element is itself an array.
    private void compileSliceFill(
        AssignExp expression, SliceExp target, in size_t resolvedTarget,
    ) {
        const elementFacts = TypeFacts.of(target.type.nextOf);
        const destSliceOffset =
            loadSliceDescriptor(resolvedTarget, TypeFacts.of(target.type));
        const valueOffset = reserveTemp(elementFacts);
        evalInto(expression.e2, valueOffset, elementFacts.size);
        emit(&opSliceFill, destSliceOffset, valueOffset, elementFacts.size);
    }

    // Resolve the target before evaluating the right operand. DMD's
    // promoted floating target is read before that operand; same-width and
    // integral assignments keep the ordinary right-side-first order.
    private void compileCompoundAssign(
        BinAssignExp expression, in size_t destOffset,
    ) {
        import snakebite.frontend.storage: compoundTarget;

        const target = compileAddress(compoundTarget(expression));
        compileCompoundAssignAt(expression, target, destOffset);
    }

    private void compileCompoundAssignAt(
        BinAssignExp expression, in size_t targetOffset,
        in size_t destOffset = discardResult,
    ) {
        import snakebite.backends.arithmetic:
            ArithmeticPlan, arithmeticKind, arithmeticPlan;
        import snakebite.backends.shifts: shiftPlan;
        import snakebite.frontend.storage: compoundTarget;
        import std.conv: text;

        auto target = compoundTarget(expression);
        const targetFacts = TypeFacts.of(target.type);
        const operationFacts = TypeFacts.of(expression.e1.type);
        const plan = arithmeticPlan(expression);
        Instruction.Handler handler;
        // Explicit types: `auto` would copy `const` from the facts.
        TypeFacts rightFacts = operationFacts;
        size_t operationWidth = operationFacts.size;
        size_t operands;
        bool shiftSignExtend = !targetFacts.isUnsigned;
        // A literal shift count keeps its own promoted type, which can
        // differ in width from the operation type.
        bool stepAtOperationWidth;
        CompoundConversion conversion;
        with (ArithmeticPlan.Kind) final switch (plan.kind) {
            case integral, pointerOffset:
                stepAtOperationWidth = true;
                if (expression.isShlAssignExp || expression.isShrAssignExp
                        || expression.isUshrAssignExp) {
                    const shift = shiftPlan(expression);
                    handler = shiftHandler(shift);
                    operationWidth = shift.width;
                    shiftSignExtend = shift.signExtend;
                } else
                    handler = compoundHandler(
                        expression, operationFacts.isUnsigned, false);
                break;
            case floating:
                handler = compoundHandler(
                    expression, operationFacts.isUnsigned, true);
                conversion = compoundConversion(expression);
                if (conversion.crossesKind)
                    operationWidth = conversion.load.destFacts.size;
                break;
            case complex:
                conversion = compoundConversion(expression);
                handler = complexHandler(expression);
                rightFacts = TypeFacts.of(expression.e2.type);
                operationWidth = operationFacts.size / 2;
                operands = plan.operands.packed;
                break;
            case vector:
                return compileVectorCompoundAssign(
                    expression, plan, targetOffset, destOffset);
            case pointerDifference:
                assert(0, text("`", expressionText(expression), "`: `-=` ",
                    "cannot store a pointer difference in a pointer"));
        }

        auto field = target.isDotVarExp;
        auto fieldDeclaration = field is null
            ? null : field.var.isVarDeclaration;
        auto storage = ScalarStorage(
            fieldDeclaration is null
                || fieldDeclaration.isBitFieldDeclaration is null
                ? ScalarStorage.Kind.indirect : ScalarStorage.Kind.bitfield,
            targetFacts, targetOffset, fieldDeclaration,
            arithmeticKind(target.type),
        );
        storage.facts.isUnsigned = !shiftSignExtend;
        storage.conversion = conversion;
        // Where the operation reads and writes its value: the type it runs
        // in, which the plan changes for a target that crosses kind.
        const valueFacts = conversion.crossesKind
            ? conversion.load.destFacts : operationFacts;
        size_t valueOffset;
        if (conversion.readsTargetFirst)
            valueOffset = readScalar(storage, valueFacts);

        auto rightOffset = reserveTemp(rightFacts);
        if (stepAtOperationWidth && expression.e2.isIntegerExp)
            evalOperandInto(expression.e2, rightOffset, operationWidth);
        else
            evalInto(expression.e2, rightOffset, rightFacts.size);
        if (conversion.crossesKind && conversion.step.kind != CastKind.copy) {
            const widened = reserveTemp(conversion.step.destFacts);
            emitPackedCast(conversion.step, widened, rightOffset);
            rightOffset = widened;
        }
        if (!conversion.readsTargetFirst)
            valueOffset = readScalar(storage, valueFacts);
        emit(handler, valueOffset, rightOffset, operationWidth, operands);
        valueOffset = writeScalar(storage, valueOffset, valueFacts.size);

        if (destOffset == discardResult)
            return;
        // The value of the expression is what the field holds, which is
        // narrower than the value the operation gave.
        if (storage.kind == ScalarStorage.Kind.bitfield)
            loadScalar(storage, destOffset, storage.facts.size);
        else
            emit(&opCopy, destOffset, valueOffset, storage.facts.size);
    }

    // A vector target has the operation's own type: dmd promotes no lane.
    private void compileVectorCompoundAssign(
        BinAssignExp expression,
        in imported!"snakebite.backends.arithmetic".ArithmeticPlan plan,
        in size_t targetOffset, in size_t destOffset,
    ) {
        auto storage = ScalarStorage(ScalarStorage.Kind.indirect, plan.facts,
            targetOffset, null, plan.kind);
        const rightOffset = reserveTemp(plan.facts);
        evalInto(expression.e2, rightOffset, plan.facts.size);
        auto valueOffset = readScalar(storage, plan.facts);
        const laneHandler = laneHandler(expression, plan, compoundHandler(
            expression, plan.laneFacts.isUnsigned, false));
        emitLanes(laneHandler, plan, valueOffset, rightOffset);
        valueOffset = writeScalar(storage, valueOffset, plan.facts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, plan.facts.size);
    }

    // The complex operation for a binary, compound or postfix operator.
    private Instruction.Handler complexHandler(Expression expression) {
        import snakebite.nativevalue: ComplexOperation;
        import std.conv: text;

        with (EXP) switch (expression.op) {
            case add, addAssign, plusPlus:
                return &opComplex!(ComplexOperation.add);
            case min, minAssign, minusMinus:
                return &opComplex!(ComplexOperation.subtract);
            case mul, mulAssign:
                return &opComplex!(ComplexOperation.multiply);
            case div, divAssign:
                return &opComplex!(ComplexOperation.divide);
            case mod, modAssign:
                return &opComplex!(ComplexOperation.modulo);
            default:
                assert(0, text("`", expressionText(expression), "`: dmd ",
                    "rejects bitwise and shift operators on complex ",
                    "operands"));
        }
    }

    private struct ScalarStorage {
        enum Kind { frame, staticData, indirect, bitfield }

        Kind kind;
        TypeFacts facts;
        size_t offset;
        VarDeclaration variable;
        imported!"snakebite.backends.arithmetic".ArithmeticPlan.Kind
            arithmetic;
        // Only a compound assignment sets it.
        CompoundConversion conversion;

        // DMD reads a promoted floating or complex target before its right
        // side; integral targets keep the ordinary right-side-first order.
        bool promotesBeforeOperand() const {
            import snakebite.backends.arithmetic: ArithmeticPlan;

            with (ArithmeticPlan.Kind) final switch (arithmetic) {
                case floating, complex:
                    return true;
                case integral, pointerOffset, pointerDifference, vector:
                    return false;
            }
        }
    }

    private ScalarStorage scalarStorage(Expression target) {
        import snakebite.backends.arithmetic: arithmeticKind;

        const facts = TypeFacts.of(target.type);
        const arithmetic = arithmeticKind(target.type);

        if (auto dot = target.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            assert(field !is null,
                "a scalar DotVarExp target denotes a field variable");
            const address = compileFieldAddress(dot);
            return ScalarStorage(
                field.isBitFieldDeclaration is null
                    ? ScalarStorage.Kind.indirect
                    : ScalarStorage.Kind.bitfield,
                facts, address, field,
                arithmetic,
            );
        }

        if (auto var = target.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            assert(variable !is null,
                "a scalar VarExp target denotes a variable");
            if (isThisField(variable))
                return ScalarStorage(
                    ScalarStorage.Kind.indirect, facts,
                    compileAddress(target), null,
                    arithmetic,
                );
            if (variable.isDataseg)
                return ScalarStorage(
                    ScalarStorage.Kind.staticData, facts, 0, variable,
                    arithmetic,
                );
            if (_layout.hasSlot(variable) && !isClosureVariable(variable)
                    && !_layout.isRef(variable))
                return ScalarStorage(
                    ScalarStorage.Kind.frame, facts,
                    _layout.offsetOf(variable), null,
                    arithmetic,
                );
            return ScalarStorage(
                ScalarStorage.Kind.indirect, facts,
                addressOfVariable(variable), null,
                arithmetic,
            );
        }

        return ScalarStorage(
            ScalarStorage.Kind.indirect, facts,
            compileAddress(target), null,
            arithmetic,
        );
    }

    private size_t readScalar(
        ScalarStorage storage, in TypeFacts resultFacts,
    ) {
        if (storage.conversion.crossesKind) {
            const loaded = reserveTemp(storage.facts);
            loadScalar(storage, loaded, storage.facts.size);
            const converted = reserveTemp(resultFacts);
            emitPackedCast(storage.conversion.load, converted, loaded);
            return converted;
        }

        if (storage.kind == ScalarStorage.Kind.frame
                && storage.facts.size == resultFacts.size)
            return storage.offset;

        const valueOffset = reserveTemp(resultFacts);
        if (storage.facts.size == resultFacts.size) {
            loadScalar(storage, valueOffset, resultFacts.size);
            return valueOffset;
        }

        loadScalar(storage, valueOffset, storage.facts.size);
        emitWidthChange(storage.arithmetic, storage.facts, valueOffset,
            valueOffset, resultFacts.size, storage.facts.size);
        return valueOffset;
    }

    // Converts a target's value between its own width and the width of a
    // compound assignment's promoted operation.
    private void emitWidthChange(
        imported!"snakebite.backends.arithmetic".ArithmeticPlan.Kind kind,
        in TypeFacts facts, in size_t destination, in size_t source,
        in size_t width, in size_t sourceWidth,
    ) {
        import snakebite.backends.arithmetic: ArithmeticPlan;
        import snakebite.nativevalue: CastKind;

        with (ArithmeticPlan.Kind) final switch (kind) {
            case floating:
                emit(&opFloatWidthCast, destination, source, width,
                    sourceWidth);
                return;
            case complex:
                emit(&opCastAs!(CastKind.complexWidth), destination, source,
                    width, sourceWidth);
                return;
            case integral, pointerOffset:
                assert(destination == source,
                    "an integral target widens in place");
                emit(facts.isUnsigned
                        ? &opCastWidenUnsigned : &opCastWidenSigned,
                    destination, sourceWidth, width);
                return;
            case vector, pointerDifference:
                assert(0, "a vector or pointer target is never promoted");
        }
    }

    private void loadScalar(
        ScalarStorage storage, in size_t destination, in size_t width,
    ) {
        final switch (storage.kind) with (ScalarStorage.Kind) {
        case frame:
            emit(&opCopy, destination, storage.offset, storage.facts.size);
            break;
        case staticData:
            emitStaticLoad(storage.variable, destination, storage.facts.size);
            break;
        case indirect:
            emit(&opLoadIndirect, destination, storage.offset,
                storage.facts.size);
            break;
        case bitfield:
            emit(&opLoadBitfield, destination, storage.offset,
                storage.facts.size,
                bitfieldAccess(storage.variable).encode(width));
            break;
        }
    }

    private size_t writeScalar(
        ScalarStorage storage, in size_t valueOffset,
        in size_t valueWidth,
    ) {
        size_t storedOffset = valueOffset;
        size_t storedWidth = valueWidth;
        if (storage.conversion.crossesKind) {
            storedOffset = reserveTemp(storage.facts);
            emitPackedCast(storage.conversion.store, storedOffset,
                valueOffset);
            storedWidth = storage.facts.size;
        } else if (valueWidth != storage.facts.size
                && storage.promotesBeforeOperand) {
            storedOffset = reserveTemp(storage.facts);
            emitWidthChange(storage.arithmetic, storage.facts, storedOffset,
                valueOffset, storage.facts.size, valueWidth);
        }

        final switch (storage.kind) with (ScalarStorage.Kind) {
        case frame:
            if (storage.offset != storedOffset)
                emit(&opCopy, storage.offset, storedOffset,
                    storage.facts.size);
            break;
        case staticData:
            emitStaticStore(storage.variable, storedOffset, storage.facts.size);
            break;
        case indirect:
            emit(&opStoreIndirect, storage.offset, storedOffset,
                storage.facts.size);
            break;
        case bitfield:
            emitBitfieldStore(storage.variable, storage.offset, storedOffset,
                storedWidth);
            break;
        }
        return storedOffset;
    }

    // Emits a cast whose operand already sits at `source`. The two sizes an
    // instruction carries are the cast's own, and `castSizeWithSignedness`
    // folds in the one signedness a kind reads: the source's for a kind that
    // reads an integral value, the destination's for one that writes it.
    private void emitPackedCast(
        in CastPlan plan, in size_t destination, in size_t source,
    ) {
        with (CastKind) final switch (plan.kind) {
            case complexToBool, complexToReal, complexToImaginary,
                    complexWidth, realToComplex, imaginaryToComplex,
                    floatToPointer, pointerToFloat, floatWidth:
                emit(castOp(plan.kind), destination, source,
                    plan.destFacts.size, plan.sourceFacts.size);
                return;
            case complexToIntegral, floatToIntegral:
                emit(castOp(plan.kind), destination, source,
                    castSizeWithSignedness(
                        plan.destFacts.size, plan.destFacts.isUnsigned),
                    plan.sourceFacts.size);
                return;
            case integralToComplex, integralToFloat:
                emit(castOp(plan.kind), destination, source,
                    plan.destFacts.size,
                    castSizeWithSignedness(
                        plan.sourceFacts.size, plan.sourceFacts.isUnsigned));
                return;
            case floatToBool:
                emit(&opCastAs!floatToBool, destination, source, 0,
                    plan.sourceFacts.size);
                return;
            case copy, classReference, zero, sarrayToSlice,
                    sarrayToPointer, sliceToPointer, pointerToArray,
                    pointerToIntegral, delegateToPointer, reinterpretSlice,
                    narrow, widenSigned, widenUnsigned, toBool:
                assert(0, "this kind does not take a packed operand pair");
        }
    }

    private void emitStaticLoad(
        VarDeclaration variable,
        in size_t destinationOffset,
        in size_t width,
    ) {
        emit(staticLoadHandler(variable), destinationOffset, staticAddressOf(variable), width);
    }

    private Instruction.Handler shiftHandler(
        in imported!"snakebite.backends.shifts".ShiftPlan plan,
    ) {
        with (imported!"snakebite.backends.shifts".ShiftPlan.Direction)
            final switch (plan.direction) {
                case left:
                    return &opShiftLeft;
                case rightArithmetic:
                    return &opShiftRightArithmetic;
                case rightLogical:
                    return &opShiftRightLogical;
            }
    }

    private Instruction.Handler compoundHandler(
        BinAssignExp expression, in bool unsigned, in bool floating,
    ) {
        import std.conv: text;

        if (expression.isAddAssignExp)
            return floating ? &opFloatAdd : &opAdd;
        if (expression.isMinAssignExp)
            return floating ? &opFloatSubtract : &opSubtract;
        if (expression.isMulAssignExp)
            return floating ? &opFloatMultiply : &opMultiply;
        if (expression.isAndAssignExp) return &opBitAnd;
        if (expression.isOrAssignExp) return &opBitOr;
        if (expression.isXorAssignExp) return &opBitXor;
        if (expression.isDivAssignExp)
            return floating
                ? &opFloatDivide
                : (unsigned ? &opDivideUnsigned : &opDivideSigned);
        if (expression.isModAssignExp)
            return floating
                ? &opFloatModulo
                : (unsigned ? &opModuloUnsigned : &opModuloSigned);

        assert(0, text("`", expressionText(expression), "`: dmd lowers ",
            "every other compound assignment"));
    }

    // `x++`/`x--`, dmd's own node for the postfix forms alone - the
    // prefix ones are rewritten into `x += 1`/`x -= 1` during semantic
    // analysis and never reach this compiler as their own node.
    // `destOffset` is where the *old* value - what a `PostExp` yields as
    // an expression - goes, captured before the target changes;
    // `discardResult` when a caller at statement level does not want it.
    private void compilePost(PostExp expression, in size_t destOffset) {
        import snakebite.backends.arithmetic: ArithmeticPlan, arithmeticPlan;
        import std.conv: text;

        const plan = arithmeticPlan(expression);
        auto storage = scalarStorage(expression.e1);
        const valueOffset = readScalar(storage, storage.facts);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, storage.facts.size);

        const increment = expression.op == EXP.plusPlus;
        const stepOffset = reserveTemp(storage.facts);
        Instruction.Handler handler;
        size_t operationWidth = storage.facts.size;
        size_t operands;
        with (ArithmeticPlan.Kind) final switch (plan.kind) {
            case integral:
                evalInto(expression.e2, stepOffset, storage.facts.size);
                handler = increment ? &opAdd : &opSubtract;
                break;

            case floating:
                evalInto(expression.e2, stepOffset, storage.facts.size);
                handler = increment ? &opFloatAdd : &opFloatSubtract;
                break;

            // dmd's own AST does not scale a postfix `++`/`--` step for an
            // enum of a pointer, so the step comes from the pointee size,
            // not from `e2`.
            case pointerOffset: {
                const elementFacts =
                    TypeFacts.of(expression.e1.type.toBasetype.nextOf);
                emit(&opConstant, stepOffset,
                    addConstant(cast(long) elementFacts.size),
                    storage.facts.size);
                handler = increment ? &opAdd : &opSubtract;
                break;
            }

            case complex:
                evalInto(expression.e2, stepOffset, storage.facts.size);
                handler = complexHandler(expression);
                operationWidth = storage.facts.size / 2;
                operands = plan.operands.packed;
                break;

            case vector:
                evalInto(expression.e2, stepOffset, storage.facts.size);
                emitLanes(laneHandler(expression, plan,
                    increment ? &opAdd : &opSubtract), plan, valueOffset,
                    stepOffset);
                writeScalar(storage, valueOffset, storage.facts.size);
                return;

            case pointerDifference:
                assert(0, text("`", expressionText(expression), "`: a ",
                    "postfix `++`/`--` has the type of its operand"));
        }
        emit(handler, valueOffset, stepOffset, operationWidth, operands);
        writeScalar(storage, valueOffset, storage.facts.size);
    }

    // Compiles a value into a storage operand, including storage reached
    // through a runtime address: a literal, a local read, a nested call, a
    // nested assignment's own value (`return (sum = five());`), or any of
    // the operators below.
    private void evalInto(
        Expression expression, in size_t destOffset, in size_t width,
        Type valueType = null,
    ) {
        auto savedType = _valueType;
        const destination = _destination;
        const savedWidth = _width;
        scope (exit) {
            _destination = destination;
            _width = savedWidth;
            _valueType = savedType;
        }

        _valueType = valueType is null ? expression.type : valueType;
        _destination = destOffset;
        _width = width;
        expression.accept(this);
    }

    extern(C++):

    override void visit(Expression expression) {
        import std.conv: text;

        assert(0, text("Expression ", expression.op,
            ": no `visit` override, and not in `UnreachableNodes`"));
    }

    override void visit(DeclarationExp expression) {
        if (_destination != discardResult && _expressions.active())
            return compileDeclaration(expression);
        assert(_destination == discardResult,
            "a declaration expression does not produce a value");

        compileDeclaration(expression);
    }

    extern(D) private void emitBytes(in void[] bytes) {
        assert(bytes.length == _width);
        emit(&opStaticLoad, _destination, cast(size_t) bytes.ptr, bytes.length);
    }

    private void compileConstant(Expression expression) {
        requireDestination(expression);
        emitBytes(_bytecode._nativeData.value(_valueType, expression));
    }

    override void visit(IntegerExp expression) {
        if (_valueType !is null && _valueType.isTypeStruct !is null) {
            // DMD encodes a zero-initialized struct as an IntegerExp.
            requireDestination(expression);
            emit(&opZero, _destination, 0, _width);
            return;
        }
        compileConstant(expression);
    }

    override void visit(RealExp expression) {
        compileConstant(expression);
    }

    // `1.0f + 0.0fi`: dmd's own constant folding already reduces
    // `complex`-literal arithmetic to one `ComplexExp` (`EXP.complex80`
    // regardless of the actual `cfloat`/`cdouble`/`creal` width - only
    // `.type` differs), the same compile-time constant `RealExp` above
    // is for a real one; `compileConstant` embeds either the same way.
    override void visit(ComplexExp expression) {
        compileConstant(expression);
    }

    override void visit(StringExp expression) {
        compileConstant(expression);
    }

    // `int4 v = 1;`/`cast(int4) 1`: dmd's own semantic pass (`dcast.d`)
    // rewrites either shape to this node, `e1` already cast to the
    // vector's own element type, and its meaning is "every lane gets
    // this one value" - filling the first lane and then copying those
    // same bytes to every remaining one. `int4 v = cast(int4)
    // someInt4Sarray;` reaches this node too, with `e1` a matching-size
    // static array instead (`dcast.d`'s `T[n] <-- __vector(U[m])`, in
    // reverse): a plain reinterpret of the array's own bytes, not a
    // broadcast of a single "element".
    override void visit(VectorExp expression) {
        import dmd.astenums: Tsarray;
        import dmd.typesem: toBasetype;
        import snakebite.nativelayout: TypeFacts;

        requireDestination(expression);

        if (expression.e1.type.toBasetype.ty == Tsarray) {
            evalInto(expression.e1, _destination, _width);
            return;
        }

        const elementFacts = TypeFacts.of(expression.e1.type);
        evalInto(expression.e1, _destination, elementFacts.size);
        foreach (i; 1 .. _width / elementFacts.size)
            emit(&opCopy, _destination + i * elementFacts.size,
                _destination, elementFacts.size);
    }

    // `someVector.array`: dmd's own semantic pass (`typesem.d`'s
    // `TypeVector.dotExp`, `Id.array`) reinterprets the vector as its
    // own `basetype` static array - the same bytes, so evaluating `e1`
    // with its own (vector) type straight into the destination already
    // is the static array's own value.
    override void visit(VectorArrayExp expression) {
        requireDestination(expression);
        evalInto(expression.e1, _destination, _width);
    }

    override void visit(VarExp expression) {
        if (_destination == discardResult)
            return;

        requireDestination(expression);

        // See `snakebite.frontend.dmd.delegates.isCtfeVariable`: shared with
        // the interpreter, which folds the same read to a constant.
        {
            import snakebite.frontend.dmd.delegates: isCtfeVariable;

            if (isCtfeVariable(expression.var)) {
                emit(&opConstant, _destination, addConstant(0L), _width);
                return;
            }
        }

        // initSymbol exposes the aggregate's native initializer as bytes.
        // Keep the image in the same storage used for default values and
        // class runtime information so its address remains valid.
        if (auto symbol = expression.var.isSymbolDeclaration) {
            if (symbol.type.isTypeStruct !is null) {
                emitBytes(_bytecode._nativeData.initialValue(
                    _valueType, expression.loc));
                return;
            }

            auto declaration = symbol.dsym.isAggregateDeclaration;
            assert(declaration !is null,
                "an initializer symbol names an aggregate");
            const initial = _bytecode._runtimeTypes.initializer(declaration);

            import snakebite.nativelayout:
                arrayLengthOffset, arrayPointerOffset;

            emit(&opConstant, _destination + arrayLengthOffset,
                addConstant(cast(long) initial.length), size_t.sizeof);
            emit(&opConstant, _destination + arrayPointerOffset,
                addConstant(cast(long) cast(size_t) initial.ptr),
                size_t.sizeof);
            return;
        }

        auto variable = expression.var.isVarDeclaration;
        assert(variable !is null,
            "a runtime variable expression names a variable");

        if (variable.isDataseg) {
            emitStaticLoad(variable, _destination, _width);
            return;
        }

        if (isThisField(variable)) {
            const addressOffset = compileThisFieldAddress(variable);
            emit(&opLoadIndirect, _destination, addressOffset, _width);
            return;
        }

        // `$` inside an index has no frame slot of its own - dmd hands out
        // a fresh `VarDeclaration` for it that no statement declares
        // (`FrameLayout` never reserves it a slot for exactly that reason),
        // and the shared storage resolver binds `_dollar` to the length it
        // stands for around evaluating the index expression it appears in.
        if (variable is _dollarVariable) {
            emit(&opCopy, _destination, _dollarOffset, _width);
            return;
        }

        if (!_layout.hasSlot(variable) || isClosureVariable(variable)) {
            const address = addressOfVariable(variable);
            emit(&opLoadIndirect, _destination, address, _width);
            return;
        }

        const source = _layout.offsetOf(variable);

        // A `ref` variable's own slot holds the address of the storage it
        // is bound to, not the storage itself - reading it means reading
        // through that address instead of the slot's own bytes, the one
        // place every plain variable read resolves this.
        if (_layout.isRef(variable)) {
            emit(&opLoadIndirect, _destination, source, _width);
            return;
        }

        if (source != _destination)
            emit(&opCopy, _destination, source, _width);
    }

    // `&variable`: dmd folds this straight into a `SymOffExp` naming the
    // variable and a byte offset into it, rather than wrapping a `VarExp`
    // in a general `AddrExp`. `SymbolAddressResolver` shares the offset
    // operation with the interpreter while this visitor supplies the VM's
    // frame-slot primitives.
    override void visit(SymOffExp expression) {
        requireDestination(expression);
        const addressOffset = compileSymbolAddress(expression);
        if (addressOffset != _destination)
            emit(&opCopy, _destination, addressOffset, size_t.sizeof);
    }

    override void visit(FuncExp expression) {
        requireDestination(expression);

        import dmd.astenums: Tdelegate;

        if (expression.fd is null)
            assert(0,
                "`FuncExp`'s constructor always resolves its declaration");

        if (expression.type.toBasetype.ty != Tdelegate) {
            const address = _bytecode.callableAddress(expression.fd, 0);
            emit(&opConstant, _destination,
                addConstant(cast(long) cast(size_t) address), _width);
            return;
        }

        compileDelegateValue(
            delegateTargetOf(expression.fd, expression.type), expression);
    }

    override void visit(DelegateExp expression) {
        requireDestination(expression);

        if (expression.func is null)
            assert(0, "a `DelegateExp` names its method");
        compileDelegateValue(
            delegateTargetOf(expression.func, expression.type, expression.e1,
                expression.vthis2),
            expression);
    }

    // Shared tail of `visit(FuncExp)`/`visit(DelegateExp)`: once
    // `snakebite.frontend.dmd.delegates.delegateTargetOf` has decided what the
    // delegate value needs (frame-independent, dmd-only facts - see its
    // own doc), this resolves that decision to instructions in this
    // compiler's own representation - `contextAddressOf` walks the same
    // static chain `compileCall`'s hidden-`this` argument already follows
    // for an ordinary call to a nested function. Its function word is a
    // callable address, so host code can invoke a delegate stored in guest
    // data without changing its representation.
    private void compileDelegateValue(
        DelegateTarget target, Expression expression,
    ) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset;

        if (target.function_ is null)
            assert(0, "a delegate value names its function");

        const context = _destination + delegateContextOffset;
        if (target.receiver !is null) {
            if (target.receiverIsAddress) {
                const address = compileAddress(target.receiver);
                emit(&opCopy, context, address, size_t.sizeof);
            } else {
                evalInto(target.receiver, context, size_t.sizeof);
                compileNullCheck(context, expression.loc);
            }
        } else if (target.needsContext) {
            const contextOffset = contextAddressOf(target.contextOwner);
            emit(&opCopy, _destination + delegateContextOffset,
                contextOffset, size_t.sizeof);
        } else {
            emit(&opConstant, _destination + delegateContextOffset,
                addConstant(0), size_t.sizeof);
        }

        const plan = pairPlanOf(
            _function, target.function_, target.contextPair);
        if (plan.variable !is null)
            emit(&opCopy, context, storeContextPair(plan, context),
                size_t.sizeof);

        if (target.virtualDispatch) {
            compileClassVtableSlot(
                expression, context, target.function_,
                _destination + delegateFunctionOffset);
            return;
        }

        const address = _bytecode.callableAddress(target.function_, 0);
        emit(&opConstant, _destination + delegateFunctionOffset,
            addConstant(cast(long) cast(size_t) address), size_t.sizeof);
    }

    // `dg.ptr`/`dg.funcptr`: dmd reads either word straight out of the
    // delegate value, so this evaluates the delegate itself into a
    // temporary and copies the one word the caller asked for out of it -
    // the same two offsets `compileDelegateValue` above fills in.
    override void visit(DelegatePtrExp expression) {
        requireDestination(expression);

        import snakebite.nativelayout: delegateContextOffset;

        compileDelegateWord(expression.e1, delegateContextOffset);
    }

    override void visit(DelegateFuncptrExp expression) {
        requireDestination(expression);

        import snakebite.nativelayout: delegateFunctionOffset;

        compileDelegateWord(expression.e1, delegateFunctionOffset);
    }

    private void compileDelegateWord(Expression expression, in size_t offset) {
        import snakebite.nativelayout: delegateValueSize;

        const delegateOffset = reserveTemp(TypeFacts.delegateValue);
        evalInto(expression, delegateOffset, delegateValueSize);
        emit(&opCopy, _destination, delegateOffset + offset, _width);
    }

    private size_t compileStaticAddress(VarDeclaration variable) {
        const addressOffset = reserveTemp(pointerFacts);
        emit(staticAddressHandler(variable), addressOffset,
            staticAddressOf(variable), size_t.sizeof);
        return addressOffset;
    }

    // For a struct method, `this` is a reference to a struct value: its
    // hidden slot holds the receiver's address, so a value read loads the
    // struct bytes through it. For a class method, `this` is already the
    // class reference itself - one pointer, the same value the hidden
    // slot already holds - so a value read is a plain copy, the same
    // difference `hiddenThisOffset`'s own doc explains. A constructor can
    // synthesize a `ThisExp` without a declaration; the shared layout
    // records the declaration in that case.
    override void visit(ThisExp expression) {
        requireDestination(expression);

        const offset = hiddenThisOffset(expression.var);
        // `VarDeclaration.isThis` (`hiddenThis.isThis`) answers for an
        // ordinary member field, not for `vthis` itself - its own parent
        // is the method, not the aggregate, so it always answers `null`.
        // The function that owns `hiddenThis` is the one that actually
        // names the aggregate this `this` belongs to - `_function` itself
        // for an ordinary member method, but a lambda or nested function
        // reading `this` implicitly names the enclosing member method's
        // `vthis` instead (see `hiddenThisOffset`'s own doc), so asking
        // `_function.isThis` directly would answer `null` even for a
        // class method's own receiver in that case.
        auto hiddenThis = expression.var is null
            ? cast() _layout.hiddenThis.variable : expression.var;
        auto ownerFunction = outerFunctionOf(hiddenThis);
        auto owner = ownerFunction is null ? null : ownerFunction.isThis;
        if (owner !is null && owner.isClassDeclaration !is null) {
            if (offset != _destination)
                emit(&opCopy, _destination, offset, _width);
            return;
        }

        emit(&opLoadIndirect, _destination, offset, _width);
    }

    // The general `&expression` node: dmd only folds `&variable` into a
    // `SymOffExp` above when the variable is *not* itself `ref`
    // (`optimize.d`'s own `visitAddr`) - `&a` for a `ref` parameter `a`
    // stays this node instead, since its meaning is different: `a`'s own
    // slot already holds the address `&a` names, not a further
    // indirection into a pointer-to-pointer. `compileAddress` already
    // answers that same question for every lvalue this compiler reaches
    // through `ref` binding, so this is nothing more than that answer
    // copied to `_destination`.
    override void visit(AddrExp expression) {
        import snakebite.frontend.storage: typeInfoAddressedBy;
        import snakebite.nativelayout: isStaticStructAddress;

        if (isStaticStructAddress(expression))
            return compileConstant(expression);

        requireDestination(expression);

        if (auto typeInfo =
                expression.typeInfoAddressedBy(_bytecode._runtimeTypes)) {
            emitTypeInfoConstant(typeInfo);
            return;
        }

        const addressOffset = compileAddress(expression.e1);
        if (addressOffset != _destination)
            emit(&opCopy, _destination, addressOffset, size_t.sizeof);
    }

    override void visit(PtrExp expression) {
        requireDestination(expression);

        const addressOffset = compileAddress(expression);
        emit(&opLoadIndirect, _destination, addressOffset, _width);
    }

    // `s.field`, read as a value. `expression.e1` is evaluated into a
    // temporary of its own first, whatever kind of expression it is - a
    // local, an array element, another field access - the same way any
    // other sub-expression this compiler evaluates is; the field then
    // reads out of that temporary at its own `field.offset`, laid out by
    // dmd's own native semantics rather than recomputed here.
    override void visit(DotVarExp expression) {
        if (_destination == discardResult) {
            const facts = TypeFacts.of(expression.type);
            const offset = reserveTemp(facts);
            evalInto(expression, offset, facts.size);
            return;
        }

        requireDestination(expression);

        auto field = expression.var.isVarDeclaration;
        assert(field !is null, "a field read names a variable");

        if (auto bitfield = field.isBitFieldDeclaration) {
            const facts = TypeFacts.of(field.type);
            const addressOffset = compileFieldAddress(expression);
            emit(&opLoadBitfield, _destination, addressOffset, facts.size,
                bitfieldAccess(field).encode(facts.size));
            return;
        }

        import dmd.astenums: Tclass, Tpointer;
        auto aggregateType = expression.e1.type.toBasetype;
        if (aggregateType.ty == Tclass || aggregateType.ty == Tpointer) {
            const facts = TypeFacts.of(field.type);
            const objectOffset = reserveTemp(pointerFacts);
            evalInto(expression.e1, objectOffset, size_t.sizeof);
            compileNullCheck(objectOffset, expression.e1.loc);
            const fieldOffset = reserveTemp(pointerFacts);
            emit(&opConstant, fieldOffset,
                addConstant(cast(long) field.offset), size_t.sizeof);
            emit(&opAdd, objectOffset, fieldOffset, size_t.sizeof);
            emit(&opLoadIndirect, _destination, objectOffset, _width);
            return;
        }

        assert(aggregateType.isTypeStruct !is null,
            "a struct field has a struct or class receiver");

        const baseFacts = TypeFacts.of(expression.e1.type);
        const baseOffset = reserveTemp(baseFacts);
        evalInto(expression.e1, baseOffset, baseFacts.size);
        emit(&opCopy, _destination, baseOffset + field.offset, _width);
    }

    // The four hooks `snakebite.backends.aggregateinit.applyStep` and
    // `driveInit` drive, one per `InitStep.Kind`, each turning one step
    // into bytecode at `base`, a storage operand that preserves field
    // offsets for both frame values and allocations alike.

    // Satisfies `aggregateinit`'s `Hooks` contract: forwards each
    // `InitStep.Kind` to the matching `apply*Step` method below, at
    // whichever `base` its call site is compiling into. Built
    // once per call site instead of the four lambdas each used to
    // build.
    private struct AggregateInitHooks {
        private FunctionCompiler _compiler;
        private size_t _base;

        public void applyVthis(InitStep step) {
            _compiler.applyVthisStep(step, _base);
        }
        public void applyValue(InitStep step) {
            _compiler.applyValueStep(step, _base);
        }
        public void applyBitfield(InitStep step) {
            _compiler.applyBitfieldStep(step, _base);
        }
        public void applyBroadcast(InitStep step) {
            _compiler.applyBroadcastStep(step, _base);
        }
    }

    // A `vthis` step with `source` set (a nested class's `NewExp.thisexp`)
    // evaluates that expression directly, then adds `sourceAdjustment` if
    // it is non-zero. Any other step stores the context of its
    // `contextOwner`.
    private void applyVthisStep(InitStep step, in size_t base) {
        if (step.source !is null) {
            evalInto(step.source, base + step.offset, step.facts.size,
                step.type);
            if (step.sourceAdjustment != 0) {
                const adjustment = reserveTemp(pointerFacts);
                emit(&opConstant, adjustment,
                    addConstant(cast(long) step.sourceAdjustment),
                    size_t.sizeof);
                emit(&opAdd, base + step.offset, adjustment, size_t.sizeof);
            }
            return;
        }

        const context = contextOffsetOf(
            contextSourceOf(_function, step.contextOwner));
        emit(&opCopy, base + step.offset, context, size_t.sizeof);
    }

    private void applyValueStep(InitStep step, in size_t base) {
        evalInto(step.source, base + step.offset, step.facts.size, step.type);
    }

    private void applyBitfieldStep(InitStep step, in size_t base) {
        const valueOffset = reserveTemp(step.facts);
        evalInto(step.source, valueOffset, step.facts.size, step.type);

        const addressOffset = reserveTemp(pointerFacts);
        emit(&opFrameAddress, addressOffset, base + step.offset,
            size_t.sizeof);

        emitBitfieldStore(step.field, addressOffset, valueOffset,
            step.facts.size);
    }

    // Reached alike for a `StructLiteralExp`'s `elements` and a `NewExp`'s
    // positional `arguments`: both are narrowed by dmd's own `fit`
    // (`expressionsem.d`) ahead of `fill`, which walks a static-array
    // field's nested array levels until a single given value matches one,
    // leaving that value's own (narrower) type on the source expression
    // instead of widening it to the full field type.
    private void applyBroadcastStep(InitStep step, in size_t base) {
        const tempOffset = reserveTemp(step.facts);
        evalInto(step.source, tempOffset, step.facts.size);

        foreach (i; 0 .. step.count)
            emit(&opCopy, base + step.offset + i * step.facts.size,
                tempOffset, step.facts.size);
    }

    // `Point(3, 4)`, dmd's own literal form for a plain-old struct with no
    // user-defined constructor: every field evaluated directly into its
    // own slot at `field.offset` within `_destination`, zeroed first for
    // any field the literal itself leaves out - the same "zero, then fill
    // what is given" shape `compileNewArray`'s own default fill and
    // `StructLiteralExp.elements` sparseness both call for.
    override void visit(StructLiteralExp expression) {
        requireDestination(expression);
        import snakebite.nativelayout: isStoredLiteral;

        if (isStoredLiteral(expression))
            return compileConstant(expression);

        emit(&opZero, _destination, 0, _width);

        import snakebite.backends.aggregateinit: applyStep, planStructLiteral;

        auto plan = planStructLiteral(expression);
        auto hooks = AggregateInitHooks(this, _destination);
        foreach (step; plan.steps)
            applyStep(hooks, step);
    }

    // `arr.length`: the array's own length word, read straight out of its
    // own two-word slot - `arrayLengthOffset` is `0`, so this is really
    // just `arr`'s own first word, but named through the constant rather
    // than assumed, the same way the shared storage resolver names the pointer
    // word through `arrayPointerOffset` instead of assuming it comes
    // second.
    override void visit(ArrayLengthExp expression) {
        import snakebite.nativelayout: arrayLengthOffset;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.e1.type);
        assert(facts.isDynamicArray);

        const arrayOffset = reserveTemp(facts);
        evalInto(expression.e1, arrayOffset, facts.size);
        emit(&opCopy, _destination, arrayOffset + arrayLengthOffset, _width);
    }

    private void compileBoundedSlice(
            SliceExp expression,
            size_t sourceLengthOffset,
            size_t sourcePointerOffset) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;

        auto outerDollarVariable = _dollarVariable;
        auto outerDollarOffset = _dollarOffset;
        scope (exit) {
            _dollarVariable = outerDollarVariable;
            _dollarOffset = outerDollarOffset;
        }
        if (expression.lengthVar !is null) {
            _dollarVariable = expression.lengthVar;
            _dollarOffset = sourceLengthOffset;
        }

        const lowOffset = reserveTemp(pointerFacts);
        if (expression.lwr is null)
            emit(&opConstant, lowOffset, addConstant(0), size_t.sizeof);
        else
            evalOperandInto(expression.lwr, lowOffset, size_t.sizeof);

        const highOffset = reserveTemp(pointerFacts);
        if (expression.upr is null)
            emit(&opCopy, highOffset, sourceLengthOffset, size_t.sizeof);
        else
            evalOperandInto(expression.upr, highOffset, size_t.sizeof);

        const plan = planSlice(expression);
        Arg[3] boundsArgs = [
            Arg(lowOffset, 0, size_t.sizeof),
            Arg(highOffset, 0, size_t.sizeof),
            Arg(sourceLengthOffset, 0, size_t.sizeof),
        ];
        // Check before pointer arithmetic so a bad slice cannot form an
        // address outside the guest array.
        if (plan.checkOrder)
            compileSliceCheck(
                lowOffset, highOffset, boundsArgs[], expression.loc);
        if (plan.checkUpper)
            compileSliceCheck(
                highOffset, sourceLengthOffset, boundsArgs[], expression.loc);

        emit(&opCopy, _destination + arrayLengthOffset,
            highOffset, size_t.sizeof);
        emit(&opSubtract, _destination + arrayLengthOffset,
            lowOffset, size_t.sizeof);

        const byteOffsetOffset = reserveTemp(pointerFacts);
        emit(&opCopy, byteOffsetOffset, lowOffset, size_t.sizeof);
        const elementFacts = TypeFacts.of(expression.e1.type.nextOf);
        const elementSizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, elementSizeOffset,
            addConstant(cast(long) elementFacts.size), size_t.sizeof);
        emit(&opMultiply, byteOffsetOffset, elementSizeOffset,
            size_t.sizeof);

        const pointerOffset = reserveTemp(pointerFacts);
        emit(&opCopy, pointerOffset, sourcePointerOffset, size_t.sizeof);
        emit(&opAdd, pointerOffset, byteOffsetOffset, size_t.sizeof);
        emit(&opCopy, _destination + arrayPointerOffset,
            pointerOffset, size_t.sizeof);
    }

    // `arr[]`: dmd's own `foreach` lowering over an array takes a bare
    // whole-array slice of it before iterating, to fix the range being
    // walked against mutation of the original variable during the loop.
    // A dynamic array's whole slice is the same two words as the array
    // itself, so it does not need the bounds work of a bounded slice.
    override void visit(SliceExp expression) {
        requireDestination(expression);

        if (planSlice(expression).yieldsStaticArray) {
            const address = compileSlicePointer(expression);
            emit(&opLoadIndirect, _destination, address, _width);
            return;
        }
        compileSliceHeader(expression);
    }

    // The address of the elements a slice names, as a word in a temporary.
    private size_t compileSlicePointer(SliceExp expression) {
        import snakebite.nativelayout: arrayPointerOffset, arrayValueSize;

        const sliceFacts = TypeFacts(
            arrayValueSize, size_t.alignof, false, false, true,
            TypeFacts.of(expression.e1.type.toBasetype.nextOf).size,
        );
        const header = reserveTemp(sliceFacts);

        const destination = _destination;
        const width = _width;
        scope (exit) {
            _destination = destination;
            _width = width;
        }
        _destination = header;
        _width = arrayValueSize;
        compileSliceHeader(expression);
        return header + arrayPointerOffset;
    }

    private void compileSliceHeader(SliceExp expression) {
        import dmd.astenums: TY;
        import std.conv: text;

        auto sourceType = expression.e1.type.toBasetype;
        final switch (sourceType.ty) with (TY) {
            case Tpointer:
                return compilePointerSlice(expression, sourceType);
            case Tsarray:
                return compileStaticArraySlice(expression, sourceType);
            case Tarray:
                return compileDynamicArraySlice(expression, sourceType);
            case Taarray, Treference, Tfunction, Tident, Tclass, Tstruct,
                Tenum, Tdelegate, Tnone, Tvoid, Tint8, Tuns8, Tint16,
                Tuns16, Tint32, Tuns32, Tint64, Tuns64, Tfloat32, Tfloat64,
                Tfloat80, Timaginary32, Timaginary64, Timaginary80,
                Tcomplex32, Tcomplex64, Tcomplex80, Tbool, Tchar, Twchar,
                Tdchar, Terror, Tinstance, Ttypeof, Ttuple, Tslice, Treturn,
                Tnull, Tvector, Tint128, Tuns128, Ttraits, Tmixin,
                Tnoreturn, Ttag:
                assert(0, text("`", expression.toString, "` slices a `",
                    sourceType.toString, "`: semantic slices only a ",
                    "pointer or an array at run time, a vector through its ",
                    "`.array` and an aggregate through `opSlice`"));
        }
    }

    // Semantic requires both bounds to slice a pointer.
    private void compilePointerSlice(SliceExp expression, Type sourceType) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;

        assert(expression.upr !is null);
        const facts = TypeFacts.of(sourceType);
        const pointerOffset = reserveTemp(facts);
        evalInto(expression.e1, pointerOffset, facts.size);

        const lowOffset = reserveTemp(pointerFacts);
        if (expression.lwr is null)
            emit(&opConstant, lowOffset, addConstant(0), size_t.sizeof);
        else
            evalOperandInto(expression.lwr, lowOffset, size_t.sizeof);

        const highOffset = reserveTemp(pointerFacts);
        evalOperandInto(expression.upr, highOffset, size_t.sizeof);

        const plan = planSlice(expression);
        if (plan.checkOrder) {
            const lengthOffset = reserveTemp(pointerFacts);
            emit(&opConstant, lengthOffset, addConstant(0), size_t.sizeof);
            compileSliceCheck(
                lowOffset, highOffset,
                [
                    Arg(lowOffset, 0, size_t.sizeof),
                    Arg(highOffset, 0, size_t.sizeof),
                    Arg(lengthOffset, 0, size_t.sizeof),
                ],
                expression.loc,
            );
        }

        emit(&opSubtract, highOffset, lowOffset, size_t.sizeof);
        emit(&opCopy, _destination + arrayLengthOffset, highOffset,
            size_t.sizeof);

        const elementFacts = TypeFacts.of(sourceType.nextOf);
        const elementSizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, elementSizeOffset,
            addConstant(cast(long) elementFacts.size), size_t.sizeof);
        emit(&opMultiply, lowOffset, elementSizeOffset, size_t.sizeof);
        emit(&opAdd, pointerOffset, lowOffset, size_t.sizeof);
        emit(&opCopy, _destination + arrayPointerOffset, pointerOffset,
            size_t.sizeof);
    }

    private void compileStaticArraySlice(
        SliceExp expression, Type sourceType,
    ) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;

        const dim = cast(size_t) sourceType.isTypeSArray.dim.toInteger;

        // A bounded static-array slice has no length word to read back,
        // but its result still has the native dynamic-array shape. Use the
        // dimension from the static type as its source length.
        if (expression.lwr !is null || expression.upr !is null) {
            const sourceLengthOffset = reserveTemp(pointerFacts);
            emit(&opConstant, sourceLengthOffset,
                addConstant(cast(long) dim), size_t.sizeof);
            const addressOffset = compileAddress(expression.e1);
            compileBoundedSlice(
                expression, sourceLengthOffset, addressOffset);
            return;
        }

        // `xs[]`: a static array's own whole-array slice, dmd's own
        // `foreach` lowering over one (see `dmd.statementsem`'s rewrite to
        // a `for` loop over `xs[]`) as well as an explicit one written by
        // hand. No bounds to check - the whole array is always in bounds
        // of itself - and no separate storage to point into: the result's
        // pointer word is `xs`'s own address, its length word `xs`'s own
        // dimension, known at compile time.
        const addressOffset = compileAddress(expression.e1);
        emit(&opConstant, _destination + arrayLengthOffset,
            addConstant(cast(long) dim), size_t.sizeof);
        emit(&opCopy, _destination + arrayPointerOffset,
            addressOffset, size_t.sizeof);
    }

    private void compileDynamicArraySlice(
        SliceExp expression, Type sourceType,
    ) {
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;

        if (expression.lwr is null && expression.upr is null) {
            evalInto(expression.e1, _destination, _width);
            return;
        }

        const facts = TypeFacts.of(sourceType);
        const arrayOffset = reserveTemp(facts);
        evalInto(expression.e1, arrayOffset, facts.size);

        compileBoundedSlice(
            expression,
            arrayOffset + arrayLengthOffset,
            arrayOffset + arrayPointerOffset);
    }

    // `arr[i]`, read as a value. The shared storage resolver computes where
    // that element actually lives; this only adds
    // the load once that address is in hand.
    override void visit(IndexExp expression) {
        if (_destination == discardResult) {
            const elementFacts = TypeFacts.of(expression.type);
            const offset = reserveTemp(elementFacts);
            evalInto(expression, offset, elementFacts.size);
            return;
        }

        requireDestination(expression);
        const addressOffset = compileAddress(expression);
        emit(&opLoadIndirect, _destination, addressOffset, _width);
    }

    // `[a, b, c]`. Every element is evaluated in order into the block this
    // allocates, even when every one of them happens to be a constant - dmd
    // already folds a genuinely compile-time-constant literal into
    // something this compiler need never see as an `ArrayLiteralExp` at
    // all, so one that does reach here may have an element like `x + 1`
    // that only evaluating can produce.
    //
    // The shared LoweringVisitor routes array literals without a lowering
    // here. Lowered literals use the allocation result as their element
    // storage and are completed below.
    protected override void visitUnloweredArrayLiteral(
            ArrayLiteralExp expression) {
        requireDestination(expression);
        import snakebite.nativelayout: isStoredLiteral;

        if (isStoredLiteral(expression))
            return compileConstant(expression);
        compileArrayLiteral(expression, _destination);
    }

    protected override void requireLiteralDestination(
            ArrayLiteralExp expression) {
        requireDestination(expression);
    }

    private struct TemporaryDestination {
        size_t offset;
        size_t width;
        Type type;
    }

    // The stack `withTemporaryDestination` pushes and pops. Each entry is
    // the *surrounding* (`_destination`, `_width`, `_valueType`)
    // destination saved before `_destination` was overwritten with the
    // temporary's own offset - it is what `storeConstant`/`storeAddress`/
    // `copyBytes` emit stores into, not the temporary itself.
    private TemporaryDestination[] _temporaryDestinations;

    // Reserves a temporary of `facts` and substitutes it for the ambient
    // (`_destination`, `_width`, `_valueType`) destination `run` (and
    // anything it compiles through this visitor) targets, restoring the
    // surrounding destination once `run` returns - the same save/reserve/
    // restore shape `evalInto` below already uses for a single expression,
    // generalised to an arbitrary sequence of them. Bytecode temporaries
    // are never released early: `reserveTemp` only ever grows this
    // function's frame past what `_layout` reserved.
    extern(D) protected override void withTemporaryDestination(
            Type type, in TypeFacts facts, scope void delegate() run) {
        auto destination = TemporaryDestination(
            _destination, _width, _valueType);
        _temporaryDestinations ~= destination;
        scope (exit) {
            _temporaryDestinations.length--;
            _destination = destination.offset;
            _width = destination.width;
            _valueType = destination.type;
        }

        _destination = reserveTemp(facts);
        _width = facts.size;
        _valueType = type;
        run();
    }

    // `_destination` is the innermost temporary's own offset; what it
    // *holds* is the pointer `_d_arrayliteralTX` (or the equivalent
    // lowering) copied there. Emits code that stores the element at
    // `byteOffset` from that held pointer, not from `_destination` itself.
    protected override void evaluateElement(
        Expression element, Type elementType, in TypeFacts facts,
        in size_t byteOffset,
    ) {
        const elementOffset = reserveTemp(facts);
        evalInto(element, elementOffset, facts.size, elementType);
        const addressOffset = reserveTemp(pointerFacts);
        emit(&opCopy, addressOffset, _destination, size_t.sizeof);
        if (byteOffset != 0) {
            const offset = reserveTemp(pointerFacts);
            emit(&opConstant, offset, addConstant(cast(long) byteOffset),
                size_t.sizeof);
            emit(&opAdd, addressOffset, offset, size_t.sizeof);
        }
        emit(&opStoreIndirect, addressOffset, elementOffset, facts.size);
    }

    // Valid only inside `withTemporaryDestination`'s `run` delegate: emits
    // a store of `value` at `byteOffset` into the surrounding destination
    // that call saved (`_temporaryDestinations[$ - 1]`), not into the
    // temporary.
    protected override void storeConstant(
        in size_t value, in size_t byteOffset,
    ) {
        assert(_temporaryDestinations.length > 0,
            "storeConstant needs an enclosing withTemporaryDestination");
        const destination = _temporaryDestinations[$ - 1];
        emit(&opConstant, destination.offset + byteOffset,
            addConstant(cast(long) value), size_t.sizeof);
    }

    // Valid only inside `withTemporaryDestination`'s `run` delegate: emits
    // a copy of the innermost temporary's *value* (the pointer it holds,
    // e.g. what `_d_arrayliteralTX` returned) to `byteOffset` in the
    // surrounding destination that call saved.
    protected override void storeAddress(in size_t byteOffset) {
        assert(_temporaryDestinations.length > 0,
            "storeAddress needs an enclosing withTemporaryDestination");
        const destination = _temporaryDestinations[$ - 1];
        emit(&opCopy, destination.offset + byteOffset,
            _destination, size_t.sizeof);
    }

    // Valid only inside `withTemporaryDestination`'s `run` delegate: emits
    // a copy of `width` bytes from the address the innermost temporary
    // holds into the surrounding destination that call saved (a static
    // array's own bytes, not a pointer to them).
    protected override void copyBytes(in size_t width) {
        assert(_temporaryDestinations.length > 0,
            "copyBytes needs an enclosing withTemporaryDestination");
        const destination = _temporaryDestinations[$ - 1];
        emit(&opLoadIndirect, destination.offset, _destination, width);
    }

    // An associative-array literal has no glue-layer codegen of its own:
    // dmd's semantic pass lowers it to a call to
    // `object._d_assocarrayliteralTX!(K, V)` (`AssocArrayLiteralExp.lowering`),
    // built from the key and value expressions the guest wrote as ordinary
    // `ArrayLiteralExp`s. Compiling `lowering` runs that call through the
    // ordinary `CallExp` path, which resolves it as already-compiled
    // druntime code the same way any other native call is resolved -
    // never a hash table this compiler builds itself.
    protected override void visitUnloweredAssocArrayLiteral(
            AssocArrayLiteralExp expression) {
        assert(0, "dmd lowers every associative array literal "
            ~ "(`tryLowerAALiteral`) or reports the missing hook");
    }

    private struct NewDestination {
        size_t offset;
        size_t width;
        Type type;
    }

    private NewDestination[] _newDestinations;

    // `LoweringVisitor.visit(NewExp)` routes `onstack` and `placement` to
    // `visitUnloweredNew` before ever calling this, matching dmd's own glue
    // layer (`glue/e2ir.d`, `if (ne.onstack || ne.placement)`); a heap
    // `NewExp` with `thisexp` set (a nested class's own construction)
    // reaches here like any other and its context is filled in
    // `compileNew`, via `planClassContext`.
    protected override void prepareNew(NewExp expression) {
        prepareNewDestination(expression);
    }

    private void prepareNewDestination(NewExp expression) {
        // Type must stay mutable for destination restoration.
        auto destination = NewDestination(
            _destination, _width, _valueType);
        const facts = TypeFacts.of(expression.type);
        const temporary = reserveTemp(facts);
        _newDestinations ~= destination;
        _destination = temporary;
        _width = facts.size;
        _valueType = expression.type;
    }

    protected override void restoreNew() {
        auto destination = _newDestinations[$ - 1]; // Keeps Type mutable.
        _newDestinations.length--;
        _destination = destination.offset;
        _width = destination.width;
        _valueType = destination.type;
    }

    protected override void visitUnloweredNew(
        NewExp expression, NewPlan plan,
    ) {
        if (plan.destination == NewPlan.Destination.lowering)
            assert(0, "dmd lowers every heap `new` of a class that is not "
                ~ "a `scope class`, outside a `ctfe` or `-betterC` scope");

        prepareNewDestination(expression);
        scope (exit) restoreNew;

        if (plan.destination == NewPlan.Destination.placement) {
            const address = compileAddress(plan.placement);
            emit(&opCopy, _destination, address, size_t.sizeof);
        } else {
            assert(plan.destination == NewPlan.Destination.stack
                && plan.objectKind == NewPlan.ObjectKind.class_);
            auto classType = expression.newtype.toBasetype.isTypeClass;
            assert(classType !is null);
            auto declaration = classType.sym;
            auto runtime = _bytecode.classRuntimeInfo(declaration);
            const alignment = declaration.alignsize == 0
                ? 1 : declaration.alignsize;
            const object = reserveTemp(
                TypeFacts(declaration.structsize, alignment));
            emit(&opStaticLoad, object, cast(size_t) runtime.m_init.ptr,
                runtime.m_init.length);
            emit(&opFrameAddress, _destination, object, size_t.sizeof);
        }

        if (plan.objectKind == NewPlan.ObjectKind.class_
                && plan.destination == NewPlan.Destination.placement) {
            auto classType = expression.newtype.toBasetype.isTypeClass;
            assert(classType !is null);
            auto declaration = classType.sym;
            auto runtime = _bytecode.classRuntimeInfo(declaration);
            const image = reserveTemp(TypeFacts(
                runtime.m_init.length, declaration.alignsize == 0
                    ? 1 : declaration.alignsize));
            emit(&opStaticLoad, image, cast(size_t) runtime.m_init.ptr,
                runtime.m_init.length);
            emit(&opStoreIndirect, _destination, image,
                runtime.m_init.length);
        }

        visitLoweredNew(expression);
    }

    protected override void visitLoweredNew(NewExp expression) {
        import dmd.astenums: Tpointer;
        auto newType = expression.newtype.toBasetype;
        if (newType.isTypeClass !is null || newType.isTypeStruct !is null)
            compileNew(expression);
        else if (expression.type.toBasetype.ty == Tpointer
                && expression.arguments !is null
                && expression.arguments.length != 0) {
            if (expression.arguments.length != 1)
                assert(0, "dmd rejects `new T(a, b)` for a scalar `T`");
            const facts = TypeFacts.of(expression.newtype);
            const valueOffset = reserveTemp(facts);
            evalInto((*expression.arguments)[0], valueOffset, facts.size);
            emit(&opStoreIndirect, _destination, valueOffset, facts.size);
        }

        const destination = _newDestinations[$ - 1];
        if (destination.offset != discardResult)
            emit(&opCopy, destination.offset, _destination, _width);
    }

    // DMD leaves constructor and positional field initialization outside
    // the allocation lowering. Its result already occupies _destination.
    // `driveInit` (`aggregateinit.d`) owns the order the `vthis` steps, the
    // constructor call, and the remaining positional field stores run in -
    // a nested struct's or nested class's `vthis` sits inside the
    // allocation the lowering just returned, at the same native offset a
    // value of that aggregate type would use, filled before either the
    // constructor call or the remaining field stores, so both a
    // `new Adder(2)` with a constructor and a bare `new Reader` (no
    // arguments at all) get a real context rather than `.init`'s zero.
    private void compileNew(NewExp expression) {
        import snakebite.backends.aggregateinit:
            driveInit, planClassContext, planNew, planPositionalFields;

        auto newPlan = planNew(expression);
        auto structType = expression.newtype.toBasetype.isTypeStruct;
        const objectOffset = _destination;
        const storage = indirectStorage(objectOffset);

        auto plan = structType is null
            ? planClassContext(expression)
            : planPositionalFields(structType.sym,
                expression.member is null ? expression.arguments : null);

        auto hooks = AggregateInitHooks(this, storage);
        driveInit(hooks, plan, expression.member !is null,
            () {
                if (newPlan.argumentPrefix !is null)
                    compileEffectInCurrentLifetime(
                        newPlan.argumentPrefix);
                compileResolvedCall(
                    expression.member, expression.arguments, expression.loc,
                    expressionText(expression), true, () => objectOffset,
                    discardResult);
            });
    }

    override void visit(DeleteExp expression) {
        import snakebite.backends.deleteplan: planDelete;

        auto deletion = planDelete(expression);
        const object = reserveTemp(pointerFacts);
        evalInto(deletion.object, object, size_t.sizeof);
        auto plan = planOf(_bytecode._plans, deletion.hook);
        _callSites ~= CallSite.native(plan,
            [Arg(object, 0, size_t.sizeof)], 0);
        emit(&opCall, discardResult, _callSites.length - 1, 0);
    }

    // `null` is all-zero bytes whatever it means - a pointer, a class
    // reference, an associative array, or a dynamic array's `{length,
    // pointer}` pair - so this fills the destination's own width with
    // zero rather than asking `expression.type` what shape to write.
    // `expression.type` is not always the destination's own type: dmd
    // infers an `auto`-return function's return type from every `return`
    // statement together, so an earlier `return null;` before a later
    // `return` of the real pointer type keeps `typeof(null)` on its own
    // `NullExp` even once the function's inferred return type is settled
    // - `_width`, supplied by whichever caller is evaluating this `null`
    // into a destination, is what actually applies here.
    override void visit(NullExp expression) {
        requireDestination(expression);

        emit(&opZero, _destination, 0, _width);
    }

    override void visit(ClassReferenceExp expression) {
        compileConstant(expression);
    }

    override void visit(TypeidExp expression) {
        import dmd.dtemplate: isExpression, isType;
        import std.conv: text;

        requireDestination(expression);

        if (auto value = isExpression(expression.obj)) {
            evalInto(value, _destination, size_t.sizeof);
            const indirections = 2
                + (value.type.toBasetype.isTypeClass.sym
                    .isInterfaceDeclaration !is null);
            foreach (i; 0 .. indirections)
                emit(&opLoadIndirect, _destination, _destination, size_t.sizeof);
            return;
        }

        auto type = isType(expression.obj);
        if (!(type !is null && type.vtinfo !is null))
            assert(0, "`TypeidExp` semantic leaves a type with its `TypeInfo`");

        emitRuntimeTypeInfoConstant(type);
    }

    private void emitRuntimeTypeInfoConstant(
        Type type,
        in size_t destination = size_t.max,
        in size_t width = size_t.max,
    ) {
        emitTypeInfoConstant(
            _bytecode._runtimeTypes.get(type), destination, width);
    }

    private void emitTypeInfoConstant(
        TypeInfo info,
        in size_t destination = size_t.max,
        in size_t width = size_t.max,
    ) {
        auto address = cast(void*) info;

        emit(&opConstant,
            destination == size_t.max ? _destination : destination,
            addConstant(cast(long) cast(size_t) address),
            width == size_t.max ? _width : width);
    }

    override void visit(CallExp expression) {
        if (_destination != discardResult && isRefCall(expression)) {
            const addressOffset = compileAddress(expression);
            emit(&opLoadIndirect, _destination, addressOffset, _width);
            return;
        }

        compileCall(expression, _destination);
    }

    // Whether `expression` calls a `ref`-returning function, resolved
    // (`expression.f`) or through a function pointer's own `TypeFunction`
    // - both `visit(CallExp)` and `compileAddress`'s `CallExp` case need
    // this same answer to know whether the call's result is a value or an
    // address to load through.
    private bool isRefCall(CallExp expression) {
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto functionType = typeFunctionOf(expression);
        return functionType !is null && functionType.isRef;
    }

    // `assert(x)`, run at statement level for its effect alone - it has no
    // value for anything to read, so unlike every other expression here,
    // this ignores `_destination` rather than requiring one.
    override void visit(AssertExp expression) {
        compileAssert(expression);
    }

    protected override void visitHalt() {
        const never = reserveTemp(pointerFacts);
        emit(&opConstant, never, addConstant(0), size_t.sizeof);
        emit(&opAssert, never, haltSite, size_t.sizeof);
        _finished = true;
    }

    override void visit(AssignExp expression) {
        compileAssign(expression, _destination);
    }

    override void visit(BlitExp expression) {
        compileAssign(expression, _destination);
    }

    protected override void visitUnloweredConstruct(ConstructExp expression) {
        compileAssign(expression, _destination);
    }

    override void visit(BinAssignExp expression) {
        compileCompoundAssign(expression, _destination);
    }

    // `~=` appending a `dchar` (`CatDcharAssignExp`) never gets a
    // `.lowering`: dmd's semantic pass builds one only for `CatAssignExp`'s
    // other two operators (see `LoweringVisitor.visit(CatAssignExp)`),
    // leaving this case's UTF-8/UTF-16 encoding to glue-layer codegen
    // alone, which calls `_d_arrayappendcd`/`_d_arrayappendwd` by linker
    // symbol with no `FuncDeclaration` behind it - so, unlike every other
    // `~=` lowering here, there is no `CallExp` this compiler could walk
    // through the ordinary native-call path. This resolves and calls that
    // same hook directly, through the same `rawPlanOf`/`CallSite.native`
    // shape `compileBoundsHook` already uses for a druntime hook dmd
    // never resolves to a `FuncDeclaration`, the same symbol a real
    // build's glue layer would call. The hook takes `x` by `ref` and
    // appends into it in place, so its own return value (that same
    // `{length, pointer}` pair again) is never read back here - the call
    // itself runs with its result discarded, and `opLoadIndirect` reads
    // the updated pair straight out of `x`'s own storage instead.
    override void visitUnloweredCatDcharAssign(CatDcharAssignExp expression) {
        import dmd.astenums: Tchar, Twchar;
        import snakebite.nativelayout: arrayValueSize;

        auto elementType = expression.e1.type.nextOf;
        assert(elementType !is null);
        const elementBase = elementType.toBasetype;
        assert(elementBase.ty == Tchar || elementBase.ty == Twchar);
        const hook = elementBase.ty == Twchar
            ? DruntimeHook.arrayAppendWchar : DruntimeHook.arrayAppendChar;
        auto plan = planOf(_bytecode._plans, hook);

        const arrayOffset = compileAddress(expression.e1);

        const valueFacts = TypeFacts.of(expression.e2.type);
        const valueOffset = reserveTemp(valueFacts);
        evalInto(expression.e2, valueOffset, valueFacts.size);

        _callSites ~= CallSite.native(
            cast(const(void)*) plan,
            [
                Arg(arrayOffset, 0, size_t.sizeof),
                Arg(valueOffset, 0, valueFacts.size),
            ],
            0,
        );
        emit(&opCall, discardResult, _callSites.length - 1, 0);

        if (_destination != discardResult)
            emit(&opLoadIndirect, _destination, arrayOffset, arrayValueSize);
    }

    protected override void visitUnloweredCat(CatExp expression) {
        assert(0, "dmd lowers every `~` outside a `-betterC` scope "
            ~ "(`trySetCatExpLowering`)");
    }

    override void visit(PostExp expression) {
        compilePost(expression, _destination);
    }

    override void visit(DotTypeExp expression) {
        if (_destination == discardResult)
            compileEffect(expression.e1);
        else
            evalInto(expression.e1, _destination, _width);
    }

    override void visit(CommaExp expression) {
        import dmd.sideeffect: hasSideEffect;

        compileEffect(expression.e1);
        if (_destination != discardResult) {
            evalInto(expression.e2, _destination, _width);
            return;
        }

        // `arr.length = 0` lowers to `(arr = arr[0 .. 0], 0)` (see
        // `expressionsem.d`'s `visitAssign`'s `ArrayLengthExp` case): the
        // trailing `0` only carries the assignment's own result type,
        // dropped here the same way dmd's own frontend drops it for a
        // statement-level assignment. A tail without side effects needs no
        // code, so it is skipped.
        if (hasSideEffect(expression.e2))
            compileEffect(expression.e2);
    }

    protected override void visitUnloweredCast(CastExp expression) {
        import dmd.astenums: Tvoid;

        // `cast(void) call();`: dmd's own `foreach`-over-associative-array
        // lowering casts `_d_aaApply2`'s `int` result to `void` when the
        // loop's own value is never read, the same discard a bare
        // `call();` statement already gets through `compileEffect` - only
        // here `expression.e1` sits behind an explicit `CastExp` instead of
        // being the statement's own expression. A `void` cast produces no
        // value, so running `expression.e1` for effect is everything this
        // cast means.
        if (_destination == discardResult && expression.type.ty == Tvoid) {
            compileEffect(expression.e1);
            return;
        }

        requireDestination(expression);
        compileCast(expression, _destination, _width);
    }

    override void visit(NotExp expression) {
        requireDestination(expression);
        compileNot(expression, _destination);
        widenBoolean;
    }

    override void visit(LogicalExp expression) {
        compileLogical(expression, _destination, _width);
        widenBoolean;
    }

    // `!`, `&&`, `||` and the comparisons write one byte, the width of the
    // `bool` they have in D. In C their type is `int`, and the bytes that
    // the byte does not cover must not keep what the slot held before.
    private void widenBoolean() {
        if (_destination != discardResult && _width > 1)
            emit(&opCastWidenUnsigned, _destination, 1, _width);
    }

    override void visit(CondExp expression) {
        if (_destination == discardResult) {
            compileTernary(expression, discardResult, 0);
            return;
        }

        requireDestination(expression);
        compileTernary(expression, _destination, _width);
    }

    protected override void visitComparison(
        CmpExp expression, in ComparisonPlan plan,
    ) {
        requireDestination(expression);
        compileComparison(expression, plan, _destination);
        if (plan.kind != ComparisonPlan.Kind.vector)
            widenBoolean;
    }

    protected override void visitUnloweredEqual(EqualExp expression) {
        requireDestination(expression);
        compileEquality(expression);
        if (comparisonPlan(expression).kind != ComparisonPlan.Kind.vector)
            widenBoolean;
    }

    private void compileEquality(EqualExp expression) {
        const plan = comparisonPlan(expression);
        with (ComparisonPlan.Kind) final switch (plan.kind) {
            case dynamicArray:
                return compileMemcmpDynamicArrayEquality(
                    expression, _destination);
            // A delegate is a plain `{context, function}` pair - dmd's own
            // native equality for it, like a static array's, is exactly its
            // bytes compared whole. `compileStaticArrayEquality` does
            // nothing but that byte compare, sizing each operand from its
            // own type, so operands of different sizes compare unequal.
            case staticArray, delegate_:
                return compileStaticArrayEquality(expression, _destination);
            case integral, floating, complex, reference, vector:
                return compileComparison(expression, plan, _destination);
        }
    }

    override protected void visitIdentity(
        IdentityExp expression, in IdentityPlan plan,
    ) {
        requireDestination(expression);
        compileIdentity(expression, plan, _destination);
    }

    override void visit(NegExp expression) {
        requireDestination(expression);
        compileUnary(expression, _destination, _width, &opNegate);
    }

    override void visit(ComExp expression) {
        requireDestination(expression);
        compileUnary(expression, _destination, _width, &opComplement);
    }

    override void visit(AddExp expression) {
        compileBinaryExpression(expression, &opAdd);
    }

    override void visit(MinExp expression) {
        compileBinaryExpression(expression, &opSubtract);
    }

    override void visit(MulExp expression) {
        compileBinaryExpression(expression, &opMultiply);
    }

    override void visit(AndExp expression) {
        compileBinaryExpression(expression, &opBitAnd);
    }

    override void visit(OrExp expression) {
        compileBinaryExpression(expression, &opBitOr);
    }

    override void visit(XorExp expression) {
        compileBinaryExpression(expression, &opBitXor);
    }

    override void visit(ShlExp expression) {
        compileShiftExpression(expression);
    }

    override void visit(UshrExp expression) {
        compileShiftExpression(expression);
    }

    override void visit(ShrExp expression) {
        compileShiftExpression(expression);
    }

    override void visit(DivExp expression) {
        compileSignedBinaryExpression(
            expression, &opDivideSigned, &opDivideUnsigned);
    }

    override void visit(ModExp expression) {
        compileSignedBinaryExpression(
            expression, &opModuloSigned, &opModuloUnsigned);
    }

    extern(D):

    // An expression evaluated for no result still runs, once and in order,
    // so its operands' side effects happen: it computes into a scratch
    // slot nobody reads. The restoring of `_destination` and `_width` is
    // up to whoever set them (`evalInto`, `compileEffect`).
    private void requireDestination(Expression expression) {
        if (_destination != discardResult)
            return;

        const facts = TypeFacts.of(expression.type);
        _destination = reserveTemp(facts);
        _width = facts.size;
        _valueType = expression.type;
    }

    private void compileBinaryExpression(
        BinExp expression, Instruction.Handler handler,
    ) {
        requireDestination(expression);
        compileBinary(expression, _destination, _width, handler);
    }

    private void compileShiftExpression(BinExp expression) {
        import snakebite.backends.shifts: shiftPlan;

        compileBinaryExpression(
            expression, shiftHandler(shiftPlan(expression)));
    }

    private void compileSignedBinaryExpression(
        BinExp expression,
        Instruction.Handler signedHandler,
        Instruction.Handler unsignedHandler,
    ) {
        const handler = TypeFacts.of(expression.e1.type).isUnsigned
            ? unsignedHandler : signedHandler;
        compileBinaryExpression(expression, handler);
    }

    // `+`, `-`, `*`, `&`, `|`, `^`, `<<`, `>>`, `>>>`, `/`, `%`: both
    // operands are evaluated into temporaries of their own - never
    // `destOffset` directly, which can already be a variable either
    // operand itself reads (`x = y + x`; evaluating `y` straight into
    // `x`'s own slot would clobber `x` before it is read for the right
    // operand) - then combined in place with `handler`, already the
    // right one for this operator and, where it matters, this
    // expression's own signedness (decided by the caller, which knows
    // which operator this is; this compiler has no per-operator table of
    // its own to keep in step with the VM's opcodes). The answer is
    // copied out to `destOffset` only when it differs from the left
    // operand's own temporary.
    private void compileBinary(
        BinExp expression, in size_t destOffset, in size_t width,
        Instruction.Handler handler,
    ) {
        import snakebite.backends.arithmetic:
            ArithmeticPlan, arithmeticKind, arithmeticPlan;
        import std.conv: text;

        const plan = arithmeticPlan(expression);
        with (ArithmeticPlan.Kind) final switch (plan.kind) {
            case integral: {
                const leftOffset = reserveTemp(plan.facts);
                evalOperandInto(expression.e1, leftOffset, width);
                const rightOffset = reserveTemp(plan.facts);
                evalOperandInto(expression.e2, rightOffset, width);
                emit(handler, leftOffset, rightOffset, width);
                return copyResult(destOffset, leftOffset, width);
            }

            case floating: {
                const leftOffset = reserveTemp(plan.facts);
                evalInto(expression.e1, leftOffset, plan.facts.size);
                const rightOffset = reserveTemp(plan.facts);
                evalInto(expression.e2, rightOffset, plan.facts.size);
                emit(floatingBinaryHandler(expression), leftOffset,
                    rightOffset, plan.facts.size);
                return copyResult(destOffset, leftOffset, width);
            }

            case complex: {
                const leftFacts = TypeFacts.of(expression.e1.type);
                const leftOffset = reserveTemp(plan.facts);
                evalInto(expression.e1, leftOffset, leftFacts.size);
                const rightFacts = TypeFacts.of(expression.e2.type);
                const rightOffset = reserveTemp(rightFacts);
                evalInto(expression.e2, rightOffset, rightFacts.size);
                emit(complexHandler(expression), leftOffset, rightOffset,
                    plan.facts.size / 2, plan.operands.packed);
                return copyResult(destOffset, leftOffset, width);
            }

            case vector: {
                const leftOffset = reserveTemp(plan.facts);
                evalInto(expression.e1, leftOffset, plan.facts.size);
                const rightOffset = reserveTemp(plan.facts);
                evalInto(expression.e2, rightOffset, plan.facts.size);
                emitLanes(laneHandler(expression, plan, handler), plan,
                    leftOffset, rightOffset);
                return copyResult(destOffset, leftOffset, width);
            }

            case pointerOffset: {
                assert(handler is &opAdd || handler is &opSubtract,
                    text("`", expressionText(expression), "`: D only adds ",
                        "an offset to a pointer or subtracts one"));
                const pointerLeft =
                    arithmeticKind(expression.e1.type) == pointerOffset;
                auto pointerOperand =
                    pointerLeft ? expression.e1 : expression.e2;
                auto offsetOperand =
                    pointerLeft ? expression.e2 : expression.e1;
                const leftOffset = reserveTemp(plan.facts);
                evalInto(pointerOperand, leftOffset, plan.facts.size);
                const rightOffset = reserveTemp(plan.facts);
                evalOperandInto(offsetOperand, rightOffset, plan.facts.size);
                emit(handler, leftOffset, rightOffset, plan.facts.size);
                return copyResult(destOffset, leftOffset, width);
            }

            // `p2 - p1`: dmd's own semantic pass (`MinExp::semantic`)
            // already wraps the subtraction in a `DivExp` by the pointee's
            // size, so this leaves the raw byte count for that division.
            case pointerDifference: {
                assert(handler is &opSubtract, text("`",
                    expressionText(expression), "`: D only subtracts one ",
                    "pointer from another"));
                const leftOffset = reserveTemp(pointerFacts);
                evalInto(expression.e1, leftOffset, pointerFacts.size);
                const rightOffset = reserveTemp(pointerFacts);
                evalInto(expression.e2, rightOffset, pointerFacts.size);
                emit(&opSubtract, leftOffset, rightOffset, pointerFacts.size);
                return copyResult(destOffset, leftOffset, width);
            }
        }
    }

    // The operation on one lane of a vector: `handler` for an integral
    // lane, the floating operation for a floating one.
    private Instruction.Handler laneHandler(
        BinExp expression,
        in imported!"snakebite.backends.arithmetic".ArithmeticPlan plan,
        Instruction.Handler integralHandler,
    ) {
        import snakebite.backends.arithmetic: ArithmeticPlan;
        import std.conv: text;

        with (ArithmeticPlan.Kind) final switch (plan.laneKind) {
            case integral:
                return integralHandler;
            case floating:
                return floatingBinaryHandler(expression);
            case complex, pointerOffset, pointerDifference, vector:
                assert(0, text("`", expressionText(expression), "` has a ",
                    "lane that is neither integral nor floating"));
        }
    }

    // Applies `handler` to each lane of the vectors at `left` and `right`,
    // leaving the answer at `left`.
    private void emitLanes(
        Instruction.Handler handler,
        in imported!"snakebite.backends.arithmetic".ArithmeticPlan plan,
        in size_t left, in size_t right,
    ) {
        const laneSize = plan.laneFacts.size;
        foreach (i; 0 .. plan.facts.size / laneSize)
            emit(handler, left + i * laneSize, right + i * laneSize,
                laneSize);
    }

    private void copyResult(
        in size_t destOffset, in size_t resultOffset, in size_t width,
    ) {
        if (destOffset != resultOffset)
            emit(&opCopy, destOffset, resultOffset, width);
    }

    private Instruction.Handler floatingBinaryHandler(BinExp expression) {
        import std.conv: text;

        with (EXP) switch (expression.op) {
            case add, addAssign, plusPlus: return &opFloatAdd;
            case min, minAssign, minusMinus: return &opFloatSubtract;
            case mul, mulAssign: return &opFloatMultiply;
            case div, divAssign: return &opFloatDivide;
            case mod, modAssign: return &opFloatModulo;
            default:
                assert(0, text("`", expressionText(expression), "`: dmd ",
                    "rejects bitwise and shift operators on floating ",
                    "operands"));
        }
    }

    // Evaluates `operand` for use as one side of a binary opcode that
    // reads both its operands at one shared `width` - `compileBinary`'s
    // own opcodes, whose `Instruction` has only one `width` field for
    // both. Every operator's own usual arithmetic conversions already
    // give both operands `width` except a shift's right side, which
    // keeps its own, possibly narrower, type (`x << (someByte + 1)`) -
    // evaluating it as if it already had `width` bytes reserved, the way
    // `evalInto`'s `VarExp` case does verbatim, would `opCopy` bytes past
    // whatever narrower storage actually holds it. This evaluates the
    // operand at its own type's width first, then widens or narrows the
    // same temporary in place to `width` - the same conversion a cast to
    // `width` bytes performs, because that is exactly what reading a
    // narrower or wider operand as this opcode's shared width means.
    private void evalOperandInto(
        Expression operand, in size_t destOffset, in size_t width,
    ) {
        import std.conv: text;

        const operandFacts = TypeFacts.of(operand.type);
        assert(operandFacts.isIntegral && isIntegralSize(operandFacts.size),
            text("`", expressionText(operand), "`: semantic types every ",
                "index, slice bound and integral operand as an integer"));

        if (operandFacts.size == width) {
            evalInto(operand, destOffset, width);
            return;
        }

        if (operandFacts.size < width && operand.isIntegerExp) {
            // A literal needs no run-time conversion: store it at `width`.
            Type literalType = operandFacts.isUnsigned
                ? (width == 8 ? Type.tuns64 : Type.tuns32)
                : (width == 8 ? Type.tint64 : Type.tint32);
            if (TypeFacts.of(literalType).size == width) {
                evalInto(operand, destOffset, width, literalType);
                return;
            }
        }

        if (operandFacts.size < width) {
            evalInto(operand, destOffset, operandFacts.size);
            emit(
                operandFacts.isUnsigned
                    ? &opCastWidenUnsigned : &opCastWidenSigned,
                destOffset, operandFacts.size, width,
            );
            return;
        }

        const temp = reserveTemp(operandFacts);
        evalInto(operand, temp, operandFacts.size);
        emit(&opCopy, destOffset, temp, width);
    }

    // `<`, `<=`, `>`, `>=`, `==`, `!=`: both operands are read into
    // temporaries of their own common width - not necessarily
    // `destOffset`'s own width, since the result is always a one-byte
    // `bool` - and the comparison opcode leaves its answer in the first
    // of those, copied out to `destOffset` only when it differs.
    private void compileComparison(
        BinExp expression, in ComparisonPlan plan, in size_t destOffset,
    ) {
        import std.conv: text;

        const operandFacts = plan.facts;

        with (ComparisonPlan.Kind) final switch (plan.kind) {
            // A class reference compares the same way a pointer does - `is`/
            // `==` on two references is identity, the same one pointer width
            // `opEqual` already reads either way; only `is`/`!is` (`identity`/
            // `notIdentity`) are legal D syntax for a class reference, but the
            // handler map below already answers those the same as `==`/`!=`.
            case reference: {
                Instruction.Handler pointerHandler;
                with (EXP) switch (expression.op) {
                    case lessThan:
                        pointerHandler = &opLessThanUnsigned;
                        break;
                    case lessOrEqual:
                        pointerHandler = &opLessOrEqualUnsigned;
                        break;
                    case greaterThan:
                        pointerHandler = &opGreaterThanUnsigned;
                        break;
                    case greaterOrEqual:
                        pointerHandler = &opGreaterOrEqualUnsigned;
                        break;
                    case equal, identity: pointerHandler = &opEqual; break;
                    case notEqual, notIdentity: pointerHandler = &opNotEqual;
                        break;
                    default: assert(0);
                }

                const leftOffset = reserveTemp(operandFacts);
                evalInto(expression.e1, leftOffset, operandFacts.size);
                const rightOffset = reserveTemp(operandFacts);
                evalInto(expression.e2, rightOffset, operandFacts.size);
                emit(pointerHandler, leftOffset, rightOffset, operandFacts.size);

                if (destOffset != leftOffset)
                    emit(&opCopy, destOffset, leftOffset, 1);
                return;
            }

            // Host floating-point operators preserve D's NaN and signed-zero
            // semantics for equality and ordering. Integral equality instead
            // compares the stored bits, which would make a NaN equal itself and
            // positive and negative zero unequal.
            case floating: {
                auto floatHandler = floatComparisonHandler(expression);

                const floatLeftOffset = reserveTemp(operandFacts);
                evalInto(expression.e1, floatLeftOffset, operandFacts.size);
                const floatRightOffset = reserveTemp(operandFacts);
                evalInto(expression.e2, floatRightOffset, operandFacts.size);
                emit(floatHandler, floatLeftOffset, floatRightOffset,
                    operandFacts.size);

                if (destOffset != floatLeftOffset)
                    emit(&opCopy, destOffset, floatLeftOffset, 1);
                return;
            }

            // D does not order complex values, so only `==`/`!=` reach
            // here: both halves compare, and the answers combine.
            case complex: {
                const half = operandFacts.size / 2;
                auto halfHandler = floatComparisonHandler(expression);
                const leftOffset = reserveTemp(operandFacts);
                evalInto(expression.e1, leftOffset, operandFacts.size);
                const rightOffset = reserveTemp(operandFacts);
                evalInto(expression.e2, rightOffset, operandFacts.size);
                emit(halfHandler, leftOffset, rightOffset, half);
                emit(halfHandler, leftOffset + half, rightOffset + half, half);
                emit(expression.op == EXP.equal ? &opBitAnd : &opBitOr,
                    leftOffset, leftOffset + half, 1);

                if (destOffset != leftOffset)
                    emit(&opCopy, destOffset, leftOffset, 1);
                return;
            }

            case vector:
                return compileVectorComparison(expression, plan, destOffset);

            case dynamicArray, staticArray:
                assert(0, text("`", expressionText(expression), "` cannot ",
                    "reach here: dmd lowers array ordering to `__cmp`, and ",
                    "array equality is a byte compare"));

            case delegate_:
                return compileDelegateOrdering(expression, destOffset);

            case integral: {
                assert(operandFacts.isIntegral
                        && isIntegralSize(operandFacts.size),
                    text("`", expressionText(expression), "`: `kindOf` ",
                        "gives `integral` only to 1, 2, 4 and 8 byte ",
                        "integers"));

                auto handler = comparisonHandler(expression, operandFacts.isUnsigned);

                const leftOffset = reserveTemp(operandFacts);
                evalInto(expression.e1, leftOffset, operandFacts.size);
                const rightOffset = reserveTemp(operandFacts);
                evalInto(expression.e2, rightOffset, operandFacts.size);
                emit(handler, leftOffset, rightOffset, operandFacts.size);

                if (destOffset != leftOffset)
                    emit(&opCopy, destOffset, leftOffset, 1);
                return;
            }
        }
    }

    private Instruction.Handler floatComparisonHandler(BinExp expression) {
        import std.conv: text;

        with (EXP) switch (expression.op) {
            case lessThan: return &opFloatLessThan;
            case lessOrEqual: return &opFloatLessOrEqual;
            case greaterThan: return &opFloatGreaterThan;
            case greaterOrEqual: return &opFloatGreaterOrEqual;
            case equal: return &opFloatEqual;
            case notEqual: return &opFloatNotEqual;
            default:
                assert(0, text("`", expressionText(expression), "`: dmd ",
                    "builds a `CmpExp` or `EqualExp` only for these ",
                    "operators"));
        }
    }

    // A delegate orders as one unsigned integer whose high word is its
    // function pointer: `a < b` is `fa < fb || fa == fb && pa < pb`, and
    // likewise for the other orderings.
    private void compileDelegateOrdering(
        BinExp expression, in size_t destOffset,
    ) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset;
        import std.conv: text;

        const facts = TypeFacts.delegateValue;
        const left = reserveTemp(facts);
        evalInto(expression.e1, left, facts.size);
        const right = reserveTemp(facts);
        evalInto(expression.e2, right, facts.size);

        Instruction.Handler strict;
        with (EXP) switch (expression.op) {
            case lessThan, lessOrEqual:
                strict = &opLessThanUnsigned;
                break;
            case greaterThan, greaterOrEqual:
                strict = &opGreaterThanUnsigned;
                break;
            default:
                assert(0, text("`", expressionText(expression), "`: dmd ",
                    "builds a `CmpExp` only for the four orderings"));
        }
        auto low = comparisonHandler(expression, true);

        const highOrdered = reserveTemp(pointerFacts);
        emit(&opCopy, highOrdered, left + delegateFunctionOffset,
            size_t.sizeof);
        emit(strict, highOrdered, right + delegateFunctionOffset,
            size_t.sizeof);
        const highEqual = reserveTemp(pointerFacts);
        emit(&opCopy, highEqual, left + delegateFunctionOffset,
            size_t.sizeof);
        emit(&opEqual, highEqual, right + delegateFunctionOffset,
            size_t.sizeof);
        const lowOrdered = reserveTemp(pointerFacts);
        emit(&opCopy, lowOrdered, left + delegateContextOffset,
            size_t.sizeof);
        emit(low, lowOrdered, right + delegateContextOffset, size_t.sizeof);

        emit(&opBitAnd, highEqual, lowOrdered, 1);
        emit(&opBitOr, highOrdered, highEqual, 1);
        emit(&opCopy, destOffset, highOrdered, 1);
    }

    // Each result lane is all-ones where the operands' lanes compare true.
    private void compileVectorComparison(
        BinExp expression, in ComparisonPlan plan, in size_t destOffset,
    ) {
        import std.conv: text;

        const leftOffset = reserveTemp(plan.facts);
        evalInto(expression.e1, leftOffset, plan.facts.size);
        const rightOffset = reserveTemp(plan.facts);
        evalInto(expression.e2, rightOffset, plan.facts.size);

        Instruction.Handler handler;
        with (ComparisonPlan.Kind) final switch (plan.laneKind) {
            case floating:
                handler = floatComparisonHandler(expression);
                break;
            case integral:
                handler = comparisonHandler(
                    expression, plan.laneFacts.isUnsigned);
                break;
            case complex, reference, vector, dynamicArray, staticArray,
                delegate_:
                assert(0, text("`", expressionText(expression), "` has a ",
                    "vector lane that is neither integral nor floating"));
        }

        const laneSize = plan.laneFacts.size;
        const lanes = plan.facts.size / laneSize;
        const resultLaneSize = TypeFacts.of(expression.type).size / lanes;
        const laneOffset = reserveTemp(plan.laneFacts);
        foreach (i; 0 .. lanes) {
            emit(&opCopy, laneOffset, leftOffset + i * laneSize, laneSize);
            emit(handler, laneOffset, rightOffset + i * laneSize, laneSize);
            emit(&opCastWidenUnsigned, laneOffset, 1, resultLaneSize);
            emit(&opNegate, laneOffset, 0, resultLaneSize);
            emit(&opCopy, destOffset + i * resultLaneSize, laneOffset,
                resultLaneSize);
        }
    }

    // DMD's identity lowering is a native byte comparison.  The shared
    // plan supplies its width, including the real's non-padding bytes.
    private void compileIdentity(
        IdentityExp expression, in IdentityPlan plan, in size_t destOffset,
    ) {
        import dmd.tokens: EXP;
        import snakebite.nativelayout: arrayValueSize;

        if (plan.skipCompare) {
            emit(&opConstant, destOffset,
                addConstant(expression.op == EXP.identity ? 1 : 0), 1);
            return;
        }

        const facts = TypeFacts.of(expression.e1.type);
        const arrayFacts = TypeFacts(
            arrayValueSize, size_t.alignof, false, false, true, 0);
        const leftOffset = reserveTemp(plan.staticArray
            ? arrayFacts
            : facts);
        const rightOffset = reserveTemp(plan.staticArray
            ? arrayFacts
            : facts);
        if (plan.staticArray) {
            import snakebite.nativelayout:
                arrayLengthOffset, arrayPointerOffset;
            const leftAddress = plan.leftStorage
                ? compileIdentityArrayStorage(expression.e1, facts)
                : compileAddress(expression.e1);
            const rightAddress = plan.rightStorage
                ? compileIdentityArrayStorage(expression.e2, facts)
                : compileAddress(expression.e2);
            emit(&opConstant, leftOffset + arrayLengthOffset,
                addConstant(cast(long) plan.length), size_t.sizeof);
            emit(&opConstant, rightOffset + arrayLengthOffset,
                addConstant(cast(long) plan.length), size_t.sizeof);
            emit(&opCopy, leftOffset + arrayPointerOffset, leftAddress,
                size_t.sizeof);
            emit(&opCopy, rightOffset + arrayPointerOffset, rightAddress,
                size_t.sizeof);
        } else {
            evalInto(expression.e1, leftOffset, facts.size);
            evalInto(expression.e2, rightOffset, facts.size);
        }
        emit(&opStaticArrayEqual, leftOffset, rightOffset, plan.width);
        if (expression.op == EXP.notIdentity)
            emit(&opLogicalNot, leftOffset, 0, 1);
        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, 1);
    }

    private size_t compileIdentityArrayStorage(
        Expression expression, in TypeFacts facts,
    ) {
        const valueOffset = reserveTemp(facts);
        evalInto(expression, valueOffset, facts.size);
        const addressOffset = reserveTemp(pointerFacts);
        emit(&opFrameAddress, addressOffset, valueOffset, size_t.sizeof);
        return addressOffset;
    }

    // DMD leaves EqualExp.lowering null only when its semantic pass approved
    // bytewise element equality. All other array equality runs through that
    // lowering instead of entering this fast path.
    private void compileMemcmpDynamicArrayEquality(
        EqualExp expression, in size_t destOffset,
    ) {
        import dmd.tokens: EXP;
        import snakebite.nativelayout: arrayValueSize;

        assert(expression.lowering is null);

        const arrayFacts = TypeFacts(
            arrayValueSize, size_t.alignof, false, false, true, 0);
        const elementFacts = TypeFacts.of(expression.e1.type.nextOf);

        const leftOffset = reserveTemp(arrayFacts);
        evalArrayValueInto(expression.e1, leftOffset);
        const rightOffset = reserveTemp(arrayFacts);
        evalArrayValueInto(expression.e2, rightOffset);

        emit(&opArrayEqual, leftOffset, rightOffset, elementFacts.size);
        if (expression.op == EXP.notEqual)
            emit(&opLogicalNot, leftOffset, 0, 1);
        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, 1);
    }

    // A static array operand becomes the `{length, ptr}` value of its own
    // elements, as dmd's `e2ir.d` reads it for a mixed array comparison.
    private void evalArrayValueInto(Expression operand, in size_t destOffset) {
        import dmd.astenums: Tarray;
        import dmd.expressionsem: toInteger;
        import dmd.typesem: toBasetype;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, arrayValueSize;

        auto type = operand.type.toBasetype;
        if (type.ty == Tarray) {
            evalInto(operand, destOffset, arrayValueSize);
            return;
        }

        const address = compileIdentityArrayStorage(
            operand, TypeFacts.of(type));
        emit(&opConstant, destOffset + arrayLengthOffset,
            addConstant(cast(long) type.isTypeSArray.dim.toInteger),
            size_t.sizeof);
        emit(&opCopy, destOffset + arrayPointerOffset, address,
            size_t.sizeof);
    }

    // dmd's semantic pass (`expressionsem.d`'s `shouldUseMemcmp`, guarding
    // the `object.__equals` lowering) treats `T[N] == T[N]` exactly as it
    // treats `T[] == T[]`: whenever the element type is not safely
    // memcmp-able, the whole `EqualExp` is rewritten into an `__equals`
    // call before this compiler ever sees it. A plain `EqualExp` reaching
    // here with `lowering is null` is therefore already one dmd itself
    // would compare byte for byte - the same guarantee
    // `compileMemcmpDynamicArrayEquality` relies on for `T[]`.
    //
    // Unlike that dynamic-array sibling, there is no pointer word to read
    // first: `expression.e1`/`e2` are already the whole array's own bytes
    // once evaluated (`arrayLengthOffset`/`arrayPointerOffset` name a
    // dynamic array's two-word header, and a static array has none), so
    // this compares that many bytes directly.
    private void compileStaticArrayEquality(
        EqualExp expression, in size_t destOffset,
    ) {
        import dmd.tokens: EXP;

        assert(expression.lowering is null);

        const leftFacts = TypeFacts.of(expression.e1.type);
        const rightFacts = TypeFacts.of(expression.e2.type);

        const leftOffset = reserveTemp(leftFacts);
        evalInto(expression.e1, leftOffset, leftFacts.size);
        const rightOffset = reserveTemp(rightFacts);
        evalInto(expression.e2, rightOffset, rightFacts.size);

        if (leftFacts.size != rightFacts.size) {
            emit(&opConstant, destOffset,
                addConstant(expression.op == EXP.notEqual), 1);
            return;
        }

        emit(&opStaticArrayEqual, leftOffset, rightOffset, leftFacts.size);
        if (expression.op == EXP.notEqual)
            emit(&opLogicalNot, leftOffset, 0, 1);
        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, 1);
    }

    private Instruction.Handler comparisonHandler(
        BinExp expression, in bool unsigned,
    ) {
        with (EXP) switch (expression.op) {
            case lessThan:
                return unsigned ? &opLessThanUnsigned : &opLessThanSigned;
            case lessOrEqual:
                return unsigned
                    ? &opLessOrEqualUnsigned : &opLessOrEqualSigned;
            case greaterThan:
                return unsigned
                    ? &opGreaterThanUnsigned : &opGreaterThanSigned;
            case greaterOrEqual:
                return unsigned
                    ? &opGreaterOrEqualUnsigned : &opGreaterOrEqualSigned;
            case equal:
                return &opEqual;
            case notEqual:
                return &opNotEqual;
            default: assert(0);
        }
    }

    // `-x`, `~x`: evaluates the operand directly into `destOffset`, then
    // applies `handler` in place.
    private void compileUnary(
        UnaExp expression, in size_t destOffset, in size_t width,
        Instruction.Handler handler,
    ) {
        import snakebite.backends.arithmetic: ArithmeticPlan, arithmeticPlan;
        import std.conv: text;

        const plan = arithmeticPlan(expression);
        with (ArithmeticPlan.Kind) final switch (plan.kind) {
            case integral:
                evalInto(expression.e1, destOffset, width);
                emit(handler, destOffset, 0, width);
                return;

            case floating:
                assert(handler is &opNegate, text("`",
                    expressionText(expression), "`: dmd rejects `~` on a ",
                    "floating operand"));
                evalInto(expression.e1, destOffset, width);
                emit(&opFloatNegate, destOffset, 0, width);
                return;

            case complex:
                assert(handler is &opNegate, text("`",
                    expressionText(expression), "`: dmd rejects `~` on a ",
                    "complex operand"));
                evalInto(expression.e1, destOffset, width);
                emit(&opComplexNegate, destOffset, 0, width / 2);
                return;

            case vector: {
                evalInto(expression.e1, destOffset, width);
                const laneSize = plan.laneFacts.size;
                Instruction.Handler laneHandler;
                final switch (plan.laneKind) {
                    case integral:
                        laneHandler = handler;
                        break;
                    case floating:
                        assert(handler is &opNegate, text("`",
                            expressionText(expression), "`: dmd rejects ",
                            "`~` on floating lanes"));
                        laneHandler = &opFloatNegate;
                        break;
                    case complex, pointerOffset, pointerDifference, vector:
                        assert(0, text("`", expressionText(expression),
                            "` has a lane that is neither integral nor ",
                            "floating"));
                }
                foreach (i; 0 .. plan.facts.size / laneSize)
                    emit(laneHandler, destOffset + i * laneSize, 0, laneSize);
                return;
            }

            case pointerOffset, pointerDifference:
                assert(0, text("`", expressionText(expression), "`: D has ",
                    "no unary arithmetic on a pointer"));
        }
    }

    // `!x`: evaluated the same way any other condition is - `compileCondition`
    // already knows how to reduce a dynamic array operand to its pointer
    // word alone, which this needs exactly as much as `if`/`while` do -
    // then reduced to a single-byte `bool` the same way a comparison is,
    // copied out to `destOffset` only when the temporary is not already it.
    private void compileNot(NotExp expression, in size_t destOffset) {
        const operandOffset = compileCondition(expression.e1);
        const width = conditionWidth(expression.e1);
        emit(&opLogicalNot, operandOffset, 0, width);

        if (destOffset != operandOffset)
            emit(&opCopy, destOffset, operandOffset, 1);
    }

    // `&&`/`||`: dmd does not cast either operand to `bool` - `yes() &&
    // five()`, `five()` returning a plain `int`, is legal and tests
    // `five()` for nonzero the same way an `if`'s own condition does - so
    // each operand is evaluated at its own type's width (`compileCondition`,
    // the same helper `if`/`while`/`for`/the ternary already use), never
    // at this expression's own one-byte `bool` width: evaluating an `int`
    // operand there would truncate it to its low byte before testing it,
    // and evaluating a call there would have `compileCall` write the
    // callee's full return width into a one-byte slot. A branch skips the
    // right operand exactly when D's own short-circuit rule says to -
    // `&&` skips it once the left side is already false, `||` once it is
    // already true - and whichever operand actually decided the answer is
    // then reduced to a proper `bool` and copied out to `destOffset`.
    private void compileLogical(
        LogicalExp expression, in size_t destOffset, in size_t width,
    ) {
        const leftOffset = compileCondition(expression.e1);
        const leftWidth = conditionWidth(expression.e1);

        const branchIndex = _instructions.length;
        auto shortCircuit = expression.op == EXP.andAnd
            ? &opBranchFalse : &opBranchTrue;
        emit(shortCircuit, leftOffset, 0, leftWidth);

        if (destOffset == discardResult) {
            compileEffect(expression.e2);
            _instructions[branchIndex].source = _instructions.length;
            return;
        }

        // The left side did not decide the answer: the right side's own
        // truthiness does.
        const rightOffset = compileCondition(expression.e2);
        const rightWidth = conditionWidth(expression.e2);
        emit(&opCastToBool, rightOffset, 0, rightWidth);
        if (destOffset != rightOffset)
            emit(&opCopy, destOffset, rightOffset, 1);
        const jumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);

        // Short-circuited: the left side decided the answer by itself.
        _instructions[branchIndex].source = _instructions.length;
        emit(&opCastToBool, leftOffset, 0, leftWidth);
        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, 1);

        _instructions[jumpIndex].destination = _instructions.length;
    }

    // `cond ? a : b`: only the branch the condition selects at run time
    // is ever evaluated, the same as `if`/`else`.
    private void compileTernary(
        CondExp expression, in size_t destOffset, in size_t width,
    ) {
        const conditionOffset = compileCondition(expression.econd);
        const conditionWidth_ = conditionWidth(expression.econd);

        const branchIndex = _instructions.length;
        emit(&opBranchFalse, conditionOffset, 0, conditionWidth_);

        _finished = false;
        evalInto(expression.e1, destOffset, width);
        const ifFinished = _finished;
        size_t jumpIndex = size_t.max;
        if (!ifFinished) {
            jumpIndex = _instructions.length;
            emit(&opJump, 0, 0, 0);
        }

        _instructions[branchIndex].source = _instructions.length;
        _finished = false;
        evalInto(expression.e2, destOffset, width);
        const elseFinished = _finished;
        if (jumpIndex != size_t.max)
            _instructions[jumpIndex].destination = _instructions.length;
        _finished = ifFinished && elseFinished;
    }

    // `cast(T) x`. `snakebite.backends.casts.classify` has already turned
    // the source and destination types into a `Kind`; this is the
    // adapter that executes each one, with no type inspection of its
    // own. `cast(bool)` is not a narrowing: dmd classifies `bool` as an
    // integral type, so a plain low-byte truncation would answer
    // `cast(bool) 256` as `false` rather than D's own `true`. A cast
    // that does not change width is a reinterpretation of the same bits
    // - `cast(uint)` of an `int`, say - so it just evaluates the operand
    // straight into `destOffset`. `plan.kind` is already `CastKind`, so
    // each arm below just names its own kind twice: once to match
    // `plan.kind`, once to pick `opCastAs`'s instance of it - the
    // second naming is what turns a run-time `plan.kind` into a
    // compile-time template argument, not a translation between two
    // enums.
    private void compileCast(
        CastExp expression, in size_t destOffset, in size_t width,
    ) {
        import snakebite.backends.casts: classify;
        import std.conv: text;

        auto sourceType = expression.e1.type;
        // `.im` on a `complex` value is dmd's own `e.castTo(sc,
        // timaginaryN)` (`typesem.d`'s `Id.im` case for `Tcomplex*`)
        // with the resulting node's `.type` then overwritten straight
        // to the matching `Tfloat*` - a same-size reinterpret with no
        // `CastExp` of its own, done directly on the expression
        // `castTo` already built. `.type` is that overwritten field;
        // `.to` still names the cast `castTo` actually performed, so
        // it is the one `classify` has to see to tell that apart from
        // `.re`, whose `.to` and `.type` agree.
        auto destType =
            expression.to !is null ? expression.to : expression.type;

        const plan = classify(expression.e1, destType);

        // Every kind below is only a transformation of the operand's
        // own already-evaluated (or already-addressed) bytes into
        // `destOffset`'s - `snakebite.nativevalue.applyCastAs`, reached
        // here through `opCastAs`'s own instance of `plan.kind`, is the
        // one place that carries each of them out; this compiler only
        // ever decides where the operand's bytes already live and
        // which of `width`/`sourceWidth` on the instruction it emits
        // carries which of `applyCastAs`'s sizes - `castSizeWithSigned
        // ness` packs a signedness bit into one of them for the four
        // kinds that need one, the same way `opCastWidenSigned`'s own
        // `source` field already carries a size rather than an offset.
        // `copy`, `classReference`, and `zero` are not: a plain
        // reinterpret needs no transformation at all, and the other
        // two each need this compiler's own control flow, so they still
        // emit their own bytecode
        // below.
        final switch (plan.kind) with (CastKind) {
        case copy:
            return evalInto(expression.e1, destOffset, width);

        case classReference: {
            evalInto(expression.e1, destOffset, width);
            if (plan.referenceOffset == 0)
                return;
            const skip = _instructions.length;
            emit(&opBranchFalse, destOffset, 0, width);
            const adjustment = reserveTemp(pointerFacts);
            emit(&opConstant, adjustment,
                addConstant(plan.referenceOffset), size_t.sizeof);
            emit(&opAdd, destOffset, adjustment, size_t.sizeof);
            patchTarget(skip, _instructions.length);
            return;
        }

        case zero:
            if (expression.e1.isNullExp is null)
                compileEffect(expression.e1);
            emit(&opZero, destOffset, 0, width);
            return;

        // Each of these kinds reads its whole evaluated operand out of one
        // temporary; `emitPackedCast` knows which two sizes, and which one
        // signedness, the instruction carries for each.
        case complexToBool:
        case complexToReal:
        case complexToImaginary:
        case complexToIntegral:
        case complexWidth:
        case realToComplex:
        case imaginaryToComplex:
        case integralToComplex:
        case floatToIntegral:
        case integralToFloat:
        case floatToPointer:
        case pointerToFloat:
        case floatToBool: {
            const sourceOffset = reserveTemp(plan.sourceFacts);
            evalInto(expression.e1, sourceOffset, plan.sourceFacts.size);
            emitPackedCast(plan, destOffset, sourceOffset);
            return;
        }

        case floatWidth: {
            const sourceOffset = plan.sourceFacts.size > plan.destFacts.size
                ? reserveTemp(plan.sourceFacts) : destOffset;
            evalInto(expression.e1, sourceOffset, plan.sourceFacts.size);
            emitPackedCast(plan, destOffset, sourceOffset);
            return;
        }

        // A pointer's native address bits already sit in a
        // pointer-sized temporary: `pointerToArray` copies
        // `destFacts.size` of them starting at that address, and
        // `pointerToIntegral` truncates them to `destFacts.size`
        // bytes in place, the same truncation a narrowing integral
        // cast performs.
        case pointerToArray:
        case pointerToIntegral: {
            const addressOffset = reserveTemp(pointerFacts);
            evalInto(expression.e1, addressOffset, plan.sourceFacts.size);
            emit(castOp(plan.kind), destOffset, addressOffset,
                plan.destFacts.size);
            return;
        }

        // `cast(void*) someDelegate`: `applyCastAs` reads the same
        // context word `dg.ptr` itself reads (`compileDelegateWord`
        // below), out of a temporary holding the delegate's own two
        // words. `sliceToPointer` reads the matching word out of a
        // slice's own two.
        case delegateToPointer:
        case sliceToPointer: {
            const sourceOffset = reserveTemp(plan.sourceFacts);
            evalInto(expression.e1, sourceOffset, plan.sourceFacts.size);
            emit(castOp(plan.kind), destOffset, sourceOffset,
                plan.destFacts.size);
            return;
        }

        // `compileAddress` hands back a slot holding the operand's own
        // address - the same shape `evalInto` leaves an ordinary
        // value in, just with that address as its "value" - so
        // `applyCastAs` reads it back the same way for both.
        case sarrayToSlice: {
            const addressOffset = compileAddress(expression.e1);
            emit(&opCastAs!(CastKind.sarrayToSlice), destOffset,
                addressOffset, plan.staticLength);
            return;
        }

        case sarrayToPointer: {
            const addressOffset = compileAddress(expression.e1);
            emit(&opCastAs!(CastKind.sarrayToPointer), destOffset,
                addressOffset, plan.destFacts.size);
            return;
        }

        // D reinterprets the same bytes at the new element width, so
        // the byte count - not the element count - is what has to
        // stay the same across the cast; `applyCastAs` scales the
        // source's own length by the ratio of the two element sizes,
        // both compile-time constants already on `plan`.
        case reinterpretSlice: {
            const arrayOffset = reserveTemp(plan.sourceFacts);
            evalInto(expression.e1, arrayOffset, plan.sourceFacts.size);
            emit(&opCastAs!(CastKind.reinterpretSlice), destOffset,
                arrayOffset, plan.destFacts.elementSize,
                plan.sourceFacts.elementSize);
            return;
        }

        // `narrow` reads its operand into a full-width temporary
        // first, since truncating straight into a narrower
        // `destOffset` while evaluating would overrun it; `toBool`/
        // `widenSigned`/`widenUnsigned` never widen past their
        // operand's own width while evaluating it, so they can
        // evaluate straight into `destOffset` and cast it in place.
        // `emit`'s own peephole still substitutes `opCastFixedAs` for
        // all four once it sees `width`/`sourceWidth` are one of the
        // four D integral sizes, comparing the handler by identity -
        // `castOp(plan.kind)` below returns the same `&opCastAs!kind`
        // a case arm naming only its own kind would.
        case narrow: {
            const temp = reserveTemp(plan.sourceFacts);
            evalInto(expression.e1, temp, plan.sourceFacts.size);
            emit(&opCastAs!(CastKind.narrow), destOffset, temp,
                plan.destFacts.size, plan.sourceFacts.size);
            return;
        }

        case toBool:
        case widenSigned:
        case widenUnsigned: {
            evalInto(expression.e1, destOffset, plan.sourceFacts.size);
            emit(castOp(plan.kind), destOffset, destOffset,
                plan.destFacts.size, plan.sourceFacts.size);
            return;
        }

        }
    }

    // `plan.kind` above is a run-time value inside every arm several
    // kinds share, so it cannot itself be `opCastAs`'s own
    // compile-time template argument the way naming
    // `CastKind.someKind` literally in a single-kind arm can - this is
    // what turns it back into one, the same `&opCastAs!kind` instance
    // a case arm with only that one label would name directly.
    // `copy`, `classReference`, and `zero` never reach here:
    // `compileCast`'s own arms for them return without falling into an
    // arm that calls this.
    private Instruction.Handler castOp(in CastKind kind) {
        import std.traits: EnumMembers;

        final switch (kind) with (CastKind) {
        case copy:
        case classReference:
        case zero:
            assert(0);
        static foreach (member; EnumMembers!CastKind) {
            static if (member != copy && member != classReference
                    && member != zero)
                case member:
                    return &opCastAs!member;
        }
        }
    }

    // Whether `expression` has to reach `callee` through the receiver's
    // own dynamic type rather than `callee` itself - `override`s a base
    // class's or an interface's method, and dmd left this call able to
    // reach any of them. `expression.directcall` is dmd's own answer for
    // whether it already proved otherwise (a `final` method, a call
    // through `super`, ...); a constructor is never virtual to begin
    // with, so `callee.isVirtualMethod` already excludes it without this
    // needing its own check.
    private bool isVirtualCall(CallExp expression, FuncDeclaration callee) {
        import dmd.astenums: Tclass;
        import snakebite.backends.checkplan: readsVtable;

        if (!expression.readsVtable(callee))
            return false;

        auto dot = expression.e1.isDotVarExp;
        return dot !is null && dot.e1.type.toBasetype.ty == Tclass;
    }

    // A call reached through the receiver's own dynamic type: `callee`
    // only names dmd's statically-resolved target, the method a base
    // class or an interface declares, never the guest override that
    // actually runs. `compileClassVtableSlot`
    // read the real one back out of the object at run time, into a
    // temporary this reuses the same `CallSite.indirect` shape
    // `compileIndirectCall` already built for a function-pointer value -
    // the receiver's dynamic type decides which compiled callee that
    // slot holds, at a compile time this compiler cannot know, but every
    // override still shares the one calling convention `callee`'s own
    // declared parameters describe (D requires an override's signature to
    // match), so `calleeLayout`, `FrameLayout.of(callee)`, still answers
    // where `this` and each argument belong.
    private void compileVirtualCall(
        CallExp expression, FuncDeclaration callee, in size_t destOffset,
    ) {
        import dmd.astenums: STC, Tvoid, VarArg;
        import snakebite.backends.calls: arityMismatches;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto dot = expression.e1.isDotVarExp;

        auto calleeType = typeFunctionOf(callee);
        if (arityMismatches(calleeType.parameterList, expression.arguments,
                calleeType.parameterList.varargs == VarArg.variadic))
            assert(0, "dmd rejects a call with the wrong number of arguments");

        auto returnType = calleeType.next;
        const isVoidCallee = returnType is null || returnType.ty == Tvoid;
        const returnFacts =
            isVoidCallee ? TypeFacts.init
                : calleeType.isRef ? pointerFacts : TypeFacts.of(returnType);
        if (isVoidCallee && destOffset != discardResult)
            assert(0, "a `void` call is only ever evaluated for effect");

        const objectOffset = reserveTemp(pointerFacts);
        evalInto(dot.e1, objectOffset, size_t.sizeof);

        const calleeSlotOffset = reserveTemp(pointerFacts);
        auto calleeLayout = FrameLayout.ofParameters(calleeType, true);
        Arg[] args;
        args ~= Arg(
            objectOffset, calleeLayout.hiddenThis.parameter.offset,
            size_t.sizeof,
        );

        auto site = compileIndirectArguments(
            calleeType, expression.arguments, calleeLayout, args,
            calleeSlotOffset, isVoidCallee ? 0 : returnFacts.size,
            /* hasContext */ true);
        compileNullCheck(objectOffset, expression.loc);
        compileClassVtableSlot(
            expression, objectOffset, callee, calleeSlotOffset);
        const siteIndex = _callSites.length;
        _callSites ~= site;
        emit(&opCall, destOffset, siteIndex, 0);
    }

    // `callee`'s own compiled override, read out of the object's instance
    // vtable at its declared `vtblIndex` - `classRuntimeInfo` already laid
    // that table out in the same slots dmd itself assigns every virtual
    // method. For a plain D class `vtbl[0]` is the classinfo pointer, so
    // a real method index there is never `0`; for an `extern(C++)` class
    // (`ClassDeclaration.vtblOffset` returns `0`, not `1` - the Itanium
    // ABI has no classinfo slot) the very first virtual method is itself
    // at index `0`, so only a negative index - `isVirtualMethod` false -
    // is ever wrong. This is nothing more than the same pointer
    // arithmetic `compileFieldAddress` already does for a field's own
    // offset, just through the object's vptr instead of the object
    // itself.
    private void compileClassVtableSlot(
        Expression expression, in size_t objectOffset, FuncDeclaration callee,
        in size_t calleeOffset,
    ) {
        const index = callee.vtblIndex;
        if (index < 0)
            assert(0,
                "dmd gives every virtual method a vtbl slot");

        const vptrOffset = reserveTemp(pointerFacts);
        emit(&opLoadIndirect, vptrOffset, objectOffset, size_t.sizeof);

        const slotOffset = reserveTemp(pointerFacts);
        emit(&opConstant, slotOffset,
            addConstant(cast(long) (index * size_t.sizeof)), size_t.sizeof);
        emit(&opAdd, slotOffset, vptrOffset, size_t.sizeof);

        emit(&opLoadIndirect, calleeOffset, slotOffset, size_t.sizeof);
    }

    // Compiles a call to `expression.f`: every argument evaluated into a
    // temporary of this function's own, in the callee's parameter order,
    // then one `opCall` naming the call site those temporaries and the
    // compiled callee are recorded under. `destOffset` is `discardResult`
    // for a call run at statement level, whose result (`void` or
    // otherwise) is discarded.
    private void compileCall(CallExp expression, in size_t destOffset) {
        import snakebite.frontend.dmd.functions: unresolvedCalleeOf;

        auto callee = expression.f;
        if (callee is null)
            callee = unresolvedCalleeOf(expression);
        // `super(args)`/`this(args)` constructor delegation reaches here
        // the same as any other call: dmd's own semantic pass always
        // resolves `expression.f` to the constructor it picked. A `null`
        // `callee` falls through to `compileIndirectCall`, which rejects
        // a bare `SuperExp`/`ThisExp` `e1` on its own terms - that shape
        // is not a function pointer or delegate value to call through.
        if (callee is null)
            return compileIndirectCall(expression, destOffset);

        callee = _bytecode.definitionOf(callee);
        if (isVirtualCall(expression, callee))
            return compileVirtualCall(expression, callee, destOffset);

        // `hasHiddenThis` reflects `needThis()`: true for an ordinary
        // member method and also for a nested function or lambda that
        // reads an outer method's `this` implicitly (`receiverOffsetOf`
        // then reaches that `this` through the static chain), and forces
        // `functionSemantic3` first so it stays reliable on a native
        // declaration this compiler never walks the body of - `Exception.
        // this` is one, reached through `super(...)` delegation from a
        // guest exception constructor.
        import snakebite.frontend.dmd.delegates: hasHiddenThis;

        const hasThis = hasHiddenThis(callee);
        compileResolvedCall(
            callee, expression.arguments, expression.loc,
            expressionText(expression), hasThis,
            () => receiverOffsetOf(expression, callee, destOffset),
            destOffset);
    }

    // The address of `callee`'s own hidden `this` argument for `expression`
    // - a bound method's receiver, a delegating `super(args)`/`this(args)`
    // constructor call's, or the `this` a nested function reads implicitly
    // from an enclosing member function. `compileResolvedCall`'s native and
    // guest branches alike call this at most once, only when `callee`
    // actually reserves a slot for it.
    private size_t receiverOffsetOf(
        CallExp expression, FuncDeclaration callee, in size_t destOffset,
    ) {
        const first = firstContextOffsetOf(expression, callee, destOffset);
        const plan = pairPlanOf(_function, callee, expression.vthis2);
        return plan.variable is null ? first : storeContextPair(plan, first);
    }

    // Fills the pair in the storage of its variable and returns its
    // address, the hidden argument of a callee with two contexts. `first`
    // is a frame slot that holds word 0.
    private size_t storeContextPair(in PairPlan plan, in size_t first) {
        const pairAddress = addressOfVariable(cast() plan.variable);
        emit(&opStoreIndirect, pointerAt(pairAddress, plan.receiverOffset),
            first, size_t.sizeof);
        emit(&opStoreIndirect, pointerAt(pairAddress, plan.outerOffset),
            contextOffsetOf(plan.outer), size_t.sizeof);
        return pairAddress;
    }

    private size_t pointerAt(in size_t address, in size_t offset) {
        return offset == 0 ? address : addPointerOffset(address, offset);
    }

    private size_t contextOffsetOf(in ContextSource source) {
        final switch (source.kind) with (ContextSource.Kind) {
        case none:
            const context = reserveTemp(pointerFacts);
            emit(&opConstant, context, addConstant(0), size_t.sizeof);
            return context;
        case frame:
            return contextAddressOf(cast() source.function_);
        case receiver:
            auto hidden = cast() source.function_.vthis;
            auto value = source.throughPair
                ? loadWordAt(hiddenSlotOffset(hidden), source.pairOffset)
                : hiddenThisOffset(hidden);
            foreach (const offset; source.fields)
                value = loadWordAt(value, offset);
            return value;
        case overrider:
            const word = reserveTemp(pointerFacts);
            emit(&opCopy, word, hiddenThisOffset, size_t.sizeof);
            if (source.receiverAdjustment != 0) {
                const adjustment = reserveTemp(pointerFacts);
                emit(&opConstant, adjustment,
                    addConstant(cast(long) source.receiverAdjustment),
                    size_t.sizeof);
                emit(&opAdd, word, adjustment, size_t.sizeof);
            }
            const address = reserveTemp(pointerFacts);
            emit(&opFrameAddress, address, word, size_t.sizeof);
            return addPointerOffset(address, -cast(long) source.slotOffset);
        }
    }

    private size_t loadWordAt(in size_t address, in size_t offset) {
        const word = reserveTemp(pointerFacts);
        emit(&opLoadIndirect, word, pointerAt(address, offset), size_t.sizeof);
        return word;
    }

    // `receiverOffsetOf` without the pair a dual-context callee adds
    // around it.
    private size_t firstContextOffsetOf(
        CallExp expression, FuncDeclaration callee, in size_t destOffset,
    ) {
        // A lambda or nested function reading `this` implicitly names an
        // outer member function's own hidden `this`, reached through the
        // static chain rather than through `expression.e1` - the same
        // reach `contextAddressOf` gives any other captured variable.
        if (callee.isThis is null)
            return contextOffsetOf(calleeContextSourceOf(_function, callee));

        // An ordinary bound method call wraps its receiver in a
        // `DotVarExp` (`expression.e1.isDotVarExp.e1`); `super(args)`/
        // `this(args)` constructor delegation instead leaves `expression.e1`
        // a bare `ThisExp`/`SuperExp` with no wrapper, the receiver being
        // this very function's own hidden `this` - `compileAddress`
        // resolves either shape, its own `ThisExp`/`SuperExp` case falling
        // back to `hiddenThisOffset` the same way the plain fallback below
        // does.
        auto dot = expression.e1.isDotVarExp;
        auto receiver = dot is null ? expression.e1 : dot.e1;

        if (receiver.type.toBasetype.isTypeClass !is null) {
            const object = reserveTemp(pointerFacts);
            evalInto(receiver, object, size_t.sizeof);
            return object;
        }

        if (dot !is null || receiver.isThisExp !is null
                || receiver.isSuperExp !is null)
            return compileAddress(receiver);

        // An ordinary method called with no explicit receiver at all
        // (`foo()` from inside another member of the same class) - sugar
        // for `this.foo()`.
        return hiddenThisOffset;
    }

    // Compiles a call to `callee` with `arguments` already resolved -
    // `compileCall`'s own dispatch for an ordinary `CallExp` and
    // `compileNew`'s call to the constructor a `NewExp` leaves
    // outside its own allocation lowering both reach this. The "allocate,
    // then call the constructor" split a `NewExp` makes is only about
    // where the receiver comes from, never about how the call itself is
    // compiled: `hasThis`/`thisOffsetOf` supply the receiver the same way
    // for either caller, read off `expression.e1` for an ordinary call or
    // already known as the freshly allocated object's own slot for a
    // constructor call. `thisOffsetOf` is only ever evaluated once, by
    // whichever branch below actually needs it.
    private void compileResolvedCall(
        FuncDeclaration callee,
        Expressions* arguments,
        Loc loc,
        string exprText,
        bool hasThis,
        size_t delegate() thisOffsetOf,
        in size_t destOffset,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        import snakebite.backends.calls: arityMismatches;

        size_t receiverOffset = size_t.max;
        if (hasThis)
            receiverOffset = thisOffsetOf();
        constructTemporary(callee,
            { emit(&opTemporarySuspend, 0, receiverOffset, 0); },
            { compileResolvedCallBody(callee, arguments, loc, exprText,
                hasThis, receiverOffset, destOffset); },
            { emit(&opTemporaryArm, 0, receiverOffset, 0); });
    }

    private void compileResolvedCallBody(
        FuncDeclaration callee,
        Expressions* arguments,
        Loc loc,
        string exprText,
        bool hasThis,
        size_t receiverOffset,
        size_t destOffset,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.backends.calls: arityMismatches;

        auto type = typeFunctionOf(callee);

        const hasNativeSymbol = _bytecode.hasNativeSymbol(callee);
        const decision = _bytecode._callSelection.decisionOf(
            callee, &_bytecode.isGuestFunction, hasNativeSymbol,
            _bytecode.hasIndependentNativeSymbol(callee),
        );
        final switch (decision.route) with (CallSelection.Route) {
        case native:
            Arg[] initialArgs;
            if (hasThis)
                initialArgs ~= Arg(receiverOffset, 0, size_t.sizeof);

            compileNativeCall(
                callee, type, arguments, loc, exprText, initialArgs,
                destOffset, hasNativeSymbol);
            return;
        case builtin:
            compileBuiltinCall(type, arguments, loc, exprText,
                destOffset, decision.builtinEntry,
                decision.destinationParameter);
            return;
        case vaStart:
            compileVaStart(type, arguments, loc, exprText,
                destOffset, decision.builtinEntry);
            return;
        case alloca:
            const size = reserveTemp(pointerFacts);
            evalInto((*arguments)[0], size, size_t.sizeof);
            emit(&opAlloca,
                destOffset == discardResult
                    ? reserveTemp(pointerFacts) : destOffset,
                size, size_t.sizeof);
            return;
        case guest:
            break;
        }
        auto calleeLayout = FrameLayout.of(callee);
        auto calleeType = typeFunctionOf(callee);

        if (arityMismatches(calleeType.parameterList, arguments,
                calleeType.parameterList.varargs == VarArg.variadic))
            assert(0, "dmd rejects a call with the wrong number of arguments");

        Arg[] args;
        // `calleeLayout.hiddenThis.variable`, not `hasThis`: a
        // `FuncLiteralDeclaration` bound through `auto` can keep a dead
        // `vthis` semantic proved nothing reads (see `FrameLayout.of`'s
        // own `hasDeadContext`), and `calleeLayout` is what actually
        // knows whether this callee's frame reserved it a slot.
        if (calleeLayout.hiddenThis.variable !is null) {
            if (!hasThis)
                assert(0,
                    "dmd binds a hidden `this` to every call of a method");

            args ~= Arg(
                receiverOffset,
                calleeLayout.hiddenThis.parameter.offset,
                size_t.sizeof,
            );
        }

        auto preparation = CallAdapter.Arguments.of(calleeType, arguments);
        args ~= compileGuestArguments(preparation, calleeLayout);

        if (calleeType.parameterList.varargs == VarArg.variadic)
            args ~= compileVariadicArguments(arguments, calleeLayout).guest;

        // A `ref` return hands the caller the callee's own returned
        // storage's address - `compileAddress`'s `CallExp` case is the one
        // place that address is read back out, and `compileIndirectAssign`
        // is the one place it is written through. The same shape decides a
        // native callee's own return place (`compileNativeCall`) and an
        // indirect one's (`compileIndirectCall`), so it is decided once,
        // by `CallAdapter`, rather than re-derived at each of the three.
        import snakebite.ffi.call: CallAdapter;

        const returnShape = CallAdapter.ofType(calleeType);
        const isVoidCallee = returnShape.isVoid;
        if (isVoidCallee && !returnShape.resultIsReceiver
                && destOffset != discardResult)
            assert(0, "a `void` call is only ever evaluated for effect");

        const siteIndex = _callSites.length;
        // The delegate outlives this compiler, so it captures the backend
        // and not `this`.
        auto bytecode = _bytecode;
        _callSites ~= CallSite.guest(
            deferred(() => bytecode.compileFunction(callee)), args,
            returnShape.returnFacts.size,
        );
        emit(&opCall, destOffset, siteIndex, 0);
        emitReceiverResult(returnShape, destOffset, receiverOffset);
    }

    // The value of a constructor call is its receiver, whatever the callee
    // is and wherever it lives; `CallAdapter` decides that, this only copies.
    private void emitReceiverResult(
        in CallAdapter shape,
        in size_t destOffset,
        in size_t receiverOffset,
    ) {
        if (shape.resultIsReceiver && destOffset != discardResult)
            emit(&opCopy, destOffset, receiverOffset, size_t.sizeof);
    }

    // Runs `compute` (always `bytecode.compileFunction(callee)`, the one
    // instantiation this is constrained to) at most once, on the first
    // call of the returned delegate: the site that holds it can execute
    // on any thread's VM. Later calls read the cached result without
    // taking any lock at all. The state lives in a heap struct, not in
    // captured locals, so that `compute` is seen to escape and its
    // closure is not placed on the caller's stack.
    //
    // No lock of its own: two threads racing this same call site's first
    // execution simply both call `compute` - `compileFunction`'s own
    // lock (the frontend/compiler lock, its own doc) is what makes that
    // safe and gives both of them the same finished pointer back, not an
    // extra lock here, so there is nothing left for a second one to
    // protect beyond publishing the result, which the atomic store
    // below already does.
    private static T delegate() deferred(T)(T delegate() compute)
    if (is(T: const(void)*)) {
        return &(new Deferred!T(compute)).get;
    }

    private static struct Deferred(T) {
        private T delegate() _compute;
        private T _cached;

        private T get() {
            import core.atomic: atomicLoad, atomicStore, MemoryOrder;

            if (auto found = atomicLoad!(MemoryOrder.acq)(_cached))
                return found;
            atomicStore!(MemoryOrder.rel)(_cached, _compute());
            return atomicLoad!(MemoryOrder.acq)(_cached);
        }
    }

    private Arg[] compileGuestArguments(
        CallAdapter.Arguments preparation,
        in FrameLayout layout,
    ) {
        Arg[] args;
        preparation.eachDeclared((i, value) {
            const parameter = layout.parameters[i];
            if (value.isReference) {
                const argumentOffset = compileAddress(value.expression);
                args ~= Arg(argumentOffset, parameter.offset, size_t.sizeof);
                return;
            }

            const argumentOffset = reserveTemp(parameter.facts);
            evalInto(value.expression, argumentOffset, parameter.facts.size);
            args ~= Arg(argumentOffset, parameter.offset, parameter.facts.size);
        });
        return args;
    }

    // Prepares a barrier-shaped call's arguments and return place, and
    // emits `opCall` against the `CallSite` `site` builds. A native call
    // and a builtin call are the same shape on the far side of the
    // barrier - arguments bound by `compileBarrierArgument`, a return
    // place decided by `CallAdapter.ofType` - and differ only in what
    // `CallSite` variant the callee resolves to, which `site` supplies.
    // `allowExtraArguments` matches `arityMismatches`' own flag: a native
    // callee can be a C variadic function past its declared parameters; a
    // builtin never is.
    private void compileBarrierCall(
        TypeFunction type,
        Expressions* arguments,
        Loc loc,
        string exprText,
        Arg[] initialArgs,
        in size_t destOffset,
        in bool allowExtraArguments,
        scope CallSite delegate(Arg[] args, size_t returnWidth) site,
        in size_t destinationParameter = size_t.max,
    ) {
        import snakebite.backends.calls: arityMismatches;
        import snakebite.ffi.call: CallAdapter;

        if (arityMismatches(type.parameterList, arguments, allowExtraArguments))
            assert(0, "dmd rejects a call with the wrong number of arguments");

        const returnShape = CallAdapter.ofType(type);
        if (returnShape.isVoid && !returnShape.resultIsReceiver
                && destOffset != discardResult)
            assert(0, "a `void` call is only ever evaluated for effect");

        auto preparation = CallAdapter.Arguments.of(
            type, arguments, destinationParameter);
        Arg[] args = initialArgs;
        preparation.each((value) {
            args ~= compileBarrierArgument(value);
        });

        _callSites ~= site(args, returnShape.resultIsReceiver
            ? 0 : returnShape.returnFacts.size);
        emit(&opCall,
            nativeResultPlace(destOffset, returnShape.isVoid,
                returnShape.returnFacts),
            _callSites.length - 1, 0);
        if (returnShape.resultIsReceiver)
            emitReceiverResult(
                returnShape, destOffset, initialArgs[0].callerOffset);
    }

    // Builds the FFI call plan for a native callee - one druntime already
    // supplies as compiled code, so this compiler calls out to it rather
    // than compiling a guest body - and emits `opCall` against it.
    // `compileResolvedCall`'s own native branch is this helper's one
    // caller, for both an ordinary `CallExp` and a `NewExp`'s constructor
    // call alike; `initialArgs` supplies whatever hidden-`this` argument
    // the callee takes.
    private void compileNativeCall(
        FuncDeclaration callee,
        TypeFunction type,
        Expressions* arguments,
        Loc loc,
        string exprText,
        Arg[] initialArgs,
        in size_t destOffset,
        in bool hasNativeSymbol,
    ) {
        import snakebite.ffi.call: CallAdapter;

        compileBarrierCall(type, arguments, loc, exprText, initialArgs,
            destOffset, /* allowExtraArguments */ true,
            (args, returnWidth) {
                auto preparation = CallAdapter.Arguments.of(type, arguments);
                // `CallSelection` routes every compiler intrinsic to
                // `compileBuiltinCall` instead, before this is ever
                // reached. A declared-but-unlinked `extern(C)` function
                // still reaches here, and an unused branch can refer to
                // one. Resolve it only if execution reaches the call.
                // Known native targets stay prepared for callbacks that
                // first run during GC. A target with no symbol has no
                // plan to prepare early: the lookup misses again, so the
                // call fails whenever it executes.
                if (hasNativeSymbol) {
                    const plan = preparation.prepare(_bytecode._plans, callee);
                    return CallSite.native(
                        cast(const(void)*) plan, args, returnWidth);
                }
                // The returned delegate outlives this compiler, so it
                // captures the backend and not `this`; `PlanCache` is a
                // struct.
                auto bytecode = _bytecode;
                return CallSite.native(
                    deferred(() => cast(const(void)*)
                        preparation.prepare(bytecode._plans, callee)),
                    args, returnWidth);
            });
    }

    // A builtin needs no FFI plan and no symbol lookup, unlike a native
    // call, so `site` here builds a `CallSite` straight from `entry`.
    // Arguments still bind through `compileBarrierArgument`: a builtin's
    // parameters are by-value scalars and vectors, except the one that the
    // wrapper writes through, which `Decision.destinationParameter` makes
    // a reference.
    private void compileBuiltinCall(
        TypeFunction type,
        Expressions* arguments,
        Loc loc,
        string exprText,
        in size_t destOffset,
        BuiltinCall entry,
        in size_t destinationParameter,
    ) {
        compileBarrierCall(type, arguments, loc, exprText, null,
            destOffset, /* allowExtraArguments */ false,
            (args, returnWidth) => CallSite.builtin(entry, args, returnWidth),
            destinationParameter);
    }

    // The cursor is the one input of `va_start` that is not an argument:
    // it is a slot of the frame being compiled, so it joins the arguments
    // here. A function with no cursor slot passes a null cursor.
    private void compileVaStart(
        TypeFunction type,
        Expressions* arguments,
        Loc loc,
        string exprText,
        in size_t destOffset,
        BuiltinCall entry,
    ) {
        size_t cursor = _layout.variadicCursor;
        if (cursor == size_t.max) {
            cursor = reserveTemp(pointerFacts);
            emit(&opZero, cursor, 0, size_t.sizeof);
        }
        compileBarrierCall(type, arguments, loc, exprText,
            null, destOffset, /* allowExtraArguments */ false,
            (args, returnWidth) => CallSite.builtin(
                entry, args ~ Arg(cursor, 0, size_t.sizeof), returnWidth));
    }

    // Where a native callee's result lands. A caller at statement level
    // discards it, but a MEMORY-class result is written through the
    // hidden return pointer whatever the caller does with it, so the
    // call still needs a place: a scratch slot then, never no place. A
    // result with no bytes (`void`, `noreturn`) needs none.
    private size_t nativeResultPlace(
        in size_t destOffset, in bool isVoid, in TypeFacts returnFacts,
    ) {
        return destOffset == discardResult && !isVoid && returnFacts.size != 0
            ? reserveTemp(returnFacts) : destOffset;
    }

    // What a variadic call hands over: `guest` fills the callee's frame
    // slots (the `TypeInfo` tuple of a D variadic, then the cursor), and
    // `values` are the extra arguments in place inside the cursor's
    // storage, as a native C variadic callee takes them.
    private struct VariadicArguments {
        Arg[] guest;
        Arg[] values;
        Shape[] shapes;
    }

    private VariadicArguments compileVariadicArguments(
        Expressions* arguments,
        in FrameLayout layout,
    ) {
        import snakebite.backends.layout: shapeOf;
        import snakebite.backends.variadic: FirstState, VariadicLayout;

        const hasTypes = layout.variadicTypes != size_t.max;
        const firstExtra = hasTypes + layout.parameters.length;
        TypeFacts[] facts;
        foreach (argument; (*arguments)[firstExtra .. $])
            facts ~= TypeFacts.of(argument.type);
        const plan = VariadicLayout.of(facts);
        const storage = reserveTemp(TypeFacts(plan.size, plan.alignment));
        alias Cursor = VariadicLayout.Cursor;
        const initial = Cursor.init;
        emit(&opZero, storage, 0, plan.size);
        emit(&opConstant, storage + Cursor.offset_regs.offsetof,
            addConstant(initial.offset_regs), uint.sizeof);
        emit(&opConstant, storage + Cursor.offset_fpregs.offsetof,
            addConstant(initial.offset_fpregs), uint.sizeof);
        emit(&opFrameAddress, storage + Cursor.stack_args.offsetof,
            storage + plan.argumentsOffset, size_t.sizeof);
        VariadicArguments result;
        foreach (i, offset; plan.offsets) {
            evalInto((*arguments)[firstExtra + i], storage + offset,
                facts[i].size);
            result.values ~= Arg(storage + offset, 0, facts[i].size);
            result.shapes ~=
                shapeOf((*arguments)[firstExtra + i].type, facts[i]);
        }
        emit(&opCopy, storage + FirstState.offset, storage, FirstState.size);
        const cursor = reserveTemp(pointerFacts);
        emit(&opFrameAddress, cursor, storage, size_t.sizeof);
        if (hasTypes) {
            const types = reserveTemp(pointerFacts);
            evalInto((*arguments)[0], types, size_t.sizeof);
            result.guest ~=
                Arg(types, layout.variadicTypes, size_t.sizeof);
        }
        result.guest ~= Arg(cursor, layout.variadicCursor, size_t.sizeof);
        return result;
    }

    private Arg compileBarrierArgument(CallAdapter.Arguments.Value value) {
        if (value.isReference)
            return Arg(compileAddress(value.expression), 0, size_t.sizeof);

        const offset = reserveTemp(value.facts);
        evalInto(value.expression, offset, value.facts.size);
        return compileEvaluatedArgument(offset, value);
    }

    // The argument a native callee takes for `value`, already evaluated
    // into the frame slot at `offset`.
    private Arg compileEvaluatedArgument(
        in size_t offset,
        CallAdapter.Arguments.Value value,
    ) {
        if (!value.readsField)
            return Arg(offset, 0, value.facts.size);

        const addressOffset = reserveTemp(pointerFacts);
        emit(&opConstant, addressOffset,
            addConstant(cast(long) value.fieldOffset), size_t.sizeof);
        emit(&opAdd, addressOffset, offset, size_t.sizeof);
        const fieldOffset = reserveTemp(value.fieldFacts);
        emit(&opLoadIndirect, fieldOffset, addressOffset, value.fieldFacts.size);
        return Arg(fieldOffset, 0, value.fieldFacts.size);
    }

    // `fn(args)` where dmd left `expression.f` unresolved: a call through a
    // function pointer's or a delegate's own value rather than a name.
    // dmd lowers a function-pointer call to `(*fn)(args)` (see the
    // interpreter's own `calleeOf` for the same shape), so `expression.e1`
    // is a `PtrExp` whose pointee type is the `TypeFunction` this call's
    // own signature comes from; a delegate value is already callable
    // without that dereferencing lowering, so `expression.e1` is the
    // delegate-typed expression itself there. Either way there is no
    // `FuncDeclaration` to read a `FrameLayout` from, since more than one
    // could reach this call site at run time. `FrameLayout.ofParameters`
    // packs from the signature alone, the same packing every callee's own
    // `FrameLayout.of` uses, so a callee with the signature of the value
    // reads argument `i` where the site puts it - and, for a delegate call,
    // so does the context word. A callee with another signature reads each
    // parameter from the argument in the same register (`ValueCall`).
    private void compileIndirectCall(CallExp expression, in size_t destOffset) {
        import dmd.astenums: STC, VarArg;
        import snakebite.backends.calls: isIndirectDelegateCall, ValueCall;
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset, delegateValueSize;

        // `super(args)`/`this(args)` constructor delegation is neither
        // shape below: dmd leaves `e1` a bare `SuperExp`/`ThisExp` with no
        // `.type` at all, since dmd's own glue layer picks the constructor
        // to call without reading it. Such a call reaches here only when
        // `compileCall` already found no `FuncDeclaration` to call
        // directly, so it falls through to the `functionType is null`
        // rejection below instead of dereferencing a null `.type`.
        //
        // The callee kind comes from `e1.type`, not from whether `e1` is
        // a `PtrExp` (`isIndirectDelegateCall`'s own doc): a pointer to a
        // delegate (from `key in aa` on a delegate-valued associative
        // array, or `&someDelegateVariable`) dereferences with the same
        // `(*p)(args)` syntax dmd's own function-pointer-call lowering
        // produces, but `e1.type` there is `Tdelegate`, not the
        // `Tfunction` a dereferenced function pointer's type always is.
        auto deref = expression.e1.isPtrExp;
        const isDelegateCall = isIndirectDelegateCall(expression.e1.type);

        TypeFunction functionType;
        size_t calleeOffset;
        size_t contextOffset;
        if (isDelegateCall) {
            functionType = expression.e1.type.nextOf.isTypeFunction;

            const delegateOffset = reserveTemp(TypeFacts.delegateValue);
            evalInto(expression.e1, delegateOffset, delegateValueSize);
            contextOffset = delegateOffset + delegateContextOffset;
            calleeOffset = delegateOffset + delegateFunctionOffset;
            compileNullCheck(calleeOffset, expression.loc);
        } else {
            functionType = deref is null ? null : deref.type.isTypeFunction;
            if (functionType is null)
                assert(0,
                    "dmd wraps a function pointer call's callee in a `PtrExp`");

            calleeOffset = reserveTemp(pointerFacts);
            evalInto(deref.e1, calleeOffset, size_t.sizeof);
            compileNullCheck(calleeOffset, expression.loc);
        }

        auto valueCall = ValueCall.of(functionType, isDelegateCall);
        if (valueCall.mismatches(expression.arguments))
            assert(0, "dmd rejects a call with the wrong number of arguments");

        // A `ref` return hands back its target's address in the return
        // register regardless of the pointee's own width - the same shape
        // `CallAdapter` already decides once for `compileResolvedCall`'s
        // guest branch and for `compileNativeCall`.
        import snakebite.ffi.call: CallAdapter;

        const returnShape = CallAdapter.ofType(functionType);
        const isVoidCallee = returnShape.isVoid;
        if (isVoidCallee && destOffset != discardResult)
            assert(0, "a `void` call is only ever evaluated for effect");

        const calleeLayout = valueCall.layout;

        Arg[] args;
        if (isDelegateCall)
            args ~= Arg(
                contextOffset, calleeLayout.hiddenThis.parameter.offset,
                size_t.sizeof,
            );

        auto site = compileIndirectArguments(
            functionType, expression.arguments, calleeLayout, args,
            calleeOffset, isVoidCallee ? 0 : returnShape.returnFacts.size,
            isDelegateCall);
        site.kind = CallSite.Kind.value;
        site.value.signature = valueCall.signature;
        const siteIndex = _callSites.length;
        _callSites ~= site;
        emit(&opCall,
            nativeResultPlace(destOffset, isVoidCallee, returnShape.returnFacts),
            siteIndex, 0);
    }

    // The arguments and call site of a call whose callee address is read
    // from a frame slot at run time: a function pointer, a delegate, or a
    // class's vtable entry. `args` already holds the context or receiver.
    // Every callee such a site can reach shares `functionType`'s own
    // parameters, so one argument plan covers declared parameters, the
    // `TypeInfo` and cursor of a D variadic, and the extra values of a C
    // variadic.
    private CallSite compileIndirectArguments(
        TypeFunction functionType,
        Expressions* arguments,
        in FrameLayout calleeLayout,
        Arg[] args,
        in size_t calleeOffset,
        in size_t returnWidth,
        in bool hasContext,
    ) {
        import dmd.astenums: VarArg;

        auto preparation = CallAdapter.Arguments.of(functionType, arguments);
        const initialCount = args.length;
        args ~= compileGuestArguments(preparation, calleeLayout);

        auto declared = args[initialCount .. $];
        auto guestArgs = args;
        auto nativeArgs = args;
        VariadicArguments variadic;
        const isVariadic = functionType.parameterList.varargs
            == VarArg.variadic;
        if (isVariadic) {
            variadic = compileVariadicArguments(arguments, calleeLayout);
            guestArgs = args ~ variadic.guest;
            const hidden = functionType.isDstyleVariadic
                ? compileEvaluatedArgument(
                    variadic.guest[0].callerOffset, preparation.hiddenArgument)
                : Arg.init;
            nativeArgs = args[0 .. initialCount] ~ preparation.nativeOrder(
                hidden, declared, variadic.values);
        }

        const nativePlan = isVariadic
            ? cast(const(void)*) preparation.prepareAtAddress(
                _bytecode._plans, null, hasContext)
            : _bytecode._plans.signatureOf(functionType, hasContext);
        auto site = CallSite.indirect(
            calleeOffset, guestArgs, nativeArgs, returnWidth, nativePlan,
            hasContext);
        site.value.surplus = variadic.values;
        site.value.surplusShapes = variadic.shapes;
        return site;
    }

    private TypeFacts pointerFacts() {
        return pointerFactsOf;
    }

    // Emits the conditional call to one of druntime's own bounds-failure
    // hooks (`core/exception.d`'s `_d_arraybounds_indexp`/
    // `_d_arraybounds_slicep`/`_d_arrayboundsp`) that a failed index or
    // slice check must reach. dmd's own glue layer (`e2ir.d`) has no
    // frontend lowering for a bounds check either - it emits exactly this
    // shape at codegen time, a branch around a call, not a distinct
    // "range error" operation, so this compiler does the same instead of
    // keeping one. The hook builds and throws the real
    // `ArrayIndexError`/`ArraySliceError`/`RangeError` itself and never
    // returns, so nothing after the call needs a result slot.
    //
    // `inBoundsOffset` is the frame slot already holding the flag this
    // shares `opBranchTrue`'s own convention with: nonzero means in
    // bounds, and the call is skipped. `extraArgs` are the hook's
    // parameters after `(file, line)`, already evaluated into frame slots
    // by the caller - `index`/`length` for an index check, `lower`/
    // `upper`/`length` for a slice. A function compiled without bounds
    // checks gets nothing.
    private void compileBoundsHook(
        in size_t inBoundsOffset,
        in BoundsCheck check,
        Arg[] extraArgs,
        in Loc loc,
    ) {
        import snakebite.backends.checkplan:
            boundsPlanOf, cMessageOf, FailurePlan;
        import snakebite.backends.exceptions: cAssertCallOf;

        const plan = boundsPlanOf(_bytecode.checks, _function);
        final switch (plan.kind) with (FailurePlan.Kind) {
            case ignore:
                break;
            case halt:
                emit(&opAssert, inBoundsOffset, haltSite, 1);
                break;
            case cAssert: {
                const call = cAssertCallOf(
                    cMessageOf(check).ptr, loc, _function);
                compileUnlessHolds(inBoundsOffset, 1, false, () =>
                    compileCAssertCall(call, constantArgument(
                        cast(size_t) call.assertion, size_t.sizeof)));
                break;
            }
            case raise:
                compileUnlessHolds(inBoundsOffset, 1, false, () =>
                    compileFileLineHookCall(hookOf(check), extraArgs, loc));
                break;
        }
    }

    // `-check=nullderef`: dmd's glue layer branches around druntime's
    // `_d_nullpointerp` the same way, on the pointer itself, which is
    // nonzero when it is not null. Without the flag nothing is emitted.
    private void compileNullCheck(in size_t pointerOffset, in Loc loc) {
        import snakebite.backends.checkplan:
            FailurePlan, nullDerefCMessage, nullDerefPlanOf;
        import snakebite.backends.exceptions: cAssertCallOf;

        final switch (nullDerefPlanOf(_bytecode.checks).kind) with (FailurePlan.Kind) {
            case ignore:
                break;
            case halt:
                emit(&opAssert, pointerOffset, haltSite, size_t.sizeof);
                break;
            case cAssert: {
                const call = cAssertCallOf(
                    nullDerefCMessage.ptr, loc, _function);
                compileUnlessHolds(pointerOffset, size_t.sizeof, false, () =>
                    compileCAssertCall(call, constantArgument(
                        cast(size_t) call.assertion, size_t.sizeof)));
                break;
            }
            case raise:
                compileUnlessHolds(pointerOffset, size_t.sizeof, false, () =>
                    compileFileLineHookCall(DruntimeHook.nullPointer, [], loc));
                break;
        }
    }

    // A druntime hook that takes the file and line of the failed check, then
    // the `extraArgs`.
    private void compileFileLineHookCall(
        in DruntimeHook hook,
        Arg[] extraArgs,
        in Loc loc,
    ) {
        auto plan = planOf(_bytecode._plans, hook);

        const fileOffset = reserveTemp(pointerFacts);
        emit(&opConstant, fileOffset,
            addConstant(cast(long) cast(size_t) loc.filename),
            size_t.sizeof);

        const lineOffset = reserveTemp(pointerFacts);
        emit(&opConstant, lineOffset, addConstant(cast(long) loc.linnum),
            uint.sizeof);

        Arg[] args = [
            Arg(fileOffset, 0, size_t.sizeof),
            Arg(lineOffset, 0, uint.sizeof),
        ] ~ extraArgs;
        _callSites ~= CallSite.native(cast(const(void)*) plan, args, 0);
        emit(&opCall, discardResult, _callSites.length - 1, 0);
    }

    // Fails through the druntime hook unless `smaller <= larger`, unsigned.
    private void compileSliceCheck(
        in size_t smaller, in size_t larger, Arg[] hookArguments,
        in Loc location,
    ) {
        const resultOffset = reserveTemp(pointerFacts);
        emit(&opCopy, resultOffset, smaller, size_t.sizeof);
        emit(&opLessOrEqualUnsigned, resultOffset, larger, size_t.sizeof);
        compileBoundsHook(
            resultOffset, BoundsCheck.slice, hookArguments, location);
    }

    private struct StorageAdapter {
        FunctionCompiler compiler;

        public size_t storageThis(ThisExp expression) {
            return compiler.hiddenThisOffset(expression.var);
        }

        public size_t storageSuper(SuperExp expression) {
            return compiler.hiddenThisOffset(expression.var);
        }

        public size_t storageVariable(VarExp expression) {
            auto variable = expression.var.isVarDeclaration;
            if (variable is null)
                return storageValue(expression);
            if (variable.isDataseg)
                return compiler.compileStaticAddress(variable);
            if (compiler.isThisField(variable))
                return compiler.compileThisFieldAddress(variable);
            return compiler.addressOfVariable(variable);
        }

        public size_t storageReferenceInit(AssignExp expression) {
            auto variable = expression.e1.isVarExp;
            auto declaration = variable is null
                ? null : variable.var.isVarDeclaration;
            assert(declaration !is null,
                "reference construction targets a variable declaration");

            const target = compiler.referenceSlotAddress(
                declaration);
            const source = compiler.compileAddress(expression.e2);
            compiler.emit(&opCopy, target, source, size_t.sizeof);
            return source;
        }

        public size_t storagePointer(PtrExp expression) {
            const result = compiler.reserveTemp(compiler.pointerFacts);
            compiler.evalInto(expression.e1, result, size_t.sizeof);
            compiler.compileNullCheck(result, expression.loc);
            return result;
        }

        public void storageEffect(Expression expression) {
            compiler.compileEffect(expression);
        }

        public extern(D) size_t storageConditional(
            CondExp expression,
            scope size_t delegate(Expression) resolve,
        ) {
            const conditionOffset = compiler.compileCondition(expression.econd);
            const conditionWidth = compiler.conditionWidth(expression.econd);
            const result = compiler.reserveTemp(compiler.pointerFacts);
            const branchIndex = compiler._instructions.length;
            compiler.emit(&opBranchFalse, conditionOffset, 0, conditionWidth);

            const thenOffset = resolve(expression.e1);
            compiler.emit(&opCopy, result, thenOffset, size_t.sizeof);
            const jumpIndex = compiler._instructions.length;
            compiler.emit(&opJump, 0, 0, 0);

            compiler._instructions[branchIndex].source =
                compiler._instructions.length;
            const elseOffset = resolve(expression.e2);
            compiler.emit(&opCopy, result, elseOffset, size_t.sizeof);
            compiler._instructions[jumpIndex].destination =
                compiler._instructions.length;
            return result;
        }

        public size_t storageStructLiteral(StructLiteralExp expression) {
            return storageValue(expression);
        }

        public size_t storageSlice(SliceExp expression) {
            if (planSlice(expression).yieldsStaticArray)
                return compiler.compileSlicePointer(expression);
            return storageValue(expression);
        }

        public size_t storageLowered(Expression expression) {
            return storageValue(expression);
        }

        public void storagePlainAssignment(
            AssignExp expression, size_t target,
        ) {
            compiler.compileAssignmentAt(expression, target);
        }

        public void storageSliceFill(AssignExp expression, size_t target) {
            compiler.compileSliceFill(
                expression, cast() expression.e1.isSliceExp, target);
        }

        public void storageSliceCopy(
            AssignExp expression, size_t target,
        ) {
            compiler.compileSliceAssign(
                expression, cast() expression.e1.isSliceExp,
                discardResult, target,
            );
        }

        public void storageCompoundAssignment(
            BinAssignExp expression, size_t target,
        ) {
            compiler.compileCompoundAssignAt(expression, target);
        }

        public void storageCatAssignment(
            CatAssignExp expression, size_t target,
        ) {
            compiler.compileEffect(expression);
        }

        public size_t storageReferenceCall(CallExp expression) {
            const result = compiler.reserveTemp(compiler.pointerFacts);
            compiler.compileCall(expression, result);
            return result;
        }

        public size_t storageValueCall(CallExp expression) {
            return storageValue(expression);
        }

        public size_t storageDelegateWord(size_t base, in size_t offset) {
            if (offset == 0)
                return base;
            const result = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opConstant, result,
                compiler.addConstant(cast(long) offset), size_t.sizeof);
            compiler.emit(&opAdd, result, base, size_t.sizeof);
            return result;
        }

        public size_t storageArrayLength(
            ArrayLengthExp expression, size_t base,
        ) {
            import snakebite.nativelayout: arrayLengthOffset;
            return base + arrayLengthOffset;
        }

        public size_t storageDynamicIndexLength(
            IndexExp expression, size_t base,
        ) {
            import snakebite.nativelayout: arrayLengthOffset;

            const facts = TypeFacts.of(expression.e1.type);
            const array = compiler.reserveTemp(facts);
            compiler.emit(&opLoadIndirect, array, base, facts.size);
            return array + arrayLengthOffset;
        }

        public size_t storageStaticIndexLength(IndexExp expression) {
            import dmd.typesem: toBasetype;

            const length = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opConstant, length,
                compiler.addConstant(cast(long) expression.e1.type
                    .toBasetype.isTypeSArray.dim.toInteger),
                size_t.sizeof);
            return length;
        }

        public size_t storageIndexValue(
            IndexExp expression, size_t length,
        ) {
            auto savedDollarVariable = compiler._dollarVariable;
            auto savedDollarOffset = compiler._dollarOffset;
            scope (exit) {
                compiler._dollarVariable = savedDollarVariable;
                compiler._dollarOffset = savedDollarOffset;
            }
            if (expression.lengthVar !is null) {
                compiler._dollarVariable = expression.lengthVar;
                compiler._dollarOffset = length;
            }

            const index = compiler.reserveTemp(compiler.pointerFacts);
            compiler.evalOperandInto(expression.e2, index, size_t.sizeof);
            return index;
        }

        public void storageIndexBounds(
            IndexExp expression, size_t index, size_t length,
        ) {
            const inBounds = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opCopy, inBounds, index, size_t.sizeof);
            compiler.emit(&opLessThanUnsigned, inBounds, length,
                size_t.sizeof);
            compiler.compileBoundsHook(
                inBounds,
                BoundsCheck.index,
                [
                    Arg(index, 0, size_t.sizeof),
                    Arg(length, 0, size_t.sizeof),
                ],
                expression.loc,
            );
        }

        public size_t storagePointerIndexBase(
            IndexExp expression, size_t base,
        ) {
            const pointer = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opLoadIndirect, pointer, base, size_t.sizeof);
            return pointer;
        }

        public size_t storagePointerIndexValue(IndexExp expression) {
            return storageIndexValue(expression, 0);
        }

        public size_t storageDynamicIndex(
            IndexExp expression, size_t base, size_t index,
        ) {
            import dmd.typesem: toBasetype;
            import snakebite.nativelayout: arrayPointerOffset;

            const stride =
                TypeFacts.of(expression.e1.type.toBasetype.nextOf).size;
            const strideOffset = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opConstant, strideOffset,
                compiler.addConstant(cast(long) stride), size_t.sizeof);
            compiler.emit(&opMultiply, index, strideOffset, size_t.sizeof);

            const facts = TypeFacts.of(expression.e1.type);
            const array = compiler.reserveTemp(facts);
            compiler.emit(&opLoadIndirect, array, base, facts.size);
            const address = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opCopy, address,
                array + arrayPointerOffset, size_t.sizeof);
            compiler.emit(&opAdd, address, index, size_t.sizeof);
            return address;
        }

        public size_t storageStaticIndex(
            IndexExp expression, size_t base, size_t index,
        ) {
            import dmd.typesem: toBasetype;

            const stride =
                TypeFacts.of(expression.e1.type.toBasetype.nextOf).size;
            const strideOffset = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opConstant, strideOffset,
                compiler.addConstant(cast(long) stride), size_t.sizeof);
            compiler.emit(&opMultiply, index, strideOffset, size_t.sizeof);

            const address = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opCopy, address, base, size_t.sizeof);
            compiler.emit(&opAdd, address, index, size_t.sizeof);
            return address;
        }

        public size_t storagePointerIndex(
            IndexExp expression, size_t pointer, size_t index,
        ) {
            import dmd.typesem: toBasetype;

            const stride =
                TypeFacts.of(expression.e1.type.toBasetype.nextOf).size;
            const strideOffset = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opConstant, strideOffset,
                compiler.addConstant(cast(long) stride), size_t.sizeof);
            compiler.emit(&opMultiply, index, strideOffset, size_t.sizeof);

            const address = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opCopy, address, pointer, size_t.sizeof);
            compiler.emit(&opAdd, address, index, size_t.sizeof);
            return address;
        }

        public size_t storageField(DotVarExp expression) {
            return compiler.compileFieldAddress(expression);
        }

        // The generic fallback for any expression `StorageResolver.resolve`
        // does not otherwise recognise - a struct literal (`storageStructLiteral`),
        // any slice (`storageSlice`), and any rvalue with no storage of its
        // own yet, `ArrayLiteralExp` included: dmd's own typesafe variadic
        // packing (`dmd.expressionsem.functionParameters`, issue #334 step
        // 6) slices a fresh `ArrayLiteralExp` of static-array type directly
        // (`T t...`), with no hidden variable declaration of its own the
        // way a named local would have one, and `visit(SliceExp)`'s own
        // `Tsarray` whole-array-slice case (above) asks `compileAddress`
        // for that literal's own address. Materialising it here, into
        // scratch storage, then reading its address, is what supplies one.
        public size_t storageValue(Expression expression) {
            const facts = TypeFacts.of(expression.type);
            const value = compiler.reserveTemp(facts);
            compiler.evalInto(expression, value, facts.size);
            const result = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opFrameAddress, result, value, size_t.sizeof);
            return result;
        }
    }

    private struct SymbolAddressAdapter {
        FunctionCompiler compiler;

        public size_t symbolAddress(SymOffExp expression) {
            import snakebite.frontend.storage: typeInfoObjectOf;

            if (auto function_ = expression.var.isFuncDeclaration) {
                const result = compiler.reserveTemp(compiler.pointerFacts);
                const address = compiler._bytecode.callableAddress(function_, 0);
                compiler.emit(&opConstant, result,
                    compiler.addConstant(cast(long) cast(size_t) address),
                    size_t.sizeof);
                return result;
            }

            if (auto typeInfo = expression.var.isTypeInfoDeclaration) {
                const result = compiler.reserveTemp(compiler.pointerFacts);
                compiler.emitTypeInfoConstant(
                    typeInfoObjectOf(
                        typeInfo, compiler._bytecode._runtimeTypes),
                    result, size_t.sizeof,
                );
                return result;
            }

            auto variable = expression.var.isVarDeclaration;
            assert(variable !is null,
                "a non-special symbol address names a variable");

            return variable.isDataseg
                ? compiler.compileStaticAddress(variable)
                : compiler.addressOfVariable(variable);
        }

        public size_t addSymbolOffset(
            in size_t address,
            in long offset,
        ) {
            return compiler.addPointerOffset(address, offset);
        }
    }

    private size_t compileAddress(Expression expression) {
        import snakebite.frontend.storage: StorageResolver;

        return StorageResolver!(size_t, StorageAdapter)(StorageAdapter(this))
            .resolve(expression);
    }

    private size_t compileSymbolAddress(SymOffExp expression) {
        import snakebite.frontend.storage: SymbolAddressResolver;

        return SymbolAddressResolver!(size_t, SymbolAddressAdapter)(
            SymbolAddressAdapter(this),
        ).resolve(expression);
    }

    // Calls druntime's allocator for `size` bytes and leaves the resulting
    // pointer at `resultOffset` - `destOffset + arrayPointerOffset`, for
    // every caller here, so the array's own pointer word is filled in
    // directly rather than through an extra copy. Always `GC.BlkAttr.
    // NO_SCAN`: every element type this compiler accepts for a `new T[]`/
    // an array literal is a scalar with no pointers of its own. A class
    // object's own allocation is no longer built here - `compileNew`
    // compiles `_d_newclassT`'s own `GC.malloc` call as part of its
    // lowering instead, which computes its own `GC.BlkAttr` per class
    // (`BlkAttr.FINALIZE` for one with a destructor) the same way real
    // compiled D does.
    private void emitAllocate(in size_t sizeOffset, in size_t resultOffset) {
        import core.memory: GC;

        const bitsOffset = reserveTemp(pointerFacts);
        emit(&opConstant, bitsOffset,
            addConstant(cast(long) GC.BlkAttr.NO_SCAN), uint.sizeof);

        const typeInfoOffset = reserveTemp(pointerFacts);
        emit(&opConstant, typeInfoOffset, addConstant(0), size_t.sizeof);

        const siteIndex = _callSites.length;
        _callSites ~= CallSite.native(
            _bytecode.allocatorPlan,
            [
                Arg(sizeOffset, 0, size_t.sizeof),
                Arg(bitsOffset, 0, uint.sizeof),
                Arg(typeInfoOffset, 0, size_t.sizeof),
            ],
            (void*).sizeof,
        );
        emit(&opCall, resultOffset, siteIndex, 0);
    }

    // `[a, b, c]`: allocates one block through druntime for every element,
    // then evaluates each element expression directly into its own slot in
    // it - never constant-folded bytes copied in bulk, since an element
    // like `x + 1` only evaluating can produce. `[]` needs no allocation at
    // all: a null pointer and a zero length already are an empty dynamic
    // array's own two words.
    //
    // The length and pointer are built up in a temporary, not `destOffset`
    // itself, and copied out to `destOffset` only once every element is
    // done: an element expression can read `destOffset`'s own variable
    // (`a = [a[1], a[0]]`), and until the whole literal is ready that
    // variable's old value is the only correct thing living there.
    private void compileArrayLiteral(
        ArrayLiteralExp expression, in size_t destOffset,
    ) {
        import dmd.astenums: Tsarray;
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        if (expression.type.toBasetype.ty == Tsarray)
            return compileStaticArrayLiteral(expression, destOffset);

        const facts = TypeFacts.of(expression.type);
        assert(facts.isDynamicArray);

        const elementFacts = TypeFacts.of(expression.type.nextOf);

        const count =
            expression.elements is null ? 0 : expression.elements.length;

        if (count == 0) {
            emit(&opConstant, destOffset + arrayLengthOffset,
                addConstant(0), size_t.sizeof);
            emit(&opConstant, destOffset + arrayPointerOffset,
                addConstant(0), size_t.sizeof);
            return;
        }

        const lengthOffset = reserveTemp(pointerFacts);
        emit(&opConstant, lengthOffset,
            addConstant(cast(long) count), size_t.sizeof);

        const pointerOffset = reserveTemp(pointerFacts);
        const sizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, sizeOffset,
            addConstant(cast(long) (count * elementFacts.size)),
            size_t.sizeof);

        emitAllocate(sizeOffset, pointerOffset);

        foreach (i; 0 .. count) {
            auto element = expression[i];
            const elementOffset = reserveTemp(elementFacts);
            evalInto(element, elementOffset, elementFacts.size);

            const addressOffset = reserveTemp(pointerFacts);
            emit(&opCopy, addressOffset, pointerOffset, size_t.sizeof);
            if (i != 0) {
                const byteOffsetOffset = reserveTemp(pointerFacts);
                emit(&opConstant, byteOffsetOffset,
                    addConstant(cast(long) (i * elementFacts.size)),
                    size_t.sizeof);
                emit(&opAdd, addressOffset, byteOffsetOffset, size_t.sizeof);
            }
            emit(&opStoreIndirect, addressOffset, elementOffset,
                elementFacts.size);
        }

        emit(&opCopy, destOffset + arrayLengthOffset, lengthOffset,
            size_t.sizeof);
        emit(&opCopy, destOffset + arrayPointerOffset, pointerOffset,
            size_t.sizeof);
    }

    // Static array literals need no heap allocation lowering. DMD's
    // native code generator builds their elements in stack storage.
    //
    // Every element is evaluated into a temporary first, then the whole
    // temporary copied to `destOffset` in one go - the same reason
    // `compileArrayLiteral` above builds a dynamic array literal's
    // elements in fresh storage rather than `destOffset` itself. An
    // element expression can read `destOffset`'s own variable (`a =
    // [a[1], a[0]]`), and until every element is evaluated, that
    // variable's old contents are the only correct thing for such a read
    // to see.
    private void compileStaticArrayLiteral(
        ArrayLiteralExp expression, in size_t destOffset,
    ) {
        auto sarrayType = expression.type.toBasetype.isTypeSArray;
        const elementFacts = TypeFacts.of(sarrayType.next);

        const count =
            expression.elements is null ? 0 : expression.elements.length;
        if (count == 0)
            return;

        const facts = TypeFacts.of(expression.type);
        const tempOffset = reserveTemp(facts);
        foreach (i; 0 .. count) {
            auto element = expression[i];
            evalInto(
                element, tempOffset + i * elementFacts.size,
                elementFacts.size,
            );
        }
        emit(&opCopy, destOffset, tempOffset, count * elementFacts.size);
    }


}

// Renders `expression` back to source text for a diagnostic message.
private string expressionText(imported!"dmd.expression".Expression expression) {
    import std.conv: text;

    return text("`", expression.toString, "`");
}



// A function body is analysed only in the compile unit that compiles this
// module, whereas a module-scope `static assert` runs again in every unit
// that imports it.
private void assertEveryNodeHandled() {
    static assert(
        imported!"snakebite.backends.nodecoverage".AssertEveryNodeHandled!FunctionCompiler);
}
