module snakebite.backends.bytecode.compiler;


private:

import snakebite.nativelayout: typeFacts, truthFacts;



import snakebite.internalfailure: internalFailure;

import dmd.mtype: Type;
import object: TypeInfo_Class;
import snakebite.backends.argumentflow: Shape;
import snakebite.backends.loweringvisitor: LoweringVisitor;
import snakebite.backends.identity: IdentityPlan, identityPlan;
import snakebite.backends.ifplan: IfPlan;
import snakebite.backends.logical: LogicalPlan;
import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;
import snakebite.backends.switchplan:
    SwitchPlan, switchPlan, gotoCaseTarget, gotoDefaultTarget;
import snakebite.backends.fullexpression:
    FullExpressionScope;
import snakebite.backends.controlflow:
    ScopeFrame, ScopePaths, scopePathsOf;
import snakebite.backends.exceptionplan:
    UnwindPlan, catchPlanOf, unwindPlanOf;
import snakebite.backends.checkplan: BoundsCheck, hookOf;
import snakebite.backends.druntimehooks: DruntimeHook, planOf;
import snakebite.backends.sliceplan: planSlice;
import snakebite.backends.exceptions: AssertFailure, CAssertCall;
import snakebite.ffi: CallbackBridge, CallbackCall, PlanCache;
import std.typecons: Flag, No, Yes;


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
    import snakebite.backends.bytecode.vm: Function, InlineBody, Vm;
    import snakebite.backends.layout: FrameLayout;
    import snakebite.frontend.checks: Checks;
    import snakebite.sharedtable: SharedTable;
    import snakebite.exception: SnakebiteException;
    import snakebite.framestack: defaultFrameCapacity;
    import snakebite.hostthreads: heapNew;
    import snakebite.executionstates: ExecutionStates;
    import snakebite.nativelayout: NativeData, nativeSymbolName;
    import snakebite.backends.runtimetypes: RuntimeTypes;

    // Each native stack needs its own guest frame stack. Fibers can resume
    // out of nesting order, so they cannot share one LIFO stack.
    // Entries are owned and released by their host thread (ADR-0006).
    private ExecutionStates!(Vm*) _vms;
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
    // Greater than zero while a callee compiles only so that its caller
    // can copy it: that compile may copy callees that are already complete
    // but compiles no further function.
    private size_t _speculating;
    private bool[FuncDeclaration] _rejectedForInlining;
    private size_t _cacheMisses;
    private Duration _compilationTime;
    // Complete declared-storage layouts, shared by compilation, context
    // paths and host entry. Publication permits lock-free callback reads
    // after preparation, including during GC finalization (ADR-0006).
    private SharedTable!(FuncDeclaration, FrameLayout) _layouts;

    public this(const Program program) {
        super(program);
        _plans = PlanCache(program.dependencyImage,
            &_program.isRootOwned);
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
        _vms = ExecutionStates!(Vm*)(() {
            return heapNew!Vm(defaultFrameCapacity, _nativeData.tlsSlots);
        }, () => _nativeData.release);
        _plans.useCallbacks(
            new CallbackBridge(&invokeCallback, cast(void*) this));
    }

    protected override void release() {
        _vms.end;
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

    version(unittest)
    public size_t executionStatesOfThisThread() {
        return _vms.count;
    }

    // Every function this backend compiled, for tests that inspect the
    // compiled form. The order is unspecified.
    version(unittest)
    public void eachCompiled(
        scope void delegate(FuncDeclaration, const(Function)*) visit,
    ) {
        foreach (declaration, compiled; _compiled)
            visit(declaration, compiled);
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
        const compiled = compileFunction(function_);
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
    // any thread needs it (`layoutOf`): binding `args` into
    // `Vm.HostArgument`s and running the compiled body touch no dmd
    // state, so this takes no lock of its own. A thread that held the
    // compiler lock here while it waited for another thread's callback -
    // the way `Thread.join` waits in `otherThread`/`concurrentThreads`
    // guest code - would never see that callback return, since the
    // callback's own slow path (`layoutOf`'s miss branch) needs that
    // same, recursive lock to build a layout the first time (ADR-0006).
    private void runHostToGuest(
        const(Function)* compiled,
        FuncDeclaration function_,
        void* returnPlace,
        scope const(void*)[] args,
        void* variadicCursor = null,
        const(void)* variadicTypes = null,
    ) {
        const layout = layoutOf(function_);
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

        auto active = _vms.enter;
        active.state.call(*compiled, returnPlace, arguments[0 .. filled]);
    }

    private const(FrameLayout)* layoutOf(FuncDeclaration function_) {
        import snakebite.frontend.compiler: withCompilerLock;

        if (auto found = function_ in _layouts)
            return found;

        const(FrameLayout)* result;
        withCompilerLock({
            if (auto found = function_ in _layouts) {
                result = found;
                return;
            }

            // FrameLayout.of completes body semantics before collecting
            // locals, including lowering temporaries. Publish only that
            // complete layout, owned by this backend rather than the AST.
            result = _layouts.insert(function_, FrameLayout.of(function_));
        });
        return result;
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
        layoutOf(function_);
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
        if (_callSelection.usesNativeVariadicAddress(
                method, hasNativeSymbol))
            return _plans.addressOf(method);
        if (_callSelection.usesGuestBody(method, &isGuestFunction,
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

    // The address that a function body names with `&f`, a function literal
    // or a delegate. A function whose address a callee takes may never run,
    // so a speculative compile must not compile it. The rejection leaves
    // only the callee's own compile to unwind: class runtime info, built
    // through `callableAddress` itself, never sees it.
    private imported!"snakebite.backends.bytecode.relocation".Address
    operandAddress(FuncDeclaration method, ptrdiff_t adjustment) {
        import snakebite.backends.bytecode.relocation: Address;

        if (_speculating != 0)
            throw new SpeculationRejected;
        const address = callableAddress(method, adjustment);
        return Address(callableKind(address), address);
    }

    // What `callableAddress` returned: a guest function, the callback entry
    // that host code calls for one, or code of the host.
    private imported!"snakebite.backends.bytecode.relocation".Target.Kind
    callableKind(in void* address) {
        import snakebite.backends.bytecode.relocation: Target;

        if (address is null || _plans.isGuestWord(address))
            return Target.Kind.functionWord;
        if (_plans.guestTarget(address).word !is null)
            return Target.Kind.callbackEntry;
        return Target.Kind.hostSymbol;
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

    // The body of `function_` for a caller to copy in place of a call, or
    // null. It compiles a tiny `function_` unless a function is already
    // compiling only for a caller. A callee that this compiler rejects, or
    // whose compile would reach another function's address, is recorded
    // once and stays a normal call.
    package const(InlineBody)* inlineBodyOf(FuncDeclaration function_) {
        import snakebite.frontend.compiler: withCompilerLock;

        const(Function)* found;
        withCompilerLock({
            if (auto complete = function_ in _complete)
                found = *complete;
            else if (_speculating == 0 && function_ !in _compiled
                    && function_ !in _rejectedForInlining
                    && hasTinyBody(function_)) {
                ++_speculating;
                scope(exit) --_speculating;
                try
                    found = compileFunction(function_);
                catch (Exception) {
                    found = null;
                    _rejectedForInlining[function_] = true;
                }
            }
        });
        return found is null ? null : found.inlineBody;
    }

    // Compiling a callee only so that a caller can copy it must not reach
    // code that a plain call would never reach: `internalFailure` ends the
    // process and cannot be recovered. A callee of at most this many
    // statements, all of them `return` or expression statements, is the
    // only one compiled that way.
    private enum maxSpeculativeStatements = 3;

    private static class SpeculationRejected: Exception {
        this() @safe pure nothrow {
            super("a speculative compile must not compile another function");
        }
    }

    private static bool hasTinyBody(FuncDeclaration function_) {
        import dmd.statement: Statement;

        int budget = maxSpeculativeStatements;
        bool tiny(Statement statement) {
            if (statement is null)
                return true;
            if (--budget < 0)
                return false;
            if (auto compound = statement.isCompoundStatement) {
                foreach (child; *compound.statements)
                    if (!tiny(child))
                        return false;
                return true;
            }
            if (auto scoped = statement.isScopeStatement)
                return tiny(scoped.statement);
            return statement.isReturnStatement !is null
                || statement.isExpStatement !is null;
        }
        return function_.fbody !is null && tiny(function_.fbody);
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
    // forced dmd forward reference (`typeFacts`, `FrameLayout.of`,
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
    // might already be holding a `CallSite` that points at it (the
    // stable pointer that the first paragraph above describes), which a `SharedTable`'s
    // "first write wins, never overwritten" insert does not provide -
    // so an unfinished body and its whole compile stay under the one
    // lock. Completed bodies are published in `_complete`; every caller
    // can reuse them without waiting for unrelated frontend work.
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
            internalFailure("callers pass a resolved function");

        if (auto complete = function_ in _complete)
            return *complete;

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
                isVoidReturn ? TypeFacts.init : typeFacts(returnType);
            const returnFacts = isRefReturn ? pointerFactsOf : pointeeFacts;

            const layout = *layoutOf(function_);
            auto body_ = function_.fbody;
            if (body_ is null)
                internalFailure("`CallSelection` routes a bodyless function to "
                    ~ "FFI or a builtin, never to the compiler");

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
        ExceptionHandler, Function, InlineBody,
        Instruction, Role, Roles, branchTargetField, recordAssertSiteRelocs,
        recordCallSiteRelocs, recordExceptionHandlerRelocs, rolesOf,
        opAdd3, opSubtract3, opMultiply3, opFloatAdd3, opFloatSubtract3,
        opFloatMultiply3, opFloatDivide3, opLessThanSigned3,
        opLessThanUnsigned3, opLessOrEqualSigned3, opLessOrEqualUnsigned3,
        opGreaterThanSigned3, opGreaterThanUnsigned3, opGreaterOrEqualSigned3,
        opGreaterOrEqualUnsigned3, opEqual3, opNotEqual3, opFloatEqual3,
        opFloatNotEqual3, opFloatLessThan3, opFloatLessOrEqual3,
        opFloatGreaterThan3, opFloatGreaterOrEqual3,
        CheckedAccess, opIndexPointer, opIndexSlice, opIndexStatic,
        checkedIndexHandler,
        opBitAnd3, opBitOr3, opBitXor3, opShiftLeft3, opShiftRightLogical3,
        opShiftRightArithmetic3, opDivideSigned3, opDivideUnsigned3,
        opModuloSigned3, opModuloUnsigned3,
        CompareKind, Comparison, constantForm, fusedBranchHandler, fusesConstant,
        firstComparisonHandler, threeAddressConstantHandlers,
        threeAddressHandlers,
        isFusedBranch, specialiseHandlers, RegisterFamily, registerFamily,
        fusedRegisterFamily, registerForm, fusedRegisterForm,
        opAdd, opAssert, opBitAnd, opBitOr, opBitXor, opBranchFalse,
        opBranchTrue, opCall,
        opCastAs, opCastFixedAs,
        opCastToBool, opCastWidenSigned, opCastWidenUnsigned, opComplement,
        opAlloca, opArrayEqual, opComplex, opComplexNegate, opConstant, opCopy,
        opCopyFixed, opLoadThenCopy, opThenReturn, opLoadIndirectFixed, opStoreIndirectFixed,
        opDivideSigned, opDivideSigned32, opDivideUnsigned,
        opEqual,
        opFloatAbs, opFloatAdd, opFloatDivide, opFloatEqual, opFloatGreaterOrEqual,
        opFloatGreaterThan, opFloatLessOrEqual, opFloatLessThan,
        opFloatModulo, opFloatMultiply, opFloatNegate, opFloatNotEqual,
        opFloatSqrt, opFloatSubtract, opFloatToBool,
        opFloatWidthCast, opFrameAddress, opGreaterOrEqualSigned,
        opGreaterOrEqualUnsigned, opGreaterThanSigned, opGreaterThanUnsigned,
        opJump, opLessOrEqualSigned, opLessOrEqualUnsigned, opLessThanSigned,
        opLessThanUnsigned, opLoadBitfield, opLoadIndirect, opLogicalNot,
        opModuloSigned, opModuloSigned32,
        opModuloUnsigned, opMultiply, opNegate, opNotEqual,
        opRangeEnd, opReturn,
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
    import snakebite.backends.bytecode.relocation:
        Address, Place, Reloc, Target, recordRelocs;
    import snakebite.backends.layout: ClosureLayout, FrameLayout;
    import snakebite.backends.temporary: TemporaryPlan, constructTemporary;
    import snakebite.exception: SnakebiteException;
    import snakebite.nativelayout:
        alignUp, initializerRunsForEffect, initializerValueOf,
        isIntegralSize, isThreadLocalStorage, TypeFacts;
    import snakebite.nativevalue: CastKind;

    alias visit = LoweringVisitor.visit;

    extern(D) protected override CallSelection* callSelection() {
        return &_bytecode._callSelection;
    }

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

    // Where the address of a returned lvalue is, until the transfer reads
    // the value after the destructors of the operand ran.
    private enum noReturnAddress = size_t.max;
    private size_t _returnAddress = noReturnAddress;

    private Instruction[] _instructions;
    private long[] _constants;
    // Every word of the instructions and constants that holds an address.
    private Reloc[] _relocs;
    private CallSite[] _callSites;
    private AssertSite[] _assertSites;
    private size_t _haltSite = size_t.max;
    private PendingExceptionHandler[] _exceptionHandlers;
    private size_t _tempSize;
    private uint _tempAlignment;
    // Temporaries made for an operand and read by its one parent.
    private bool[size_t] _operandTemps;
    private struct Temporary {
        size_t base;
        size_t site;
        Expression destructor;
    }
    private Temporary[] _temporaries;
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
            internalFailure("every `case` a jump targets was compiled");
        if (_pendingDefaultJumps.length != 0)
            internalFailure("every `default` a jump targets was compiled");

        removeEmptyLifetimes;
        // Dispatch tests no end of stream: the last instruction ends the
        // activation.
        if (_instructions.length == 0
                || (_instructions[$ - 1].handler !is &opReturn
                    && _instructions[$ - 1].handler !is &opReturnVoid
                    && _instructions[$ - 1].handler !is &opJump))
            emit(&opReturnVoid, 0, 0, 0);
        auto inlineBody = inlineBodyOfBuilt;
        resolveBranches();

        ExceptionHandler[] exceptionHandlers;
        foreach (pending; _exceptionHandlers) {
            if (!(pending._handler < _instructions.length
                    || pending._cleanupEnd != size_t.max))
                internalFailure("a catch handler is followed by the code after "
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
        fuseLoadCopies;
        assignRegisters;
        specialiseHandlers(_instructions);

        foreach (ref site; _callSites)
            if (site.cleanupStartIndex != size_t.max) {
                site.cleanupStart = cast(void*) instructionAt(
                    site.cleanupStartIndex);
                site.cleanupEnd = cast(void*) instructionAt(
                    site.cleanupEndIndex);
            }

        if (recordRelocs) {
            foreach (index, ref site; _callSites)
                recordCallSiteRelocs(_relocs, index, site);
            foreach (index, ref site; _assertSites)
                recordAssertSiteRelocs(_relocs, index, site);
            foreach (index, ref handler; exceptionHandlers)
                recordExceptionHandlerRelocs(_relocs, index, handler);
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
            _layout.returnPlace,
        );
        result.inlineBody = inlineBody;
        result.relocs = _relocs;
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


    // A caller copies a function in place of a call only when it is a
    // leaf of at most this many instructions.
    private enum maxInlineInstructions = 8;

    // How a copied instruction names frame storage. `ignored` marks a field
    // that holds no storage operand.
    private enum Operand { ignored, storage, constant }

    private static struct Operands {
        Operand destination;
        Operand source;
        // The right operand of a three-address instruction, held in
        // `sourceWidth`.
        Operand right;
    }

    // The operand roles of every handler a copied function may use, and
    // `false` for any other. A handler outside this list never gets copied,
    // so a new opcode starts as not copyable.
    private bool inlineOperandsOf(
        Instruction.Handler handler, out Operands roles,
    ) {
        import std.meta: AliasSeq;

        enum S = Operand.storage;
        enum N = Operand.ignored;
        static foreach (operation; AliasSeq!(
            opCopy, opLoadIndirect, opStoreIndirect, opAdd, opSubtract,
            opMultiply, opBitAnd, opBitOr, opBitXor, opShiftLeft,
            opShiftRightLogical, opShiftRightArithmetic, opLessThanSigned,
            opLessThanUnsigned, opLessOrEqualSigned, opLessOrEqualUnsigned,
            opGreaterThanSigned, opGreaterThanUnsigned,
            opGreaterOrEqualSigned, opGreaterOrEqualUnsigned, opEqual,
            opNotEqual, opFrameAddress,
            opCopyFixed!1, opCopyFixed!2, opCopyFixed!4, opCopyFixed!8,
            opCopyFixed!16,
        )) {
            if (handler is &operation) {
                roles = Operands(S, S);
                return true;
            }
        }
        static foreach (index, operation; threeAddressHandlers) {
            if (handler is &operation) {
                roles = Operands(S, S, S);
                return true;
            }
            // The constant form holds the address of a native constant in
            // `sourceWidth`; it does not move.
            if (handler is &threeAddressConstantHandlers[index]) {
                roles = Operands(S, S, N);
                return true;
            }
        }
        static foreach (operation; AliasSeq!(
            opIndexSlice, opIndexStatic, opIndexPointer,
        )) {
            if (handler is &operation) {
                roles = Operands(S, S, S);
                return true;
            }
        }
        // A fused compare-and-branch: the left operand is in `destination`
        // and the branch target in `sourceWidth`, which the caller of this
        // method moves as it moves every branch target.
        if (isFusedBranch(handler)) {
            roles = Operands(S, fusesConstant(handler) ? N : S);
            return true;
        }
        static foreach (width; indirectCopyWidths) {
            if (handler is &opLoadIndirectFixed!width
                    || handler is &opStoreIndirectFixed!width) {
                roles = Operands(S, S);
                return true;
            }
        }
        static foreach (kind; [
            CastKind.narrow, CastKind.widenSigned, CastKind.widenUnsigned,
        ])
            static foreach (destSize; [1UL, 2, 4, 8])
                static foreach (sourceSize; [1UL, 2, 4, 8])
                    if (handler is &opCastFixedAs!(kind, destSize, sourceSize)) {
                        roles = Operands(S, S);
                        return true;
                    }
        static foreach (operation; AliasSeq!(
            opNegate, opComplement, opLogicalNot, opCastToBool,
            opCastWidenSigned, opCastWidenUnsigned, opStaticLoad, opZero,
            opThrow, opBranchTrue, opBranchFalse,
        )) {
            if (handler is &operation) {
                roles = Operands(S, N);
                return true;
            }
        }
        if (handler is &opConstant) {
            roles = Operands(S, Operand.constant);
            return true;
        }
        if (handler is &opReturn) {
            roles = Operands(N, S);
            return true;
        }
        if (handler is &opJump || handler is &opReturnVoid) {
            roles = Operands(N, N);
            return true;
        }
        return false;
    }

    // The copyable form of the function this compiler just finished, or
    // null. Called once the instructions are final except for fusing and
    // the resolution of branch targets to addresses.
    private InlineBody* inlineBodyOfBuilt() {
        if (_callSites.length != 0 || _assertSites.length != 0
                || _exceptionHandlers.length != 0
                || _closureOffset != size_t.max
                || _layout.returnPlace.offset != size_t.max
                || _layout.variadicTypes != size_t.max
                || _layout.variadicCursor != size_t.max
                || _instructions.length > maxInlineInstructions)
            return null;
        foreach (instruction; _instructions) {
            Operands roles;
            if (!inlineOperandsOf(instruction.handler, roles))
                return null;
        }
        return new InlineBody(
            _instructions.dup, _constants.dup, _tempSize, _tempAlignment,
            _relocs.dup);
    }

    // Whether an instruction of a copied body leaves its `destination`
    // field unwritten: it only reads it, or it is a store through it.
    private bool leavesDestination(Instruction.Handler handler) {
        import std.meta: AliasSeq;

        static foreach (operation; AliasSeq!(
            opThrow, opBranchTrue, opBranchFalse, opReturn, opJump,
            opReturnVoid, opStoreIndirect,
        ))
            if (handler is &operation)
                return true;
        static foreach (width; indirectCopyWidths)
            if (handler is &opStoreIndirectFixed!width)
                return true;
        return isFusedBranch(handler);
    }

    // Whether the caller's operands can stand for the callee's parameters
    // of `body_`: nothing in it writes through a pointer, and nothing in it
    // takes the address of a frame slot. Then only its direct writes can
    // change a parameter or a caller operand.
    private bool bodyWritesOnlyItsFrame(in InlineBody body_) {
        import std.meta: AliasSeq;

        foreach (instruction; body_.instructions) {
            static foreach (operation; AliasSeq!(
                opStoreIndirect, opFrameAddress,
            ))
                if (instruction.handler is &operation)
                    return false;
            static foreach (width; indirectCopyWidths)
                if (instruction.handler is &opStoreIndirectFixed!width)
                    return false;
            if (!leavesDestination(instruction.handler)
                    && (instruction.destination & (1UL << 63)) != 0)
                return false;
        }
        return true;
    }

    // Whether any instruction of `body_` writes the bytes
    // `[offset, offset + width)` of its frame.
    private bool bodyWrites(
        in InlineBody body_, in size_t offset, in size_t width,
    ) {
        import std.meta: AliasSeq;

        // An indexing instruction's width field is the element size; it
        // writes one pointer.
        enum indexWidth = size_t.sizeof;
        foreach (instruction; body_.instructions) {
            if (leavesDestination(instruction.handler))
                continue;
            size_t written = instruction.width == 0 ? 1 : instruction.width;
            static foreach (operation; AliasSeq!(
                opIndexSlice, opIndexStatic, opIndexPointer,
            ))
                if (instruction.handler is &operation)
                    written = indexWidth;
            if (instruction.destination < offset + width
                    && instruction.destination + written > offset)
                return true;
        }
        return false;
    }

    // Whether `instruction` writes the whole of `destination` with a result
    // of `width` bytes in one machine word or less, from operands that do
    // not include `destination` itself (a two-address instruction reads it).
    // A comparison writes one byte whatever its operand width, so it is not
    // one of them.
    private bool writesWholeWord(in Instruction instruction, in size_t width) {
        import std.meta: AliasSeq;

        if (width > size_t.sizeof || instruction.width != width)
            return false;
        static foreach (operation; AliasSeq!(
            opCopy, opLoadIndirect,
            opCopyFixed!1, opCopyFixed!2, opCopyFixed!4, opCopyFixed!8,
        ))
            if (instruction.handler is &operation)
                return true;
        static foreach (copyWidth; indirectCopyWidths)
            static if (copyWidth <= size_t.sizeof)
                if (instruction.handler is &opLoadIndirectFixed!copyWidth)
                    return true;
        static foreach (index, operation; threeAddressHandlers)
            static if (index < firstComparisonHandler) {
                if (instruction.handler is &operation)
                    return true;
                if (instruction.handler
                        is &threeAddressConstantHandlers[index])
                    return true;
            }
        return false;
    }

    // Copies `body` into this function in place of a call whose arguments
    // are already in `args`. Its frame becomes a region of this frame, and
    // each return copies the result to `destOffset` and jumps past the copy.
    //
    // A parameter that nothing in the body writes shares the storage of
    // the caller's operand instead of a copy of it. `args` is reordered:
    // the shared arguments move to its front. A value that the last
    // instruction before a return computes goes straight to `destOffset`.
    private void emitInlined(
        in InlineBody body_, Arg[] args, in size_t destOffset,
    ) {
        const base = alignUp(_tempSize, body_.frameAlignment);
        _tempSize = base + body_.frameSize;
        if (body_.frameAlignment > _tempAlignment)
            _tempAlignment = body_.frameAlignment;

        size_t boundCount;
        const mayBind = bodyWritesOnlyItsFrame(body_);
        foreach (arg; args) {
            if (mayBind && arg.width != 0
                    && (arg.callerOffset & (1UL << 63)) == 0
                    && !bodyWrites(body_, arg.calleeOffset, arg.width))
                args[boundCount++] = arg;
            else
                emit(&opCopy, base + arg.calleeOffset, arg.callerOffset,
                    arg.width);
        }
        const bound = args[0 .. boundCount];
        size_t rebase(in size_t offset) {
            foreach (arg; bound)
                if (offset >= arg.calleeOffset
                        && offset < arg.calleeOffset + arg.width)
                    return arg.callerOffset + (offset - arg.calleeOffset);
            return offset + base;
        }
        size_t place(in size_t operand) {
            if ((operand & (1UL << 63)) == 0)
                return rebase(operand);
            const slot = (operand >> 32) & 0x7fff_ffffUL;
            return indirectStorage(rebase(slot)) | (operand & 0xffff_ffffUL);
        }

        const instructions = body_.instructions;
        // `positions` first marks the branch targets, then holds the new
        // index of each instruction.
        auto positions = new size_t[instructions.length + 1];
        enum targetMark = 1;
        foreach (instruction; instructions) {
            Instruction probe = instruction;
            if (auto target = branchTargetField(probe))
                positions[*target] = targetMark;
        }
        // A return whose copy to `destOffset` the instruction before it
        // does instead.
        auto direct = new bool[instructions.length];
        foreach (i, instruction; instructions) {
            if (instruction.handler !is &opReturn || destOffset == discardResult
                    || i == 0 || positions[i] == targetMark
                    || (instruction.source & (1UL << 63)) != 0)
                continue;
            const previous = instructions[i - 1];
            direct[i] = previous.destination == instruction.source
                && writesWholeWord(previous, instruction.width);
        }

        const constantBase = _constants.length;
        _constants ~= body_.constants;
        const start = _instructions.length;
        size_t next = start;
        foreach (i, instruction; instructions) {
            positions[i] = next;
            if (instruction.handler is &opReturn)
                next += (destOffset != discardResult && !direct[i] ? 1 : 0)
                    + (i + 1 == instructions.length ? 0 : 1);
            else if (instruction.handler is &opReturnVoid)
                next += i + 1 == instructions.length ? 0 : 1;
            else
                ++next;
        }
        positions[$ - 1] = next;
        const end = next;

        foreach (i, instruction; instructions) {
            Operands roles;
            inlineOperandsOf(instruction.handler, roles);
            const isReturn = instruction.handler is &opReturn;
            if (isReturn || instruction.handler is &opReturnVoid) {
                if (isReturn && destOffset != discardResult && !direct[i])
                    emit(&opCopy, destOffset, place(instruction.source),
                        instruction.width);
                if (i + 1 != instructions.length)
                    emit(&opJump, end, 0, 0);
                continue;
            }
            Instruction copied = instruction;
            if (roles.destination == Operand.storage)
                copied.destination = i + 1 < instructions.length
                        && direct[i + 1]
                    ? destOffset : place(copied.destination);
            if (roles.source == Operand.storage)
                copied.source = place(copied.source);
            else if (roles.source == Operand.constant)
                copied.source += constantBase;
            if (roles.right == Operand.storage)
                copied.sourceWidth = place(copied.sourceWidth);
            if (auto target = branchTargetField(copied))
                *target = positions[*target];
            _instructions ~= copied;
        }

        foreach (original; body_.relocs) {
            Reloc reloc = original;
            final switch (reloc.place.section) with (Place.Section) {
                case instruction:
                    reloc.place.index = positions[reloc.place.index];
                    break;
                case constant:
                    reloc.place.index += constantBase;
                    break;
                case callSite, assertSite, exceptionHandler:
                    internalFailure("a copied body has no call, assertion or "
                        ~ "catch site");
            }
            _relocs ~= reloc;
        }
    }

    // Bound handler growth while letting LDC inline small unaligned copies.
    private enum indirectCopyWidths = [1, 2, 4, 8, 16, 32];

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
        static foreach (size; indirectCopyWidths) {
            if (width == size) {
                if (handler is &opLoadIndirect)
                    handler = &opLoadIndirectFixed!size;
                else if (handler is &opStoreIndirect)
                    handler = &opStoreIndirectFixed!size;
            }
        }
        // `narrow`/`widenSigned`/`widenUnsigned` only ever see
        // `width`/`sourceWidth` in `1`/`2`/`4`/`8` - every D integral's
        // own byte count - so this is the same peephole as `opCopy`'s
        // own above, just over both sizes `opCastFixedAs` takes as
        // template parameters instead of reading off the instruction.
        static foreach (kind; [
            CastKind.narrow, CastKind.widenSigned, CastKind.widenUnsigned,
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

    // An instruction whose `destination` is an address.
    private void emit(
        Instruction.Handler handler,
        in Address destination,
        in size_t source,
        in size_t width,
    ) {
        recordOperand(handler, Place.Field.destination, destination);
        emit(handler, destination.word, source, width);
    }

    // An instruction whose `source` is an address.
    private void emit(
        Instruction.Handler handler,
        in size_t destination,
        in Address source,
        in size_t width,
        in size_t sourceWidth = 0,
    ) {
        recordOperand(handler, Place.Field.source, source);
        emit(handler, destination, source.word, width, sourceWidth);
    }

    // An instruction whose `sourceWidth` is an address.
    private void emit(
        Instruction.Handler handler,
        in size_t destination,
        in size_t source,
        in size_t width,
        in Address sourceWidth,
    ) {
        recordOperand(handler, Place.Field.sourceWidth, sourceWidth);
        emit(handler, destination, source, width, sourceWidth.word);
    }

    // The address goes into the instruction that `emit` appends next. The
    // handler says which fields may hold one.
    private void recordOperand(
        in Instruction.Handler handler, in Place.Field field,
        in Address address,
    ) {
        import std.conv: text;

        if (!recordRelocs)
            return;
        Roles roles;
        const known = rolesOf(handler, roles);
        const role = field == Place.Field.destination ? roles.destination
            : field == Place.Field.source ? roles.source
            : roles.sourceWidth;
        if (!known || role != Role.address)
            internalFailure(text("this handler holds no address in `", field,
                "`"));
        if (!address.isNull)
            _relocs ~= Reloc(
                Place(Place.Section.instruction, field, _instructions.length),
                address.target);
    }

    private size_t addConstant(in long value) {
        _constants ~= value;
        return _constants.length - 1;
    }

    private size_t addConstant(in Address address) {
        if (recordRelocs && !address.isNull)
            _relocs ~= Reloc(
            Place(Place.Section.constant, Place.Field.word,
                _constants.length),
            address.target);
        return addConstant(cast(long) address.word);
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

    // Keeps the result of an arithmetic instruction in a register when the
    // next instruction is its only reader: the operand temporary is read by
    // that instruction alone, and the next instruction is not a branch
    // target, an exception handler entry or a cleanup bound.
    private void assignRegisters() {
        const count = _instructions.length;
        if (count < 2)
            return;
        size_t[size_t] mentions;
        auto isTarget = new bool[count + 1];
        foreach (ref instruction; _instructions) {
            mentions[instruction.destination]++;
            if (instruction.source != instruction.destination)
                mentions[instruction.source]++;
            if (instruction.sourceWidth != instruction.source
                    && instruction.sourceWidth != instruction.destination)
                mentions[instruction.sourceWidth]++;
            // A temp that holds an address is mentioned by every indirect
            // operand that reads through it. A field that is not an operand
            // can only add mentions, which only stops a pairing.
            static foreach (field; ["destination", "source", "sourceWidth"])
                if (mixin("instruction." ~ field) & (1UL << 63))
                    mentions[(mixin("instruction." ~ field) >> 32)
                        & 0x7fff_ffffUL]++;
            if (auto field = branchTargetField(instruction)) {
                const target = cast(const(Instruction)*) *field;
                isTarget[target - _instructions.ptr] = true;
            }
        }
        void markTarget(in size_t index) {
            if (index <= count)
                isTarget[index] = true;
        }
        foreach (handler; _exceptionHandlers) {
            markTarget(handler._bodyStart);
            markTarget(handler._bodyEnd);
            markTarget(handler._handler);
            markTarget(handler._cleanupEnd);
        }
        foreach (ref site; _callSites)
            if (site.cleanupStartIndex != size_t.max) {
                isTarget[site.cleanupStartIndex] = true;
                isTarget[site.cleanupEndIndex] = true;
            }

        auto readsRegister = new bool[count];
        auto writesRegister = new bool[count];
        auto fused = new bool[count];
        foreach (index; 0 .. count - 1) {
            auto producer = &_instructions[index];
            auto consumer = &_instructions[index + 1];
            if (isTarget[index + 1])
                continue;
            const family = registerFamily(producer.handler, producer.width);
            if (family == RegisterFamily.none)
                continue;
            const temp = producer.destination;
            if (temp !in _operandTemps || mentions[temp] != 2)
                continue;
            if (consumer.width != producer.width)
                continue;
            if (registerFamily(consumer.handler, consumer.width) == family) {
                if (consumer.source != temp || consumer.sourceWidth == temp
                        || consumer.destination == temp)
                    continue;
            } else if (fusedRegisterFamily(consumer.handler, consumer.width)
                    == family) {
                if (consumer.destination != temp || consumer.source == temp)
                    continue;
                fused[index + 1] = true;
            } else
                continue;
            writesRegister[index] = true;
            readsRegister[index + 1] = true;
        }
        foreach (index, ref instruction; _instructions) {
            if (fused[index]) {
                instruction.handler = fusedRegisterForm(instruction.handler);
            } else if (readsRegister[index] || writesRegister[index]) {
                instruction.handler = registerForm(instruction.handler,
                    readsRegister[index], writesRegister[index]);
            }
        }
    }

    private void fuseLoadCopies() {
        foreach (index, ref instruction; _instructions) {
            if (index + 1 == _instructions.length)
                break;
            const next = &_instructions[index + 1];
            // Keep both writes and the separate copy as a branch target.
            static foreach (loadWidth; indirectCopyWidths) {
                if (instruction.handler is &opLoadIndirectFixed!loadWidth) {
                    static foreach (copyWidth; [1, 2, 4, 8, 16]) {
                        if (next.handler is &opCopyFixed!copyWidth)
                            instruction.handler = &opLoadThenCopy!(
                                loadWidth, copyWidth);
                    }
                }
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
            static foreach (width; indirectCopyWidths) {
                if (instruction.handler is &opLoadIndirectFixed!width)
                    instruction.handler = &opThenReturn!(opLoadIndirectFixed!width);
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

        foreach (ref reloc; _relocs)
            if (reloc.place.section == Place.Section.instruction)
                reloc.place.index = offsets[reloc.place.index];

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
                internalFailure(text("branch target ", *target,
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
            size_t[] repeats;
            branchOn(statement.condition, Jump.onTrue, repeats);
            foreach (index; repeats)
                patchTarget(index, bodyStart);
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
    protected override void visitWithOperand(WithStatement statement) {
        compileVariableInitializer(statement.wthis);
    }

    protected override void visitWithBody(WithStatement statement) {
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
        emit(&opRangeEnd, 0, 0, 0);
        foreach (range; protectedRanges(bodyStart, bodyEnd, finallyDepth))
            _exceptionHandlers ~= PendingExceptionHandler(
                typeid(Throwable), range.start, range.end, handler,
                size_t.max, cleanupEnd,
            );
        _finished = bodyFinished || cleanupFinished;
    }

    protected override void visitReturnOperand(
        ReturnStatement statement, bool readsAfterEnd,
    ) {
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
        _returnOffset = _layout.returnPlace.offset == size_t.max
            ? reserveTemp(_returnFacts)
            : indirectStorage(_layout.returnPlace.offset);
        if (readsAfterEnd)
            _returnAddress = compileAddress(
                FullExpressionScope.lvalueOf(statement.exp));
        else
            evalInto(statement.exp, _returnOffset, _returnFacts.size);
    }

    protected override void visitReturnTransfer(ReturnStatement statement) {
        const returnOffset = _returnOffset;
        if (_returnAddress != noReturnAddress) {
            emit(&opLoadIndirect, returnOffset, _returnAddress,
                _returnFacts.size);
            _returnAddress = noReturnAddress;
        }
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

    protected override size_t visitThrowOperand(
        Expression expression, bool readsAfterEnd,
    ) {
        import dmd.astenums: Tclass;

        if (!(expression !is null
                && expression.type.toBasetype.ty == Tclass))
            internalFailure("`throwSemantic` only accepts a `Throwable` class reference");

        if (readsAfterEnd)
            return compileAddress(FullExpressionScope.lvalueOf(expression));

        const facts = typeFacts(expression.type);
        const offset = reserveTemp(facts);
        evalInto(expression, offset, facts.size);
        return offset;
    }

    protected override void visitThrowTransfer(
        Expression, size_t offset, bool readsAfterEnd,
    ) {
        if (readsAfterEnd) {
            const thrown = reserveTemp(pointerFacts);
            emit(&opLoadIndirect, thrown, offset, pointerFacts.size);
            offset = thrown;
        }
        emit(&opThrow, offset, 0, 0, 0);
        _finished = true;
    }

    protected override void visitExpressionStatement(
        ExpStatement statement,
    ) {
        compileEffect(statement.exp);
    }

    protected override void visitIf(IfStatement statement, in IfPlan plan) {
        compileIf(statement, plan);
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
    // Case dispatch is a linear chain of equality tests against the
    // already-evaluated condition, each branching straight into its own
    // case's body once that body's own position is known (see
    // `recordCaseTarget`) - no jump table, since nothing about this
    // compiler's `Instruction` stream supports one.
    override void visit(SwitchStatement statement) {
        import snakebite.nativelayout: TypeFacts;

        if (throwIfStringSwitchInCtfeBlock(statement))
            return;

        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        auto plan = switchPlan(statement);
        const facts = typeFacts(statement.condition.type);
        assert(facts.isIntegral && isIntegralSize(facts.size));

        const conditionOffset = reserveTemp(facts);
        compileValue(FullExpressionScope.Position.switchOperand,
            statement.condition, conditionOffset, facts.size);

        foreach (case_; plan.cases) {
            const testOffset = reserveTemp(facts);
            emit(&opCopy, testOffset, conditionOffset, facts.size);
            const literalOffset = reserveTemp(facts);
            compileValue(FullExpressionScope.Position.switchOperand,
                case_.exp, literalOffset, facts.size);
            emit(&opEqual, testOffset, literalOffset, facts.size);

            const branchIndex = _instructions.length;
            emit(&opBranchTrue, testOffset, 0, 1);
            jumpToCase(case_, branchIndex);
        }

        const defaultJumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);
        _breakables ~= Breakable(label, null, _scopePaths.enclosing(statement));
        final switch (plan.noMatch) with (SwitchPlan.NoMatch) {
            case defaultTarget:
                jumpToDefault(statement, defaultJumpIndex);
                break;
            case exit:
                _breakables[$ - 1].pendingBreakJumps ~= defaultJumpIndex;
                break;
        }
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
            internalFailure("`visitDefault` rejects a `default` outside a `switch`");

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
            internalFailure("semantic3 rejects a `goto` to an undefined label");

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
    protected override void visitSwitchError(
        SwitchErrorStatement statement,
    ) {
        compileEffect(statement.exp);

        _finished = true;
    }

    override void visit(BreakStatement statement) {
        if (_breakables.length == 0)
            internalFailure("`visitBreak` rejects a `break` outside a loop or `switch`");

        const target = findBreakableIndex(statement.ident);
        if (target == size_t.max)
            internalFailure("`visitBreak` rejects a `break` to an unknown label");

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
    // associative array's handle, or an integral; both words, combined
    // here with one `opBitOr`, for a dynamic array (`ptr`, `length`) or
    // a delegate (`ptr`, `funcptr`) - so this backend
    // carries no case of its own for any of them; `conditionWidth` below
    // reports that same shared width back to this method's callers.
    private size_t compileCondition(
        Expression condition,
        in FullExpressionScope.Position position
            = FullExpressionScope.Position.condition,
        in bool inPlace = false,
    ) {
        import snakebite.nativelayout: TypeFacts;

        const truth = truthFacts(condition.type);

        const facts = typeFacts(condition.type);
        if (inPlace && !truth.isFloat && truth.offset == 0
                && truth.secondOffset == TypeFacts.Truth.noSecondWord) {
            const place = operandPlace(condition, facts.size, false, true);
            if (place != size_t.max)
                return place;
        }
        const valueOffset = reserveTemp(facts);
        compileValue(position, condition, valueOffset, facts.size);
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

    // The branch instructions for `if`, `for` and `while`: the loop or
    // `else` target is patched into each of them once it is known.
    private size_t[] compileConditionBranch(Expression condition) {
        size_t[] branches;
        branchOn(condition, Jump.onFalse, branches);
        return branches;
    }

    private size_t conditionWidth(Expression condition) {
        import snakebite.nativelayout: TypeFacts;

        const truth = truthFacts(condition.type);
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
                internalFailure();
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
        patchTarget(branchIndex, _instructions.length);
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
            constantArgument(Address(Target.Kind.frontendString, file), size_t.sizeof),
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
                Address(Target.Kind.frontendString, call.assertion),
                size_t.sizeof));
        } else {
            const call = cAssertCallOf(null, expression.loc, _function);
            const message = compileMessage(messageExpression);
            compileCAssertCall(call, Arg(
                message + arrayPointerOffset, 0, size_t.sizeof));
        }
    }

    private void compileCAssertCall(in CAssertCall call, in Arg assertion) {
        import snakebite.backends.druntimehooks: DruntimeHook, planOf;

        // Without a function, `cAssertCallOf` names it with a literal of the
        // host.
        const functionKind = call.function_[0] == 0
            ? Target.Kind.hostSymbol : Target.Kind.frontendString;
        Arg[] args = [
            assertion,
            constantArgument(Address(Target.Kind.frontendString, call.file), size_t.sizeof),
            constantArgument(call.line, uint.sizeof),
            constantArgument(
                Address(functionKind, call.function_), size_t.sizeof),
        ];
        auto plan = planOf(_bytecode._plans, DruntimeHook.cAssertFail);
        _callSites ~= CallSite.native(cast(const(void)*) plan, args, 0);
        emit(&opCall, discardResult, _callSites.length - 1, 0);
    }

    // The message of a failed assertion runs only then.
    private size_t compileMessage(Expression message) {
        const facts = typeFacts(message.type);
        const offset = reserveTemp(facts);
        compileValue(FullExpressionScope.Position.assertMessage,
            message, offset, facts.size);
        return offset;
    }

    private Arg constantArgument(in size_t value, in size_t width) {
        const offset = reserveTemp(pointerFacts);
        emit(&opConstant, offset, addConstant(cast(long) value), width);
        return Arg(offset, 0, width);
    }

    private Arg constantArgument(in Address address, in size_t width) {
        const offset = reserveTemp(pointerFacts);
        emit(&opConstant, offset, addConstant(address), width);
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
                    expression.loc, true,
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
    private void compileIf(IfStatement statement, in IfPlan plan) {
        if (plan.kind == IfPlan.Kind.ctfeBlock) {
            if (plan.bodyHasLabels)
                return compileCtfeBlockWithLabels(statement);

            if (statement.elsebody !is null)
                compileStatement(statement.elsebody);
            return;
        }

        const branchIndices = compileConditionBranch(statement.condition);

        compileStatement(statement.ifbody);
        const ifFinished = _finished;

        if (statement.elsebody is null) {
            foreach (branchIndex; branchIndices)
                patchTarget(branchIndex, _instructions.length);
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
        foreach (branchIndex; branchIndices)
            patchTarget(branchIndex, _instructions.length);

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
        inCtfeBlock({ compileStatement(statement.ifbody); });
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
        size_t[] branchIndices;
        if (guarded)
            branchIndices = compileConditionBranch(statement.condition);

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
            fullExpression(FullExpressionScope.Position.loopIncrement,
                statement.increment, {
                compileEffect(statement.increment);
            });

        emit(&opJump, conditionIndex, 0, 0);

        const afterLoop = _instructions.length;
        foreach (branchIndex; branchIndices)
            patchTarget(branchIndex, afterLoop);

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
            internalFailure("`visitContinue` rejects a `continue` outside a loop");

        const index = findLoopIndex(statement.ident);
        if (index == size_t.max)
            internalFailure("`visitContinue` rejects a `continue` to an unknown label");

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
        if (field is null)
            internalFailure("patchTarget met an instruction without a branch target");
        *field = target;
    }

    // Runs `expression` for effect, at statement level: whatever value it
    // produces (a call's return, an assignment's own value) is never read.
    private void compileEffect(Expression expression) {
        assert(_expressions.active,
            "a statement, condition or operand opened the full expression");
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
        in FullExpressionScope.Position position,
        Expression expression,
        in size_t destination,
        in size_t width,
    ) {
        if (_emittingCleanup)
            return evalInto(expression, destination, width);

        fullExpressionValue!size_t(position, expression,
            { evalInto(expression, destination, width); },
            (operand) { return compileAddress(operand); },
            (address) { emit(&opLoadIndirect, destination, address, width); });
    }

    // A destructor expression compiled into a cleanup runs inside the full
    // expression that registered it, and has no lifetime of its own.
    private void inFullExpression(
        in FullExpressionScope.Position position,
        Expression expression,
        scope void delegate() compile,
    ) {
        if (_emittingCleanup)
            return compile();

        fullExpression(position, expression, compile);
    }

    extern(D) protected override bool readsResultAfterEnd(
        in FullExpressionScope.Position position,
        Expression result,
    ) {
        return _expressions.readsResultAfterEnd(position, result);
    }

    extern(D) protected override void withFullExpression(
        in FullExpressionScope.Position position,
        Expression root,
        scope void delegate() evaluate,
    ) {
        size_t marker;
        size_t firstTemporary;
        _expressions.run(position, cast(const(void)*) root, {
            marker = _instructions.length;
            emit(null, 0, 0, 0);
            firstTemporary = _temporaries.length;
        }, evaluate, { endLifetime(marker, firstTemporary); });
    }

    private void endLifetime(in size_t marker, in size_t firstTemporary) {
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
            emit(&opRangeEnd, 0, 0, 0);
        }
        _temporaries.length = firstTemporary;
        _temporaries.assumeSafeAppend;
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
        const base = variableStorage(variable);
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

        assert(_expressions.active,
            "a statement, condition or operand opened the full expression");
        emitDeclaration();
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

        const facts = typeFacts(variable.type);
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

        const offset = variableStorage(variable);

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
    private Address staticAddressOf(VarDeclaration variable) {
        if (variable.isThreadLocalStorage)
            return Address(Target.Kind.tlsDescriptor,
                _bytecode._nativeData.tlsDescriptorOf(variable));
        return Address(Target.Kind.staticData,
            _bytecode._nativeData.storageOf(variable).ptr);
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
        if (compileDirectAssign(expression, destOffset))
            return;
        const target = compileAddress(expression);
        if (destOffset != discardResult) {
            if (auto dot = expression.e1.isDotVarExp) {
                auto field = dot.var.isVarDeclaration;
                if (field !is null
                        && field.isBitFieldDeclaration !is null) {
                    const facts = typeFacts(field.type);
                    emit(&opLoadBitfield, destOffset, target, facts.size,
                        bitfieldAccess(field).encode(facts.size));
                    return;
                }
            }
            emit(&opLoadIndirect, destOffset, target,
                typeFacts(expression.type).size);
        }
    }

    private void emitStaticStore(
        VarDeclaration variable,
        in size_t sourceOffset,
        in size_t width,
    ) {
        emit(staticStoreHandler(variable), staticAddressOf(variable),
            sourceOffset, width);
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

        const path = ClosurePlan.staticChainPath(_function, owner,
            (FuncDeclaration function_) => *_bytecode.layoutOf(function_));
        if (path is null)
            internalFailure("dmd rejects a reference to a frame the function has "
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

    private size_t variableStorage(VarDeclaration variable) {
        const offset = _layout.offsetOf(variable);
        return _layout.isReturnPlace(variable)
            ? indirectStorage(offset) : offset;
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
            if (_layout.isRef(variable) || _layout.isReturnPlace(variable))
                return _layout.offsetOf(variable);

            const result = reserveTemp(pointerFacts);
            emit(&opFrameAddress, result, _layout.offsetOf(variable),
                size_t.sizeof);
            return result;
        }

        if (owner is null)
            internalFailure("a local variable belongs to a function");

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

        const layout = *_bytecode.layoutOf(owner);
        if (!layout.hasSlot(variable))
            internalFailure("a frame layout reserves a slot for each of its locals");

        context = addPointerOffset(context, layout.offsetOf(variable));
        if (layout.isRef(variable) || layout.isReturnPlace(variable))
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
            internalFailure("a local variable belongs to a function");

        auto context = contextAddressOf(owner);
        const closurePlan = closurePlanOf(owner);
        if (closurePlan.needsClosure) {
            const closure = closurePlan.layout;
            if (!closure.hasSlot(variable))
                internalFailure("a closure's layout holds every variable captured from it");
            return addPointerOffset(context, closure.slotOf(variable).offset);
        }

        const layout = *_bytecode.layoutOf(owner);
        if (!layout.hasSlot(variable))
            internalFailure("a frame layout reserves a slot for each of its locals");
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
            internalFailure("a function that reads `this` reserves a slot for it");

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
            internalFailure("a `this` variable belongs to a function");

        auto context = contextAddressOf(owner);
        const closurePlan = closurePlanOf(owner);
        if (closurePlan.needsClosure) {
            const closure = closurePlan.layout;
            if (!closure.hasSlot(hiddenThis))
                internalFailure("a closure's layout holds every `this` captured from it");

            context = addPointerOffset(context, closure.slotOf(hiddenThis).offset);
        } else {
            const layout = *_bytecode.layoutOf(owner);
            if (!layout.hasSlot(hiddenThis))
                internalFailure("an owner's frame layout reserves a slot for its `this`");

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
                const facts = typeFacts(field.type);
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

        const facts = typeFacts(expression.e1.type);
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
            const facts = typeFacts(field.type);
            const valueOffset = reserveTemp(facts);
            evalInto(expression.e2, valueOffset, facts.size, expression.e1.type);
            emitBitfieldStore(field, target, valueOffset, facts.size);
            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

        const facts = typeFacts(target.type);

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
            typeFacts(field.type).size);
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
        const elementFacts = typeFacts(sarrayType.next);

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
                && !_layout.isReturnPlace(targetVariable)
                && _layout.hasSlot(targetVariable)
            ? _layout.offsetOf(targetVariable) : size_t.max;

        const baseOffset = resolvedTarget == size_t.max
            ? compileAddress(target.e1)
            : loadSlicePointer(resolvedTarget, typeFacts(target.type));

        const rightTy = expression.e2.type.toBasetype.ty;
        import snakebite.nativelayout: isStoredLiteral;

        if (isStoredLiteral(expression.e2)) {
            const facts = typeFacts(sarrayType);
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
            elementBase.ty == Tvoid ? 1 : typeFacts(elementType).size;

        const arrayFacts = typeFacts(target.type);
        const destSliceOffset = resolvedTarget == size_t.max
            ? reserveTemp(arrayFacts)
            : loadSliceDescriptor(resolvedTarget, arrayFacts);
        if (resolvedTarget == size_t.max)
            evalInto(target, destSliceOffset, arrayFacts.size);

        auto sourceElementType = expression.e2.type.nextOf;
        assert(sourceElementType !is null);
        const sourceElementBase = sourceElementType.toBasetype;

        const sourceElementSize = sourceElementBase.ty == Tvoid
            ? 1 : typeFacts(sourceElementType).size;
        assert(elementSize == sourceElementSize);

        const sourceFacts = typeFacts(expression.e2.type);
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
        const elementFacts = typeFacts(target.type.nextOf);
        const destSliceOffset =
            loadSliceDescriptor(resolvedTarget, typeFacts(target.type));
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

        if (compileDirectCompound(expression, destOffset))
            return;
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
        const targetFacts = typeFacts(target.type);
        const operationFacts = typeFacts(expression.e1.type);
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
                rightFacts = typeFacts(expression.e2.type);
                operationWidth = operationFacts.size / 2;
                operands = plan.operands.packed;
                break;
            case vector:
                return compileVectorCompoundAssign(
                    expression, plan, targetOffset, destOffset);
            case pointerDifference:
                internalFailure(text("`", expressionText(expression), "`: `-=` ",
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
                internalFailure(text("`", expressionText(expression), "`: dmd ",
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

        const facts = typeFacts(target.type);
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
                    && !_layout.isRef(variable)
                    && !_layout.isReturnPlace(variable))
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
                internalFailure("a vector or pointer target is never promoted");
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
            case complexToReal, complexToImaginary,
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
            case copy, classReference, zero, truth, sarrayToSlice,
                    sarrayToPointer, sliceToPointer, pointerToArray,
                    pointerToIntegral, delegateToPointer, reinterpretSlice,
                    narrow, widenSigned, widenUnsigned:
                internalFailure("this kind does not take a packed operand pair");
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

        internalFailure(text("`", expressionText(expression), "`: dmd lowers ",
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

        if (compileDirectPost(expression, destOffset))
            return;

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
                    typeFacts(expression.e1.type.toBasetype.nextOf);
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
                internalFailure(text("`", expressionText(expression), "`: a ",
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

    protected override void visitDeclaration(DeclarationExp expression) {
        if (_destination != discardResult && _expressions.active())
            return compileDeclaration(expression);
        assert(_destination == discardResult,
            "a declaration expression does not produce a value");

        compileDeclaration(expression);
    }

    extern(D) private void emitBytes(in void[] bytes) {
        assert(bytes.length == _width);
        emit(&opStaticLoad, _destination,
            Address(Target.Kind.staticData, bytes.ptr), bytes.length);
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

    extern(D) override void visitConstantBytes(Expression expression, in void[] bytes) {
        requireDestination(expression);
        emitBytes(_bytecode._nativeData.value(_valueType, bytes));
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

    override void visit(VectorExp expression) {
        import snakebite.backends.vectorinit: planVectorInit;

        requireDestination(expression);
        const plan = planVectorInit(expression);
        evalInto(expression.e1, _destination, plan.sourceFacts.size);
        foreach (i; 1 .. plan.count)
            emit(&opCopy, _destination + i * plan.sourceFacts.size,
                _destination, plan.sourceFacts.size);
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
                addConstant(Address(Target.Kind.staticData, initial.ptr)),
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

        const source = variableStorage(variable);

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
            internalFailure("`FuncExp`'s constructor always resolves its declaration");

        if (expression.type.toBasetype.ty != Tdelegate) {
            const address = _bytecode.operandAddress(expression.fd, 0);
            emit(&opConstant, _destination,
                addConstant(address),
                _width);
            return;
        }

        compileDelegateValue(
            delegateTargetOf(expression.fd, expression.type), expression);
    }

    override void visit(DelegateExp expression) {
        requireDestination(expression);

        if (expression.func is null)
            internalFailure("a `DelegateExp` names its method");
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
            internalFailure("a delegate value names its function");

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

        const address = _bytecode.operandAddress(target.function_, 0);
        emit(&opConstant, _destination + delegateFunctionOffset,
            addConstant(address),
            size_t.sizeof);
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

        const place = placeOf(expression, true);
        emit(&opCopy, _destination, place, _width);
    }

    // `s.field`, read as a value: a copy from the place of the field. An
    // aggregate that has no place (the result of a call) is evaluated into
    // a temporary first, and the field read out of that.
    override void visit(DotVarExp expression) {
        if (_destination == discardResult) {
            const facts = typeFacts(expression.type);
            const offset = reserveTemp(facts);
            evalInto(expression, offset, facts.size);
            return;
        }

        requireDestination(expression);

        auto field = expression.var.isVarDeclaration;
        assert(field !is null, "a field read names a variable");

        if (auto bitfield = field.isBitFieldDeclaration) {
            const facts = typeFacts(field.type);
            const addressOffset = compileFieldAddress(expression);
            emit(&opLoadBitfield, _destination, addressOffset, facts.size,
                bitfieldAccess(field).encode(facts.size));
            return;
        }

        const place = placeOf(expression, true);
        if (place != size_t.max) {
            emit(&opCopy, _destination, place, _width);
            return;
        }

        auto aggregateType = expression.e1.type.toBasetype;
        assert(aggregateType.isTypeStruct !is null,
            "a struct field has a struct or class receiver");

        const baseFacts = typeFacts(expression.e1.type);
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

        const length = placeOf(expression, true);
        if (length != size_t.max) {
            emit(&opCopy, _destination, length, _width);
            return;
        }

        const facts = typeFacts(expression.e1.type);
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
        const elementFacts = typeFacts(expression.e1.type.nextOf);
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
            typeFacts(expression.e1.type.toBasetype.nextOf).size,
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
                internalFailure(text("`", expression.toString, "` slices a `",
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
        const facts = typeFacts(sourceType);
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

        const elementFacts = typeFacts(sourceType.nextOf);
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

        const facts = typeFacts(sourceType);
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
            const elementFacts = typeFacts(expression.type);
            const offset = reserveTemp(elementFacts);
            evalInto(expression, offset, elementFacts.size);
            return;
        }

        requireDestination(expression);
        if (compileCheckedLoad(expression))
            return;
        const place = placeOf(expression, true);
        emit(&opCopy, _destination, place, _width);
    }

    protected override void visitStoredArrayLiteral(
            ArrayLiteralExp expression) {
        compileConstant(expression);
    }

    protected override void clearTemporaryPointer() {
        emit(&opConstant, _destination, addConstant(0), size_t.sizeof);
    }

    protected override void reserveLiteralStorage(ArrayLiteralExp expression) {
        const offset = _layout.arrayLiteralOffset(expression);
        emit(&opFrameAddress, _destination, offset, size_t.sizeof);
    }

    protected override FuncDeclaration currentFunction() {
        return _function;
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
        internalFailure("dmd lowers every associative array literal "
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
        const facts = typeFacts(expression.type);
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
            internalFailure("dmd lowers every heap `new` of a class that is not "
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
            emit(&opStaticLoad, object,
                Address(Target.Kind.staticData, runtime.m_init.ptr),
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
            emit(&opStaticLoad, image,
                Address(Target.Kind.staticData, runtime.m_init.ptr),
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
                internalFailure("dmd rejects `new T(a, b)` for a scalar `T`");
            const facts = typeFacts(expression.newtype);
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
                    compileEffect(
                        newPlan.argumentPrefix);
                compileResolvedCall(
                    expression.member, expression.arguments, expression.loc,
                    true, () => objectOffset,
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
            internalFailure("`TypeidExp` semantic leaves a type with its `TypeInfo`");

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
            addConstant(Address(Target.Kind.typeInfo, address)),
            width == size_t.max ? _width : width);
    }

    protected override void visitUnfoldedCall(CallExp expression) {
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

    extern(D) protected override void visitCtfeBlockError(
        string message, string file, size_t line,
    ) {
        const never = reserveTemp(pointerFacts);
        emit(&opConstant, never, addConstant(0), size_t.sizeof);
        _assertSites ~= AssertSite(message, file, line);
        emit(&opAssert, never, _assertSites.length - 1, size_t.sizeof);
        _finished = true;
    }

    protected override void visitUnloweredAssign(AssignExp expression) {
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

        const valueFacts = typeFacts(expression.e2.type);
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
        internalFailure("dmd lowers every `~` outside a `-betterC` scope "
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

    protected override void visitLogical(
        LogicalExp expression, in LogicalPlan plan,
    ) {
        compileLogical(expression, plan, _destination, _width);
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

        const facts = typeFacts(expression.type);
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
        const handler = typeFacts(expression.e1.type).isUnsigned
            ? unsignedHandler : signedHandler;
        compileBinaryExpression(expression, handler);
    }

    // `+`, `-`, `*`, `&`, `|`, `^`, `<<`, `>>`, `>>>`, `/`, `%`: both
    // operands are evaluated into temporaries of their own - never
    // `destOffset` directly, which can already be a variable either
    // operand itself reads (`x = y + x`; evaluating `y` straight into
    // `x`'s own slot would clobber `x` before it is read for the right
    // operand) - or, for a plain local, read in place (`operandInto`).
    // They are then combined in place with `handler`, already the
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
                if (auto handler3 = threeAddress(handler)) {
                    emitBinary3(handler3, destOffset, expression.e1,
                        expression.e2, plan.facts, width, No.floating);
                    return;
                }
                const leftOffset = reserveTemp(plan.facts);
                evalOperandInto(expression.e1, leftOffset, width);
                const rightOffset = reserveTemp(plan.facts);
                evalOperandInto(expression.e2, rightOffset, width);
                emit(handler, leftOffset, rightOffset, width);
                return copyResult(destOffset, leftOffset, width);
            }

            case floating: {
                if (auto handler3 = threeAddress(floatingBinaryHandler(expression))) {
                    emitBinary3(handler3, destOffset, expression.e1,
                        expression.e2, plan.facts, plan.facts.size, Yes.floating);
                    return;
                }
                const leftOffset = reserveTemp(plan.facts);
                evalInto(expression.e1, leftOffset, plan.facts.size);
                const rightOffset = reserveTemp(plan.facts);
                evalInto(expression.e2, rightOffset, plan.facts.size);
                emit(floatingBinaryHandler(expression), leftOffset,
                    rightOffset, plan.facts.size);
                return copyResult(destOffset, leftOffset, width);
            }

            case complex: {
                const leftFacts = typeFacts(expression.e1.type);
                const leftOffset = reserveTemp(plan.facts);
                evalInto(expression.e1, leftOffset, leftFacts.size);
                const rightFacts = typeFacts(expression.e2.type);
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
                internalFailure(text("`", expressionText(expression), "` has a ",
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

    // The three-address form of a two-address handler, or null.
    private Instruction.Handler threeAddress(Instruction.Handler handler) {
        static foreach (pair; [
            ["opAdd", "opAdd3"], ["opSubtract", "opSubtract3"],
            ["opMultiply", "opMultiply3"],
            ["opBitAnd", "opBitAnd3"], ["opBitOr", "opBitOr3"],
            ["opBitXor", "opBitXor3"], ["opShiftLeft", "opShiftLeft3"],
            ["opShiftRightLogical", "opShiftRightLogical3"],
            ["opShiftRightArithmetic", "opShiftRightArithmetic3"],
            ["opDivideSigned", "opDivideSigned3"],
            ["opDivideUnsigned", "opDivideUnsigned3"],
            ["opModuloSigned", "opModuloSigned3"],
            ["opModuloUnsigned", "opModuloUnsigned3"],
            ["opFloatAdd", "opFloatAdd3"],
            ["opFloatSubtract", "opFloatSubtract3"],
            ["opFloatMultiply", "opFloatMultiply3"],
            ["opFloatDivide", "opFloatDivide3"],
            ["opLessThanSigned", "opLessThanSigned3"],
            ["opLessThanUnsigned", "opLessThanUnsigned3"],
            ["opLessOrEqualSigned", "opLessOrEqualSigned3"],
            ["opLessOrEqualUnsigned", "opLessOrEqualUnsigned3"],
            ["opGreaterThanSigned", "opGreaterThanSigned3"],
            ["opGreaterThanUnsigned", "opGreaterThanUnsigned3"],
            ["opGreaterOrEqualSigned", "opGreaterOrEqualSigned3"],
            ["opGreaterOrEqualUnsigned", "opGreaterOrEqualUnsigned3"],
            ["opEqual", "opEqual3"], ["opNotEqual", "opNotEqual3"],
            ["opFloatEqual", "opFloatEqual3"],
            ["opFloatNotEqual", "opFloatNotEqual3"],
            ["opFloatLessThan", "opFloatLessThan3"],
            ["opFloatLessOrEqual", "opFloatLessOrEqual3"],
            ["opFloatGreaterThan", "opFloatGreaterThan3"],
            ["opFloatGreaterOrEqual", "opFloatGreaterOrEqual3"],
        ])
            if (handler is mixin("&" ~ pair[0]))
                return mixin("&" ~ pair[1]);
        return null;
    }

    private bool isRealFloatType(Type type) {
        import dmd.astenums: Tfloat32, Tfloat64, Tfloat80;
        import dmd.typesem: toBasetype;

        const ty = type.toBasetype.ty;
        return ty == Tfloat32 || ty == Tfloat64 || ty == Tfloat80;
    }

    // The frame offset of a plain local that `expression` reads, or
    // `size_t.max`. Plain: has a frame slot, not `ref`, not a closure
    // variable, not `$`, not a return place, not lazy.
    private size_t localSlot(Expression expression) {
        import dmd.astenums: STC;
        import snakebite.frontend.dmd.delegates: isCtfeVariable;

        auto read = expression.isVarExp;
        if (read is null)
            return size_t.max;
        auto variable = read.var.isVarDeclaration;
        if (variable is null || read.var.isSymbolDeclaration !is null
                || isCtfeVariable(read.var) || variable.isDataseg
                || isThisField(variable) || variable is _dollarVariable
                || !_layout.hasSlot(variable) || isClosureVariable(variable)
                || _layout.isRef(variable) || _layout.isReturnPlace(variable)
                || (variable.storage_class & (STC.lazy_ | STC.ref_ | STC.out_)))
            return size_t.max;
        return _layout.offsetOf(variable);
    }

    // The frame offset of a plain scalar local that `expression` reads, or
    // `size_t.max`. Integral, floating and pointer types only.
    private size_t operandOf(
        Expression expression, in size_t width, in bool floating,
    ) {
        const slot = localSlot(expression);
        if (slot == size_t.max || !isScalarOperand(expression.type, width, floating))
            return size_t.max;
        return slot;
    }

    // Whether `type` is a scalar that a three-address instruction reads at
    // `width` bytes: integral, floating, or a one-word reference.
    private bool isScalarOperand(
        Type type, in size_t width, in bool floating,
    ) {
        const facts = typeFacts(type);
        if (facts.size != width)
            return false;
        return floating
            ? isRealFloatType(type)
            : (facts.isIntegral || isReference(type))
                && isIntegralSize(facts.size);
    }

    // A pointer, a class reference or `typeof(null)`: one word that is
    // compared as an integer.
    private static bool isReference(Type type) {
        import dmd.astenums: Tclass, Tnull, Tpointer;
        import dmd.typesem: toBasetype;

        const ty = type.toBasetype.ty;
        return ty == Tpointer || ty == Tclass || ty == Tnull;
    }

    // A place is a storage operand: a frame offset, or an address held in a
    // frame slot plus a displacement (`indirectStorage`). Any handler
    // reads and writes either, so memory behind a pointer is an operand of
    // the instruction that uses it.
    private static bool isIndirect(in size_t place) {
        return (place & (1UL << 63)) != 0;
    }

    // `place` moved forward by `offset` bytes. A displacement that does not
    // fit its 32 bits goes through a pointer sum instead.
    private size_t placeAt(in size_t place, in size_t offset) {
        if (!isIndirect(place))
            return place + offset;
        const displacement = cast(uint) place;
        if (displacement + offset <= uint.max)
            return place + offset;
        const slot = (place >> 32) & 0x7fff_ffffUL;
        return indirectStorage(addPointerOffset(slot, displacement + offset));
    }

    // The place of the lvalue `expression` names, or `size_t.max` with no
    // code emitted. Code that must run first (loading a pointer, a null
    // check) is emitted in the order D evaluates it. A pointer held in a
    // plain local is used in place only when `inPlace` says that nothing
    // evaluated later can change it.
    private size_t placeOf(Expression expression, in bool inPlace) {
        import dmd.astenums: Tarray, Tclass;

        if (auto read = expression.isVarExp)
            return placeOfVariable(read);
        if (auto field = expression.isDotVarExp)
            return placeOfField(field, inPlace);
        if (auto dereference = expression.isPtrExp) {
            const slot = baseSlot(dereference.e1, inPlace);
            compileNullCheck(slot, dereference.loc);
            return indirectStorage(slot);
        }
        if (auto this_ = expression.isThisExp) {
            if (this_.type.toBasetype.ty == Tclass)
                return size_t.max;
            return indirectStorage(hiddenThisOffset(this_.var));
        }
        if (auto index = expression.isIndexExp)
            return placeOfIndex(index, inPlace);
        if (auto length = expression.isArrayLengthExp) {
            import snakebite.nativelayout: arrayLengthOffset;

            if (length.e1.type.toBasetype.ty != Tarray)
                return size_t.max;
            const array = placeOf(length.e1, inPlace);
            return array == size_t.max
                ? size_t.max : placeAt(array, arrayLengthOffset);
        }
        return size_t.max;
    }

    private size_t placeOfVariable(VarExp read) {
        import dmd.astenums: STC;
        import snakebite.frontend.dmd.delegates: isCtfeVariable;

        auto variable = read.var.isVarDeclaration;
        if (variable is null || read.var.isSymbolDeclaration !is null
                || isCtfeVariable(read.var) || variable.isDataseg
                || variable is _dollarVariable
                || variable.isBitFieldDeclaration !is null)
            return size_t.max;
        if (isThisField(variable))
            return placeAt(indirectStorage(hiddenThisOffset()),
                fieldOffset(variable));
        if (!_layout.hasSlot(variable) || isClosureVariable(variable)
                || (variable.storage_class & STC.lazy_))
            return size_t.max;
        const offset = _layout.offsetOf(variable);
        return _layout.isRef(variable)
            ? indirectStorage(offset) : variableStorage(variable);
    }

    private size_t placeOfField(DotVarExp expression, in bool inPlace) {
        import dmd.astenums: Tclass, Tpointer;

        auto field = expression.var.isVarDeclaration;
        if (field is null || field.isBitFieldDeclaration !is null
                || field.isDataseg)
            return size_t.max;

        const aggregate = expression.e1.type.toBasetype.ty;
        if (aggregate == Tclass || aggregate == Tpointer) {
            const slot = baseSlot(expression.e1, inPlace);
            compileNullCheck(slot, expression.e1.loc);
            return placeAt(indirectStorage(slot), field.offset);
        }
        const aggregatePlace = placeOf(expression.e1, inPlace);
        return aggregatePlace == size_t.max
            ? size_t.max : placeAt(aggregatePlace, field.offset);
    }

    // The element `expression` names. The address is computed here, after
    // the bounds check, so the place stays valid when the base changes
    // while a later operand is evaluated.
    private size_t placeOfIndex(IndexExp expression, in bool inPlace) {
        import dmd.astenums: Tarray, Tpointer, Tsarray;

        auto arrayType = expression.e1.type.toBasetype;
        switch (arrayType.ty) {
            case Tsarray:
                return placeOfStaticIndex(expression, arrayType, inPlace);
            case Tarray:
                return placeOfSliceIndex(expression, arrayType, inPlace);
            case Tpointer:
                return placeOfPointerIndex(expression, arrayType, inPlace);
            default:
                return size_t.max;
        }
    }

    // The index of a checked access: where it is, and what is added to it in
    // its own width.
    private struct CheckedIndex {
        size_t width;
        bool signed;
        long offset;
        // The frame slot that holds the index, or `size_t.max`.
        size_t slot = size_t.max;
        Expression expression;
        // A static array: the bounds are the constant `dimension`, and the
        // base is the storage of the elements.
        bool fixedLength;
        size_t dimension;
    }

    // Whether `expression` is an element of a slice or of a static array that
    // one instruction reads or writes after its bounds check. Emits no code.
    private bool checkedIndexShape(
        IndexExp expression, in size_t elementSize, out CheckedIndex shape,
    ) {
        import dmd.astenums: Tarray, Tsarray;
        import dmd.sideeffect: hasSideEffect;
        import snakebite.backends.checkplan: boundsPlanOf, FailurePlan;

        auto arrayType = expression.e1.type.toBasetype;
        shape.fixedLength = arrayType.ty == Tsarray;
        if (shape.fixedLength) {
            shape.dimension = cast(size_t) arrayType.isTypeSArray.dim.toInteger;
            if (shape.dimension > uint.max)
                return false;
        }
        if ((arrayType.ty != Tarray && !shape.fixedLength)
                || expression.lengthVar !is null
                || hasSideEffect(expression.e2)
                || !isPlainPlace(expression.e1))
            return false;
        if (typeFacts(arrayType.nextOf).size != elementSize
                || (elementSize != 1 && elementSize != 2 && elementSize != 4
                    && elementSize != 8))
            return false;
        if (boundsPlanOf(_bytecode.checks, _function).kind
                == FailurePlan.Kind.ignore)
            return false;
        // Semantic widens a 32-bit index to `size_t` with a cast.
        auto indexExpression = expression.e2;
        if (auto widening = indexExpression.isCastExp) {
            const narrow = typeFacts(widening.e1.type);
            if (narrow.isIntegral && narrow.size == 4
                    && typeFacts(widening.type).size == size_t.sizeof)
                indexExpression = widening.e1;
        }
        const index = typeFacts(indexExpression.type);
        if (!index.isIntegral || (index.size != 4 && index.size != 8))
            return false;
        shape.width = index.size;
        shape.signed = !index.isUnsigned;
        shape.expression = indexExpression;
        if (shape.fixedLength) {
            // A literal index is checked when the program is compiled; a
            // static array has no room for an offset beside its length.
            if (indexExpression.isIntegerExp)
                return false;
            shape.slot = operandOf(indexExpression, index.size, false);
            return true;
        }
        if (auto sum = indexExpression.isBinExp) {
            auto literal = sum.e2.isIntegerExp;
            if ((sum.op == EXP.add || sum.op == EXP.min) && literal !is null
                    && typeFacts(sum.e1.type).size == index.size
                    && typeFacts(sum.e1.type).isUnsigned == index.isUnsigned) {
                const local = operandOf(sum.e1, index.size, false);
                const value = sum.op == EXP.add
                    ? cast(long) literal.toInteger
                    : -cast(long) literal.toInteger;
                if (local != size_t.max && value >= int.min
                        && value <= int.max) {
                    shape.slot = local;
                    shape.offset = value;
                    return true;
                }
            }
        }
        shape.slot = operandOf(indexExpression, index.size, false);
        return true;
    }

    private bool compileCheckedLoad(IndexExp expression) {
        CheckedIndex shape;
        if (!checkedIndexShape(expression, _width, shape)
                || !isScalarOperand(expression.type, _width,
                    isRealFloatType(expression.type)))
            return false;
        const array = placeOf(expression.e1, true);
        if (array == size_t.max)
            return false;
        emitCheckedIndex(expression, shape, CheckedAccess.load, _destination,
            array);
        return true;
    }

    // `value` must have no side effect: the split store below reads the
    // array and the index again after `value` ran.
    private bool compileCheckedStore(
        IndexExp expression, Expression value, in size_t width,
        in bool floating,
    ) {
        import dmd.sideeffect: hasSideEffect;

        CheckedIndex shape;
        if (!checkedIndexShape(expression, width, shape))
            return false;
        const array = placeOf(expression.e1, true);
        if (array == size_t.max)
            return false;
        size_t operand = operandOf(value, width, floating);
        if (operand == size_t.max && !cannotFail(value)) {
            // Native order checks the left side first, so the bounds check
            // runs before the value, and the store after it needs none.
            if (hasSideEffect(value))
                internalFailure("a split checked store needs a value "
                    ~ "without side effects");
            resolveIndexSlot(shape);
            emitCheckedIndex(expression, shape, CheckedAccess.check,
                noValue, array);
            operand = reserveTemp(typeFacts(expression.type));
            evalInto(value, operand, width, expression.type);
            emitCheckedIndex(expression, shape, CheckedAccess.storeUnchecked,
                operand, array);
            return true;
        }
        if (operand == size_t.max) {
            operand = reserveTemp(typeFacts(expression.type));
            evalInto(value, operand, width, expression.type);
        }
        emitCheckedIndex(expression, shape, CheckedAccess.store, operand,
            array);
        return true;
    }

    // Whether evaluating `expression` cannot raise an `Error` or an
    // exception: literals, plain locals and arithmetic over them.
    private bool cannotFail(Expression expression) {
        switch (expression.op) {
            case EXP.int64, EXP.float64:
                return true;
            case EXP.variable:
                return localSlot(expression) != size_t.max;
            case EXP.cast_:
                return cannotFail(expression.isCastExp.e1);
            case EXP.negate, EXP.tilde:
                return cannotFail(expression.isUnaExp.e1);
            case EXP.add, EXP.min, EXP.mul, EXP.and, EXP.or, EXP.xor:
                auto binary = expression.isBinExp;
                return cannotFail(binary.e1) && cannotFail(binary.e2);
            default:
                return false;
        }
    }

    // Evaluates an index that is not a plain local into a temporary.
    private void resolveIndexSlot(ref CheckedIndex shape) {
        if (shape.slot != size_t.max)
            return;
        shape.slot = reserveTemp(typeFacts(shape.expression.type));
        evalInto(shape.expression, shape.slot, shape.width);
    }

    // The value operand of an access that has no value.
    private enum noValue = 0;

    // The access, then the failure code of the bounds check. The access
    // continues after the failure code when the index is in bounds. An
    // unchecked store has no failure code.
    private void emitCheckedIndex(
        IndexExp expression, CheckedIndex shape, in CheckedAccess access,
        in size_t value, in size_t array,
    ) {
        import snakebite.nativelayout: arrayLengthOffset;

        resolveIndexSlot(shape);
        const element = typeFacts(expression.type).size;
        const handler = checkedIndexHandler(access, shape.fixedLength,
            shape.width, shape.signed, element);
        const second = shape.fixedLength
            ? shape.dimension : cast(size_t) cast(uint) cast(int) shape.offset;
        const packed = shape.slot | (second << 32);
        if (access == CheckedAccess.storeUnchecked) {
            emit(handler, value, array, packed, 0);
            return;
        }
        const length = shape.fixedLength ? size_t.max
            : placeAt(array, arrayLengthOffset);
        auto indexType = shape.expression.type;
        compileIndexCheckWith({
            emit(handler, value, array, packed, 0);
        }, () {
            // The index the hook reports: the index plus the offset, in
            // the width of the index, then widened in place.
            const wide = reserveTemp(pointerFacts);
            emit(&opCopy, wide, shape.slot, shape.width);
            if (shape.offset != 0) {
                const offset = reserveTemp(typeFacts(indexType));
                emit(&opConstant, offset, addConstant(shape.offset),
                    shape.width);
                emit(&opAdd, wide, offset, shape.width);
            }
            if (shape.width != size_t.sizeof)
                emit(shape.signed ? &opCastWidenSigned : &opCastWidenUnsigned,
                    wide, shape.width, size_t.sizeof);
            return Arg(wide, 0, size_t.sizeof);
        }, () => shape.fixedLength
            ? constantArgument(shape.dimension, size_t.sizeof)
            : Arg(length, 0, size_t.sizeof), expression.loc);
    }

    // The value of a literal index that `$` does not depend on, or
    // `size_t.max`.
    private size_t literalIndex(IndexExp expression) {
        auto literal = expression.e2.isIntegerExp;
        if (literal is null || expression.lengthVar !is null)
            return size_t.max;
        return cast(size_t) literal.toInteger;
    }

    private size_t placeOfStaticIndex(
        IndexExp expression, Type arrayType, in bool inPlace,
    ) {
        import snakebite.nativelayout: arrayLengthOffset;

        const stride = typeFacts(arrayType.nextOf).size;
        const dimension = cast(size_t) arrayType.isTypeSArray.dim.toInteger;
        const literal = literalIndex(expression);
        if (literal < dimension)
            return placeAt(staticArrayPlace(expression.e1, inPlace),
                literal * stride);

        size_t dimensionSlot = size_t.max;
        if (expression.lengthVar !is null) {
            dimensionSlot = reserveTemp(pointerFacts);
            emit(&opConstant, dimensionSlot, addConstant(cast(long) dimension),
                size_t.sizeof);
        }
        const index = indexOperand(expression, dimensionSlot, expression.e1);
        compileIndexCheck(Comparison.lessThan, index,
            constantWord(dimension),
            () => Arg(index, 0, size_t.sizeof),
            () => constantArgument(dimension, size_t.sizeof),
            expression.loc);
        const array = staticArrayPlace(expression.e1, true);
        const address = reserveTemp(pointerFacts);
        emit(&opIndexStatic, address, array, stride, index);
        return indirectStorage(address);
    }

    // Where the elements of the static array `array` are.
    private size_t staticArrayPlace(Expression array, in bool inPlace) {
        const place = placeOf(array, inPlace);
        return place != size_t.max
            ? place : indirectStorage(compileAddress(array));
    }

    private size_t placeOfSliceIndex(
        IndexExp expression, Type arrayType, in bool inPlace,
    ) {
        import dmd.sideeffect: hasSideEffect;
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        const stride = typeFacts(arrayType.nextOf).size;
        const literal = literalIndex(expression);
        size_t array, index;
        if (expression.lengthVar !is null) {
            // `$` is the length before the index runs, and the index runs
            // after the array is read.
            array = sliceOperand(expression.e1, !hasSideEffect(expression.e2));
            const length = reserveTemp(pointerFacts);
            emit(&opCopy, length, placeAt(array, arrayLengthOffset),
                size_t.sizeof);
            index = indexOperand(expression, length, null);
        } else {
            if (literal != size_t.max && inPlace) {
                array = placeOf(expression.e1, true);
                if (array != size_t.max && !isIndirect(array)) {
                    compileIndexCheck(Comparison.greaterThan,
                        array + arrayLengthOffset, constantWord(literal),
                        () => constantArgument(literal, size_t.sizeof),
                        () => Arg(array + arrayLengthOffset, 0, size_t.sizeof),
                        expression.loc);
                    return placeAt(
                        indirectStorage(array + arrayPointerOffset),
                        literal * stride);
                }
                if (array != size_t.max)
                    return placeOfSliceAt(expression, array, stride,
                        literalOperand(literal));
            }
            index = indexOperand(expression, size_t.max, expression.e1);
            array = sliceOperand(expression.e1, true);
        }
        return placeOfSliceAt(expression, array, stride, index);
    }

    // A slice operand: the place of the slice, or a temporary that holds it.
    private size_t sliceOperand(Expression slice, in bool inPlace) {
        const place = placeOf(slice, inPlace);
        if (place != size_t.max)
            return place;
        const facts = typeFacts(slice.type);
        const temp = reserveTemp(facts);
        evalInto(slice, temp, facts.size);
        return temp;
    }

    private size_t placeOfSliceAt(
        IndexExp expression, in size_t array, in size_t stride,
        in size_t index,
    ) {
        import snakebite.nativelayout: arrayLengthOffset;

        const length = placeAt(array, arrayLengthOffset);
        compileIndexCheck(Comparison.lessThan, index, length,
            () => Arg(index, 0, size_t.sizeof),
            () => Arg(length, 0, size_t.sizeof),
            expression.loc);
        const address = reserveTemp(pointerFacts);
        emit(&opIndexSlice, address, array, stride, index);
        return indirectStorage(address);
    }

    private size_t placeOfPointerIndex(
        IndexExp expression, Type pointerType, in bool inPlace,
    ) {
        import dmd.sideeffect: hasSideEffect;

        const stride = typeFacts(pointerType.nextOf).size;
        const readInPlace = !hasSideEffect(expression.e2);
        auto pointer = isPlainPlace(expression.e1)
            ? operandPlace(expression.e1, size_t.sizeof, false, readInPlace)
            : size_t.max;
        if (pointer == size_t.max) {
            pointer = reserveTemp(pointerFacts);
            evalInto(expression.e1, pointer, size_t.sizeof);
        }
        const literal = literalIndex(expression);
        if (literal != size_t.max && inPlace && !isIndirect(pointer))
            return placeAt(indirectStorage(pointer), literal * stride);
        const index = indexOperand(expression, size_t.max, null);
        const address = reserveTemp(pointerFacts);
        emit(&opIndexPointer, address, pointer, stride, index);
        return indirectStorage(address);
    }

    // The index of `expression` as an operand of `size_t.sizeof` bytes.
    // `length` is `$` while the index is evaluated, and `later` is the
    // expression that runs after the index and before the instruction
    // that reads it.
    private size_t indexOperand(
        IndexExp expression, in size_t length, Expression later,
    ) {
        import dmd.sideeffect: hasSideEffect;

        auto savedDollarVariable = _dollarVariable;
        auto savedDollarOffset = _dollarOffset;
        scope (exit) {
            _dollarVariable = savedDollarVariable;
            _dollarOffset = savedDollarOffset;
        }
        if (expression.lengthVar !is null) {
            _dollarVariable = expression.lengthVar;
            _dollarOffset = length;
        }

        const place = operandPlace(expression.e2, size_t.sizeof, false,
            later is null || !hasSideEffect(later));
        if (place != size_t.max)
            return place;
        const index = reserveTemp(pointerFacts);
        evalOperandInto(expression.e2, index, size_t.sizeof);
        return index;
    }

    private size_t literalOperand(in size_t value) {
        const slot = reserveTemp(pointerFacts);
        emit(&opConstant, slot, addConstant(cast(long) value), size_t.sizeof);
        return slot;
    }

    // The address in the native constant pool of `value`.
    private Address constantWord(in size_t value) {
        return Address(Target.Kind.constantPool,
            _bytecode._nativeData.value(Type.tuns64, (&value)[0 .. 1]).ptr);
    }

    // A frame slot that holds the value of `pointer`. A plain local is that
    // slot when nothing evaluated later can change it.
    private size_t baseSlot(Expression pointer, in bool inPlace) {
        import dmd.astenums: Tclass;

        if (inPlace) {
            const local = localSlot(pointer);
            if (local != size_t.max)
                return local;
            if (auto this_ = pointer.isThisExp)
                if (this_.type.toBasetype.ty == Tclass)
                    return hiddenThisOffset(this_.var);
        }
        const slot = reserveTemp(pointerFacts);
        evalInto(pointer, slot, size_t.sizeof);
        return slot;
    }

    // A place for the scalar `operand` of `width` bytes, or `size_t.max`
    // with no code emitted. Only reads that start no call: the place is
    // used after the full expression of the operand ends.
    private size_t operandPlace(
        Expression operand, in size_t width, in bool floating,
        in bool inPlace,
    ) {
        if (!inPlace)
            return size_t.max;
        const local = operandOf(operand, width, floating);
        if (local != size_t.max)
            return local;
        if (!isPlainPlace(operand))
            return size_t.max;
        if (!isScalarOperand(operand.type, width, floating))
            return size_t.max;
        return placeOf(operand, true);
    }

    // A chain of fields, dereferences and `this` over variables: reading
    // it creates no temporary with a lifetime of its own.
    private bool isPlainPlace(Expression expression) {
        import dmd.astenums: STC;

        with (EXP) switch (expression.op) {
            case variable:
                auto variable = expression.isVarExp.var.isVarDeclaration;
                return variable !is null
                    && !(variable.storage_class & STC.lazy_);
            case this_:
                return true;
            case dotVariable:
                return isPlainPlace(expression.isDotVarExp.e1);
            case star:
                return isPlainPlace(expression.isPtrExp.e1);
            case arrayLength:
                return isPlainPlace(expression.isArrayLengthExp.e1);
            case index:
                auto indexed = expression.isIndexExp;
                return isPlainPlace(indexed.e1)
                    && isPlainCondition(indexed.e2);
            default:
                return false;
        }
    }

    // Where an operand of a three-address instruction is. A plain local is
    // used in place, unless `later` (the operand evaluated after this one)
    // has a side effect: it could write the local. A nothrow, strongly pure
    // call has none, and cannot write a caller's local.
    private size_t operandInto(
        Expression operand, Expression later,
        in imported!"snakebite.nativelayout".TypeFacts facts,
        in size_t width, in bool floating,
    ) {
        import dmd.sideeffect: hasSideEffect;

        const offset = operandPlace(operand, width, floating,
            later is null || !hasSideEffect(later));
        if (offset != size_t.max)
            return offset;
        const temp = reserveTemp(facts);
        _operandTemps[temp] = true;
        if (floating || isReference(operand.type)
                || operand.op == EXP.null_)
            evalInto(operand, temp, width);
        else
            evalOperandInto(operand, temp, width);
        return temp;
    }

    // The address of a literal operand in the native constant pool, or a null
    // address when `operand` is not a literal that reads as `width` bytes of
    // the operation's own kind. An integer literal narrower than the
    // operation is stored widened, as `evalOperandInto` does.
    private Address constantOf(
        Expression operand, in size_t width, in bool floating,
    ) {
        Type type;
        if (!literalType(operand, width, floating, type))
            return Address(Target.Kind.constantPool, size_t(0));
        if (operand.op == EXP.null_) {
            const size_t zero;
            return Address(Target.Kind.constantPool,
                _bytecode._nativeData.value(type, (&zero)[0 .. 1]).ptr);
        }
        return Address(Target.Kind.constantPool,
            _bytecode._nativeData.value(type, operand).ptr);
    }

    private bool isConstantOperand(
        Expression operand, in size_t width, in bool floating,
    ) {
        Type type;
        return literalType(operand, width, floating, type);
    }

    private bool literalType(
        Expression operand, in size_t width, in bool floating,
        out Type type,
    ) {
        if (operand.op == EXP.null_) {
            type = Type.tuns64;
            return !floating && width == size_t.sizeof;
        }
        if (floating ? operand.isRealExp is null : operand.isIntegerExp is null)
            return false;
        const facts = typeFacts(operand.type);
        type = operand.type;
        if (floating)
            return isRealFloatType(operand.type) && facts.size == width;
        if (!facts.isIntegral || !isIntegralSize(facts.size)
                || facts.size > width)
            return false;
        if (facts.size == width)
            return true;
        type = facts.isUnsigned
            ? (width == 8 ? Type.tuns64 : Type.tuns32)
            : (width == 8 ? Type.tint64 : Type.tint32);
        return typeFacts(type).size == width;
    }

    // The handler that gives the same answer with its operands swapped, or
    // null. A literal on the left is moved to the right through it.
    private Instruction.Handler swappedForm(Instruction.Handler handler) {
        static foreach (pair; [
            ["opAdd3", "opAdd3"], ["opMultiply3", "opMultiply3"],
            ["opBitAnd3", "opBitAnd3"], ["opBitOr3", "opBitOr3"],
            ["opBitXor3", "opBitXor3"],
            ["opFloatAdd3", "opFloatAdd3"],
            ["opFloatMultiply3", "opFloatMultiply3"],
            ["opEqual3", "opEqual3"], ["opNotEqual3", "opNotEqual3"],
            ["opFloatEqual3", "opFloatEqual3"],
            ["opFloatNotEqual3", "opFloatNotEqual3"],
            ["opLessThanSigned3", "opGreaterThanSigned3"],
            ["opGreaterThanSigned3", "opLessThanSigned3"],
            ["opLessThanUnsigned3", "opGreaterThanUnsigned3"],
            ["opGreaterThanUnsigned3", "opLessThanUnsigned3"],
            ["opLessOrEqualSigned3", "opGreaterOrEqualSigned3"],
            ["opGreaterOrEqualSigned3", "opLessOrEqualSigned3"],
            ["opLessOrEqualUnsigned3", "opGreaterOrEqualUnsigned3"],
            ["opGreaterOrEqualUnsigned3", "opLessOrEqualUnsigned3"],
            ["opFloatLessThan3", "opFloatGreaterThan3"],
            ["opFloatGreaterThan3", "opFloatLessThan3"],
            ["opFloatLessOrEqual3", "opFloatGreaterOrEqual3"],
            ["opFloatGreaterOrEqual3", "opFloatLessOrEqual3"],
        ])
            if (handler is mixin("&" ~ pair[0]))
                return mixin("&" ~ pair[1]);
        return null;
    }

    // One three-address instruction. A literal right operand is read from
    // the constant pool, and so is a literal left one when the operation
    // swaps; a literal left operand of `-` or `/` is loaded.
    private void emitBinary3(
        Instruction.Handler handler, in size_t destOffset,
        Expression left, Expression right,
        in imported!"snakebite.nativelayout".TypeFacts facts,
        in size_t width, in Flag!"floating" floatingOperands,
    ) {
        const floating = floatingOperands == Yes.floating;
        if (isConstantOperand(left, width, floating)
                && !isConstantOperand(right, width, floating)) {
            if (auto swapped = swappedForm(handler)) {
                handler = swapped;
                auto literal = left;
                left = right;
                right = literal;
            }
        }
        const leftOffset = operandInto(left, right, facts, width, floating);
        emitWithRight(handler, destOffset, leftOffset, right, facts, width,
            floating);
    }

    // `handler` on the operand at `left`, already evaluated, and `right`,
    // which is evaluated here.
    private void emitWithRight(
        Instruction.Handler handler, in size_t destOffset, in size_t left,
        Expression right, in imported!"snakebite.nativelayout".TypeFacts facts,
        in size_t width, in bool floating,
    ) {
        const constant = constantOf(right, width, floating);
        if (!constant.isNull)
            return emit(constantForm(handler), destOffset, left, width,
                constant);
        const rightOffset = operandInto(right, null, facts, width, floating);
        emit(handler, destOffset, left, width, rightOffset);
    }

    // A condition that creates no temporary with a lifetime of its own, so
    // that splitting `&&` and `||` into branches changes no destructor
    // order: scalar operations on scalar variables and literals. Calls,
    // aggregates, and everything else keep the value path.
    private bool isPlainCondition(Expression expression) {
        import dmd.astenums: STC, Tpointer;
        import dmd.typesem: toBasetype;

        const facts = typeFacts(expression.type);
        const scalar = (facts.isIntegral && isIntegralSize(facts.size))
            || isRealFloatType(expression.type)
            || expression.type.toBasetype.ty == Tpointer;
        if (!scalar)
            return false;

        with (EXP) switch (expression.op) {
            case int64, float64, null_:
                return true;
            case variable:
                auto variable = expression.isVarExp.var.isVarDeclaration;
                return variable !is null
                    && !(variable.storage_class & STC.lazy_);
            case add, min, mul, div, lessThan, lessOrEqual, greaterThan,
                    greaterOrEqual, equal, notEqual, andAnd, orOr:
                auto binary = expression.isBinExp;
                return isPlainCondition(binary.e1)
                    && isPlainCondition(binary.e2);
            case dotVariable, star, arrayLength, index:
                return isPlainPlace(expression);
            case identity, notIdentity:
                auto binary = expression.isBinExp;
                return identityPlan(binary.isIdentityExp).reference
                    && isPlainCondition(binary.e1)
                    && isPlainCondition(binary.e2);
            case cast_, negate, not:
                return isPlainCondition(expression.isUnaExp.e1);
            default:
                return false;
        }
    }

    private enum Jump : bool { onFalse = false, onTrue = true }

    // Code that jumps when `condition` is `jumpWhen` and falls through
    // otherwise. The jumps are appended to `branches` to be patched once
    // their target is known. An integral or floating comparison is one
    // compare-and-branch instruction. Jump-on-false of `a < b` is not
    // `a >= b` for NaN, so a comparison never changes its operator.
    // `&&`, `||` and `!` become branches only when `isPlainCondition`.
    private void branchOn(
        Expression condition, in bool jumpWhen, ref size_t[] branches,
        in FullExpressionScope.Position position
            = FullExpressionScope.Position.condition,
    ) {
        const splittable = condition.op == EXP.andAnd
            || condition.op == EXP.orOr || condition.op == EXP.not;
        const plain = splittable && isPlainCondition(condition);
        branchOnChecked(condition, jumpWhen, branches, position,
            plain ? Yes.plain : No.plain);
    }

    // Every operand of a plain condition is itself plain, so the check is
    // made once for the whole condition.
    private void branchOnChecked(
        Expression condition, in bool jumpWhen, ref size_t[] branches,
        in FullExpressionScope.Position position,
        in Flag!"plain" plain,
    ) {
        import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;

        const logical = condition.op == EXP.andAnd
            || condition.op == EXP.orOr;
        if (logical && plain == Yes.plain) {
            auto binary = condition.isBinExp;
            if ((condition.op == EXP.andAnd) != jumpWhen) {
                branchOnChecked(binary.e1, jumpWhen, branches, position,
                    Yes.plain);
                branchOnChecked(binary.e2, jumpWhen, branches,
                    FullExpressionScope.Position.logicalOperand, Yes.plain);
            } else {
                size_t[] decided;
                branchOnChecked(binary.e1, !jumpWhen, decided, position,
                    Yes.plain);
                branchOnChecked(binary.e2, jumpWhen, branches,
                    FullExpressionScope.Position.logicalOperand, Yes.plain);
                foreach (index; decided)
                    patchTarget(index, _instructions.length);
            }
            return;
        }

        if (condition.op == EXP.not && plain == Yes.plain) {
            branchOnChecked(condition.isUnaExp.e1, !jumpWhen, branches,
                position, Yes.plain);
            return;
        }

        Comparison operation;
        bool isComparison = true;
        with (EXP) switch (condition.op) {
            case lessThan: operation = Comparison.lessThan; break;
            case lessOrEqual: operation = Comparison.lessOrEqual; break;
            case greaterThan: operation = Comparison.greaterThan; break;
            case greaterOrEqual: operation = Comparison.greaterOrEqual; break;
            case equal: operation = Comparison.equal; break;
            case notEqual: operation = Comparison.notEqual; break;
            default: isComparison = false; break;
        }
        if (isComparison) {
            auto comparison = condition.isBinExp;
            const plan = comparisonPlan(comparison);
            const floating = plan.kind == ComparisonPlan.Kind.floating;
            if (floating || plan.kind == ComparisonPlan.Kind.integral
                    || plan.kind == ComparisonPlan.Kind.reference) {
                emitCompareBranch(comparison, operation, plan.facts,
                    floating, jumpWhen, position, branches);
                return;
            }
        }

        if (condition.op == EXP.identity || condition.op == EXP.notIdentity) {
            auto identity = condition.isIdentityExp;
            const plan = identityPlan(identity);
            if (plan.reference) {
                emitCompareBranch(identity,
                    condition.op == EXP.identity
                        ? Comparison.equal : Comparison.notEqual,
                    typeFacts(identity.e1.type), false, jumpWhen,
                    position, branches);
                return;
            }
        }

        const offset = compileCondition(condition, position, true);
        branches ~= _instructions.length;
        emit(jumpWhen ? &opBranchTrue : &opBranchFalse, offset, 0,
            conditionWidth(condition));
    }

    private void emitCompareBranch(
        BinExp comparison, Comparison operation,
        in imported!"snakebite.nativelayout".TypeFacts facts,
        in bool floating, in bool jumpWhen,
        in FullExpressionScope.Position position, ref size_t[] branches,
    ) {
        auto left = comparison.e1;
        auto right = comparison.e2;
        if (isConstantOperand(left, facts.size, floating)
                && !isConstantOperand(right, facts.size, floating)) {
            auto literal = left;
            left = right;
            right = literal;
            operation = mirrored(operation);
        }

        size_t leftOffset, rightOffset;
        Address rightConstant;
        fullExpression(position, comparison, {
            rightConstant = constantOf(right, facts.size, floating);
            if (!rightConstant.isNull)
                leftOffset = operandInto(left, null, facts, facts.size,
                    floating);
            else {
                leftOffset = operandInto(left, right, facts, facts.size,
                    floating);
                rightOffset = operandInto(right, null, facts, facts.size,
                    floating);
            }
        });
        const kind = floating ? CompareKind.floating
            : facts.isUnsigned || isReference(comparison.e1.type)
                ? CompareKind.unsigned : CompareKind.signed;
        branches ~= _instructions.length;
        if (!rightConstant.isNull)
            emit(fusedBranchHandler(operation, kind, jumpWhen, true),
                leftOffset, rightConstant, facts.size);
        else
            emit(fusedBranchHandler(operation, kind, jumpWhen, false),
                leftOffset, rightOffset, facts.size, 0);
    }

    private static Comparison mirrored(in Comparison operation) {
        final switch (operation) with (Comparison) {
            case lessThan: return greaterThan;
            case lessOrEqual: return greaterOrEqual;
            case greaterThan: return lessThan;
            case greaterOrEqual: return lessOrEqual;
            case equal: return equal;
            case notEqual: return notEqual;
        }
    }

    // `x = e` for a scalar target `x` that is a plain local or a place
    // (a field, a dereference), with `e` a literal, a read of a plain
    // local or of a place, or a binary operation of the three-address
    // kind: the result is written straight into the target. The instruction
    // that writes it is the last one and reads its operands first. Every
    // other `e` is evaluated into a temporary and copied to a place target,
    // and keeps `executeAssignment` for a local: some of them (`x = x++`)
    // write their destination before they finish.
    private bool compileDirectAssign(
        AssignExp expression, in size_t destOffset,
    ) {
        import dmd.expression: MemorySet;
        import dmd.sideeffect: hasSideEffect;

        // Binding a `ref` variable writes the pointer in its slot, not the
        // `int` it will refer to.
        if (expression.memset == MemorySet.referenceInit)
            return false;
        const facts = typeFacts(expression.e1.type);
        const floating = isRealFloatType(expression.e1.type);
        if (!isScalarOperand(expression.e1.type, facts.size, floating))
            return false;

        auto value = expression.e2;
        const direct = writesTargetLast(value, facts, floating);
        const local = operandOf(expression.e1, facts.size, floating);
        if (local != size_t.max) {
            // A call writes its result when it returns, after its arguments
            // were read, and an inlined one copies it last.
            if (!direct && value.op != EXP.call)
                return false;
            evalInto(value, local, facts.size, expression.e1.type);
            if (destOffset != discardResult && destOffset != local)
                emit(&opCopy, destOffset, local, facts.size);
            return true;
        }

        if (destOffset == discardResult && !hasSideEffect(value))
            if (auto indexed = expression.e1.isIndexExp)
                if (compileCheckedStore(indexed, value, facts.size,
                        floating))
                    return true;

        const target = placeOf(expression.e1, !hasSideEffect(value));
        if (target == size_t.max)
            return false;
        if (direct)
            evalInto(value, target, facts.size, expression.e1.type);
        else {
            const temp = reserveTemp(facts);
            evalInto(value, temp, facts.size, expression.e1.type);
            emit(&opCopy, target, temp, facts.size);
        }
        if (destOffset != discardResult)
            emit(&opCopy, destOffset, target, facts.size);
        return true;
    }

    // Whether evaluating `value` into its destination writes the
    // destination once, as the last thing it does.
    private bool writesTargetLast(
        Expression value, in imported!"snakebite.nativelayout".TypeFacts facts,
        in bool floating,
    ) {
        import snakebite.backends.arithmetic:
            ArithmeticPlan, arithmeticPlan;

        const valueFacts = typeFacts(value.type);
        with (EXP) switch (value.op) {
            case int64, float64:
                return valueFacts.size == facts.size
                    && isRealFloatType(value.type) == floating;
            case null_:
                return isReference(value.type);
            case variable:
                return operandOf(value, facts.size, floating) != size_t.max;
            case dotVariable, star, arrayLength, index:
                return isPlainPlace(value)
                    && isScalarOperand(value.type, facts.size, floating);
            case add, min, mul, div: {
                if (valueFacts.size != facts.size
                        || isRealFloatType(value.type) != floating)
                    return false;
                const plan = arithmeticPlan(value.isBinExp);
                return floating
                    ? plan.kind == ArithmeticPlan.Kind.floating
                        && plan.facts.size == facts.size
                    : plan.kind == ArithmeticPlan.Kind.integral
                        && plan.facts.size == facts.size;
            }
            case and, or, xor, mod, leftShift, rightShift, unsignedRightShift: {
                if (floating || valueFacts.size != facts.size)
                    return false;
                const plan = arithmeticPlan(value.isBinExp);
                return plan.kind == ArithmeticPlan.Kind.integral
                    && plan.facts.size == facts.size;
            }
            default:
                return false;
        }
    }

    // `x op= e` for a scalar `x` that is a plain local or a place, when no
    // conversion is needed (the operation has `x`'s type): one
    // three-address operation `x = x op e`. The right operand goes first,
    // as in the general path.
    private bool compileDirectCompound(
        BinAssignExp expression, in size_t destOffset,
    ) {
        import dmd.sideeffect: hasSideEffect;
        import snakebite.backends.arithmetic:
            ArithmeticPlan, arithmeticPlan;
        import snakebite.frontend.storage: compoundTarget;

        if (compoundTarget(expression) !is expression.e1)
            return false;
        const facts = typeFacts(expression.e1.type);
        const floating = isRealFloatType(expression.e1.type);
        if (!isScalarOperand(expression.e1.type, facts.size, floating))
            return false;

        const plan = arithmeticPlan(expression);
        if (plan.facts.size != facts.size)
            return false;
        if (floating ? plan.kind != ArithmeticPlan.Kind.floating
                : plan.kind != ArithmeticPlan.Kind.integral)
            return false;
        if (expression.isShlAssignExp || expression.isShrAssignExp
                || expression.isUshrAssignExp)
            return false;
        auto step = expression.e2;
        if (floating && (typeFacts(step.type).size != facts.size
                || !isRealFloatType(step.type)))
            return false;

        auto handler = threeAddress(compoundHandler(
            expression, facts.isUnsigned, floating));
        if (handler is null)
            return false;

        const slot = targetPlace(expression.e1, facts.size, floating, step);
        if (slot == size_t.max)
            return false;

        emitWithRight(handler, slot, slot, expression.e2, facts, facts.size,
            floating);
        if (destOffset != discardResult)
            emit(&opCopy, destOffset, slot, facts.size);
        return true;
    }

    // The operand for the scalar `target` that an instruction writes, or
    // `size_t.max` with no code emitted. A pointer it is reached through is
    // read in place only if `later`, which runs before the write, has no
    // side effect.
    private size_t targetPlace(
        Expression target, in size_t width, in bool floating,
        Expression later,
    ) {
        import dmd.sideeffect: hasSideEffect;

        const local = operandOf(target, width, floating);
        if (local != size_t.max)
            return local;
        return placeOf(target, later is null || !hasSideEffect(later));
    }

    // `x++` and `x--` for a scalar `x` of integral or floating type that is
    // a plain local or a place. The old value is copied out first, and only
    // when it is used.
    private bool compileDirectPost(
        PostExp expression, in size_t destOffset,
    ) {
        import snakebite.backends.arithmetic:
            ArithmeticPlan, arithmeticPlan;

        const facts = typeFacts(expression.e1.type);
        const floating = isRealFloatType(expression.e1.type);
        if (!isScalarOperand(expression.e1.type, facts.size, floating))
            return false;

        const plan = arithmeticPlan(expression);
        if (plan.facts.size != facts.size)
            return false;
        if (floating ? plan.kind != ArithmeticPlan.Kind.floating
                : plan.kind != ArithmeticPlan.Kind.integral)
            return false;

        const slot = targetPlace(expression.e1, facts.size, floating, null);
        if (slot == size_t.max)
            return false;

        const increment = expression.op == EXP.plusPlus;
        auto handler = threeAddress(floating
            ? (increment ? &opFloatAdd : &opFloatSubtract)
            : (increment ? &opAdd : &opSubtract));
        assert(handler !is null, "an increment has a three-address form");

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, slot, facts.size);
        emitWithRight(handler, slot, slot, expression.e2, facts, facts.size,
            floating);
        return true;
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
                internalFailure(text("`", expressionText(expression), "`: dmd ",
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

        const operandFacts = typeFacts(operand.type);
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
            if (typeFacts(literalType).size == width) {
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
                    default: internalFailure();
                }

                emitBinary3(threeAddress(pointerHandler), destOffset,
                    expression.e1, expression.e2, operandFacts,
                    operandFacts.size, No.floating);
                return;
            }

            // Host floating-point operators preserve D's NaN and signed-zero
            // semantics for equality and ordering. Integral equality instead
            // compares the stored bits, which would make a NaN equal itself and
            // positive and negative zero unequal.
            case floating: {
                auto floatHandler = floatComparisonHandler(expression);

                emitBinary3(threeAddress(floatHandler), destOffset,
                    expression.e1, expression.e2, operandFacts,
                    operandFacts.size, Yes.floating);
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
                internalFailure(text("`", expressionText(expression), "` cannot ",
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

                emitBinary3(threeAddress(handler), destOffset, expression.e1,
                    expression.e2, operandFacts, operandFacts.size, No.floating);
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
                internalFailure(text("`", expressionText(expression), "`: dmd ",
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
                internalFailure(text("`", expressionText(expression), "`: dmd ",
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
                internalFailure(text("`", expressionText(expression), "` has a ",
                    "vector lane that is neither integral nor floating"));
        }

        const laneSize = plan.laneFacts.size;
        const lanes = plan.facts.size / laneSize;
        const resultLaneSize = typeFacts(expression.type).size / lanes;
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

        if (plan.reference)
            return compileComparison(expression,
                ComparisonPlan(ComparisonPlan.Kind.reference,
                    typeFacts(expression.e1.type)),
                destOffset);

        const facts = typeFacts(expression.e1.type);
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
        const elementFacts = typeFacts(expression.e1.type.nextOf);

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
            operand, typeFacts(type));
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

        const leftFacts = typeFacts(expression.e1.type);
        const rightFacts = typeFacts(expression.e2.type);

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
            default: internalFailure();
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
                        internalFailure(text("`", expressionText(expression),
                            "` has a lane that is neither integral nor ",
                            "floating"));
                }
                foreach (i; 0 .. plan.facts.size / laneSize)
                    emit(laneHandler, destOffset + i * laneSize, 0, laneSize);
                return;
            }

            case pointerOffset, pointerDifference:
                internalFailure(text("`", expressionText(expression), "`: D has ",
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
        LogicalExp expression, in LogicalPlan plan,
        in size_t destOffset, in size_t width,
    ) {
        import dmd.astenums: Tbool;
        import dmd.typesem: toBasetype;

        const leftIsBool = expression.e1.type.toBasetype.ty == Tbool;
        const leftOffset = compileCondition(expression.e1,
            FullExpressionScope.Position.condition, leftIsBool);
        const leftInPlace = leftIsBool
            && operandOf(expression.e1, 1, false) == leftOffset;
        const leftWidth = conditionWidth(expression.e1);

        const branchIndex = _instructions.length;
        auto shortCircuit = plan.andAnd ? &opBranchFalse : &opBranchTrue;
        emit(shortCircuit, leftOffset, 0, leftWidth);

        const needsValue = destOffset != discardResult && plan.hasValue;
        if (plan.right == LogicalPlan.Right.effect
                || destOffset == discardResult) {
            inFullExpression(FullExpressionScope.Position.logicalOperand,
                expression.e2, { compileEffect(expression.e2); });
            // The operand can end in a throw, but the branch skips it.
            _finished = false;
            _instructions[branchIndex].source = _instructions.length;
            if (needsValue) {
                if (!leftInPlace)
                    emit(&opCastToBool, leftOffset, 0, leftWidth);
                if (destOffset != leftOffset)
                    emit(&opCopy, destOffset, leftOffset, 1);
            }
            return;
        }

        // The left side did not decide the answer: the right side's own
        // truthiness does.
        const rightOffset = compileCondition(
            expression.e2, FullExpressionScope.Position.logicalOperand);
        const rightWidth = conditionWidth(expression.e2);
        emit(&opCastToBool, rightOffset, 0, rightWidth);
        if (destOffset != rightOffset)
            emit(&opCopy, destOffset, rightOffset, 1);
        const jumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);

        // Short-circuited: the left side decided the answer by itself.
        _instructions[branchIndex].source = _instructions.length;
        if (!leftInPlace)
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
        // `copy`, `classReference`, `zero`, and `truth` are not: a plain
        // reinterpret needs no transformation at all, and the others
        // each need this compiler's own control flow or condition
        // code, so they emit their own bytecode below.
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

        // The operand's truth is the same one a condition tests; the
        // `bool` is that answer reduced to one byte.
        case truth: {
            const truthOffset = compileCondition(expression.e1);
            emit(&opCastToBool, truthOffset, 0, conditionWidth(expression.e1));
            emit(&opCopy, destOffset, truthOffset, 1);
            return;
        }

        // Each of these kinds reads its whole evaluated operand out of one
        // temporary; `emitPackedCast` knows which two sizes, and which one
        // signedness, the instruction carries for each.
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
        case pointerToFloat: {
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
        // `destOffset` while evaluating would overrun it;
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
        case truth:
            internalFailure();
        static foreach (member; EnumMembers!CastKind) {
            static if (member != copy && member != classReference
                    && member != zero && member != truth)
                case member:
                    return &opCastAs!member;
        }
        }
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
        import snakebite.frontend.dmd.dispatch: classReceiverOf;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto receiver = classReceiverOf(expression, callee);

        auto calleeType = typeFunctionOf(callee);
        if (arityMismatches(calleeType.parameterList, expression.arguments,
                calleeType.parameterList.varargs == VarArg.variadic))
            internalFailure("dmd rejects a call with the wrong number of arguments");

        auto returnType = calleeType.next;
        const isVoidCallee = returnType is null || returnType.ty == Tvoid;
        const returnFacts =
            isVoidCallee ? TypeFacts.init
                : calleeType.isRef ? pointerFacts : typeFacts(returnType);
        if (isVoidCallee && destOffset != discardResult)
            internalFailure("a `void` call is only ever evaluated for effect");

        const objectOffset = reserveTemp(pointerFacts);
        evalInto(receiver, objectOffset, size_t.sizeof);

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
            internalFailure("dmd gives every virtual method a vtbl slot");

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
        import snakebite.frontend.dmd.dispatch: readsVtable;
        import snakebite.frontend.dmd.functions: unresolvedCalleeOf;

        CallSelection.eachResolvedCalleePrefix(expression, &compileEffect);
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
        if (compileFloatIntrinsic(expression, callee, destOffset))
            return;
        if (compileNativeArrayNew(expression, callee, destOffset))
            return;
        if (expression.readsVtable(callee))
            return compileVirtualCall(expression, callee, destOffset);

        // Call sites and native call plans must agree on the hidden
        // context argument, including methods whose bodies stay native.
        import snakebite.frontend.dmd.delegates: hasHiddenThis;

        const hasThis = hasHiddenThis(callee);
        compileResolvedCall(
            callee, expression.arguments, expression.loc,
            hasThis,
            () => receiverOffsetOf(expression, callee),
            destOffset, expression);
    }

    // `new T[n]` lowers to `_d_newarrayT!T(n, false)`, whose chain of
    // templates the guest would interpret. druntime also exports the
    // non-template `_d_newarrayT`/`_d_newarrayiT`/`_d_newarrayU(ti, n)`,
    // which do the same work as compiled code: one native call instead.
    private bool compileNativeArrayNew(
        CallExp expression, FuncDeclaration callee, in size_t destOffset,
    ) {
        import dmd.dtemplate: isType;
        import dmd.location: Loc;
        import dmd.typesem: isZeroInit;
        import snakebite.frontend.compiler: newInFrontend;
        import snakebite.backends.druntimehooks: DruntimeHook, planOf;

        if (callee.ident is null || callee.parent is null)
            return false;
        const name = callee.ident.toString;
        if (name != "_d_newarrayT" && name != "_d_newarrayU")
            return false;
        auto instance = callee.parent.isTemplateInstance;
        if (instance is null || instance.tdtypes.length != 1
                || expression.arguments is null
                || expression.arguments.length == 0)
            return false;
        const declaration = callee.getModule.md;
        if (declaration is null || declaration.id.toString != "construction"
                || declaration.packages.length != 3
                || declaration.packages[0].toString != "core"
                || declaration.packages[1].toString != "internal"
                || declaration.packages[2].toString != "array")
            return false;
        auto elementType = isType(instance.tdtypes[0]);
        if (elementType is null)
            return false;

        const hook = name == "_d_newarrayU"
            ? DruntimeHook.newArrayUninitialized
            : newInFrontend!isZeroInit(elementType, Loc.initial)
            ? DruntimeHook.newArrayZeroed : DruntimeHook.newArrayInitialized;
        auto plan = planOf(_bytecode._plans, hook);

        const length = reserveTemp(pointerFacts);
        evalInto((*expression.arguments)[0], length, size_t.sizeof);
        const info = reserveTemp(pointerFacts);
        emitRuntimeTypeInfoConstant(
            expression.type, info, size_t.sizeof);
        _callSites ~= CallSite.native(
            cast(const(void)*) plan,
            [Arg(info, 0, size_t.sizeof), Arg(length, 0, size_t.sizeof)],
            2 * size_t.sizeof);
        emit(&opCall, destOffset, _callSites.length - 1, 0);
        return true;
    }

    // `core.math.sqrt` and `core.math.fabs` on a float type: the operand is
    // evaluated into the destination and a handler applies the operation in
    // place. Returns false when `expression` is not such a call.
    private bool compileFloatIntrinsic(
        CallExp expression, FuncDeclaration callee, in size_t destOffset,
    ) {
        import dmd.astenums: Tfloat32, Tfloat64, Tfloat80;

        if (destOffset == discardResult)
            return false;
        Instruction.Handler handler;
        final switch (_bytecode._callSelection.floatIntrinsicOf(expression, callee))
            with (CallSelection.FloatIntrinsic) {
            case none: return false;
            case sqrt: handler = &opFloatSqrt; break;
            case fabs: handler = &opFloatAbs; break;
        }
        const ty = expression.type.ty;
        // A declaration whose operand differs from its result (`double
        // fabs(real)`) is not the host's operation: it stays a call.
        if (ty != Tfloat32 && ty != Tfloat64 && ty != Tfloat80
                || (*expression.arguments)[0].type.ty != ty)
            return false;
        const width = typeFacts(expression.type).size;
        evalInto((*expression.arguments)[0], destOffset, width);
        emit(handler, destOffset, 0, width);
        return true;
    }

    // The address of `callee`'s own hidden `this` argument for `expression`
    // - a bound method's receiver, a delegating `super(args)`/`this(args)`
    // constructor call's, or the `this` a nested function reads implicitly
    // from an enclosing member function. `compileResolvedCall`'s native and
    // guest branches alike call this at most once, only when `callee`
    // actually reserves a slot for it.
    private size_t receiverOffsetOf(
        CallExp expression, FuncDeclaration callee,
    ) {
        const first = firstContextOffsetOf(expression, callee);
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
        CallExp expression, FuncDeclaration callee,
    ) {
        import snakebite.frontend.dmd.dispatch: CallReceiver, receiverOf;

        // DMD expressions must stay mutable for backend evaluation.
        auto receiver = receiverOf(expression, callee);
        final switch (receiver.kind) with (CallReceiver.Kind) {
        case enclosing:
            return contextOffsetOf(calleeContextSourceOf(_function, callee));
        case classValue:
            const object = reserveTemp(pointerFacts);
            evalInto(receiver.expression, object, size_t.sizeof);
            return object;
        case aggregateAddress:
            return receiverAddress(receiver.expression, expression);
        case implicitThis:
            return hiddenThisOffset;
        }
    }

    // The address of the receiver `aggregate` of `expression`. A pointer
    // held in a plain local is read in place when no argument can change
    // it before the callee runs.
    private size_t receiverAddress(Expression aggregate, CallExp expression) {
        import dmd.sideeffect: hasSideEffect;

        bool argumentsPure = true;
        if (expression.arguments !is null)
            foreach (argument; *expression.arguments)
                if (argument !is null && hasSideEffect(argument))
                    argumentsPure = false;
        with (EXP) switch (aggregate.op) {
            case variable, dotVariable, star, index: {
                const place = placeOf(aggregate, argumentsPure);
                if (place != size_t.max)
                    return addressOfPlace(place);
                break;
            }
            default:
                break;
        }
        return compileAddress(aggregate);
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
        bool hasThis,
        size_t delegate() thisOffsetOf,
        in size_t destOffset,
        Expression site = null,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        import snakebite.backends.calls: arityMismatches;

        size_t receiverOffset = size_t.max;
        if (hasThis)
            receiverOffset = thisOffsetOf();
        constructTemporary(callee,
            { emit(&opTemporarySuspend, 0, receiverOffset, 0); },
            { compileResolvedCallBody(callee, arguments, loc,
                hasThis, receiverOffset, destOffset, site); },
            { emit(&opTemporaryArm, 0, receiverOffset, 0); });
    }

    private void compileResolvedCallBody(
        FuncDeclaration callee,
        Expressions* arguments,
        Loc loc,
        bool hasThis,
        size_t receiverOffset,
        size_t destOffset,
        Expression site = null,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.backends.calls: arityMismatches;

        auto type = typeFunctionOf(callee);

        const hasNativeSymbol = _bytecode.hasNativeSymbol(callee);
        const decision = CallSelection.atCallSite(_bytecode._callSelection.decisionOf(
            callee, &_bytecode.isGuestFunction, hasNativeSymbol,
            _bytecode.hasIndependentNativeSymbol(callee),
        ), site);
        final switch (decision.route) with (CallSelection.Route) {
        case native:
            Arg[] initialArgs;
            if (hasThis)
                initialArgs ~= Arg(receiverOffset, 0, size_t.sizeof);

            compileNativeCall(
                callee, type, arguments, loc, initialArgs,
                destOffset, hasNativeSymbol);
            return;
        case builtin:
            compileBuiltinCall(type, arguments, loc,
                destOffset, decision.builtinEntry,
                decision.destinationParameter);
            return;
        case vaStart:
            compileVaStart(type, arguments, loc,
                destOffset, decision.builtinEntry);
            return;
        case vaCopy:
            compileVaCopy(type, arguments, loc,
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
        const calleeLayout = *_bytecode.layoutOf(callee);
        auto calleeType = typeFunctionOf(callee);

        if (arityMismatches(calleeType.parameterList, arguments,
                calleeType.parameterList.varargs == VarArg.variadic))
            internalFailure("dmd rejects a call with the wrong number of arguments");

        Arg[] args;
        // `calleeLayout.hiddenThis.variable`, not `hasThis`: a
        // `FuncLiteralDeclaration` bound through `auto` can keep a dead
        // `vthis` semantic proved nothing reads (see `FrameLayout.of`'s
        // own `hasDeadContext`), and `calleeLayout` is what actually
        // knows whether this callee's frame reserved it a slot.
        if (calleeLayout.hiddenThis.variable !is null) {
            if (!hasThis)
                internalFailure("dmd binds a hidden `this` to every call of a method");

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
            internalFailure("a `void` call is only ever evaluated for effect");

        if (calleeType.parameterList.varargs == VarArg.none) {
            if (auto inlinable = _bytecode.inlineBodyOf(callee)) {
                emitInlined(*inlinable, args, destOffset);
                emitReceiverResult(returnShape, destOffset, receiverOffset);
                return;
            }
        }

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
    // completed cache or locked compile gives both callers the same
    // finished pointer. The atomic store below publishes that result
    // for later calls through this site.
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
        Arg[] initialArgs,
        in size_t destOffset,
        in bool allowExtraArguments,
        scope CallSite delegate(Arg[] args, size_t returnWidth) site,
        in size_t destinationParameter = size_t.max,
    ) {
        import snakebite.backends.calls: arityMismatches;
        import snakebite.ffi.call: CallAdapter;

        if (arityMismatches(type.parameterList, arguments, allowExtraArguments))
            internalFailure("dmd rejects a call with the wrong number of arguments");

        const returnShape = CallAdapter.ofType(type);
        if (returnShape.isVoid && !returnShape.resultIsReceiver
                && destOffset != discardResult)
            internalFailure("a `void` call is only ever evaluated for effect");

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
        Arg[] initialArgs,
        in size_t destOffset,
        in bool hasNativeSymbol,
    ) {
        import snakebite.ffi.call: CallAdapter;

        compileBarrierCall(type, arguments, loc, initialArgs,
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
        in size_t destOffset,
        BuiltinCall entry,
        in size_t destinationParameter,
    ) {
        compileBarrierCall(type, arguments, loc, null,
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
        in size_t destOffset,
        BuiltinCall entry,
    ) {
        size_t cursor = _layout.variadicCursor;
        if (cursor == size_t.max) {
            cursor = reserveTemp(pointerFacts);
            emit(&opZero, cursor, 0, size_t.sizeof);
        }
        compileBarrierCall(type, arguments, loc,
            null, destOffset, /* allowExtraArguments */ false,
            (args, returnWidth) => CallSite.builtin(
                entry, args ~ Arg(cursor, 0, size_t.sizeof), returnWidth));
    }

    // The copy of a `va_list` lives in storage of the activation that makes
    // it, as `alloca`'s memory does: a slot with its address joins the
    // arguments.
    private void compileVaCopy(
        TypeFunction type,
        Expressions* arguments,
        Loc loc,
        in size_t destOffset,
        BuiltinCall entry,
    ) {
        import snakebite.backends.builtins: variadicCopySize;

        const size = reserveTemp(pointerFacts);
        emit(&opConstant, size, addConstant(cast(long) variadicCopySize),
            size_t.sizeof);
        const storage = reserveTemp(pointerFacts);
        emit(&opAlloca, storage, size, size_t.sizeof);
        compileBarrierCall(type, arguments, loc,
            null, destOffset, /* allowExtraArguments */ false,
            (args, returnWidth) => CallSite.builtin(
                entry, args ~ Arg(storage, 0, size_t.sizeof), returnWidth));
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
            facts ~= typeFacts(argument.type);
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
                internalFailure("dmd wraps a function pointer call's callee in a `PtrExp`");

            calleeOffset = reserveTemp(pointerFacts);
            evalInto(deref.e1, calleeOffset, size_t.sizeof);
            compileNullCheck(calleeOffset, expression.loc);
        }

        auto valueCall = ValueCall.of(functionType, isDelegateCall);
        if (valueCall.mismatches(expression.arguments))
            internalFailure("dmd rejects a call with the wrong number of arguments");

        // A `ref` return hands back its target's address in the return
        // register regardless of the pointee's own width - the same shape
        // `CallAdapter` already decides once for `compileResolvedCall`'s
        // guest branch and for `compileNativeCall`.
        import snakebite.ffi.call: CallAdapter;

        const returnShape = CallAdapter.ofType(functionType);
        const isVoidCallee = returnShape.isVoid;
        if (isVoidCallee && destOffset != discardResult)
            internalFailure("a `void` call is only ever evaluated for effect");

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
                        Address(Target.Kind.hostSymbol, call.assertion),
                        size_t.sizeof)));
                break;
            }
            case raise:
                compileUnlessHolds(inBoundsOffset, 1, false, () =>
                    compileFileLineHookCall(hookOf(check), extraArgs, loc));
                break;
        }
    }

    // Fails through the plan for an index check unless `left comparison
    // right` holds, both read unsigned. The check is one compare-and-branch
    // over the code that fails; the arguments of the druntime hook are made
    // in that code, where they cost nothing when the index is in bounds.
    private void compileIndexCheck(
        in Comparison comparison, in size_t left, in size_t right,
        scope Arg delegate() indexArgument,
        scope Arg delegate() lengthArgument,
        in Loc loc,
    ) {
        compileIndexCheckWith({
            emit(fusedBranchHandler(comparison, CompareKind.unsigned, true,
                    false),
                left, right, size_t.sizeof, 0);
        }, indexArgument, lengthArgument, loc);
    }

    // As above, with the right operand a constant of the native constant
    // pool.
    private void compileIndexCheck(
        in Comparison comparison, in size_t left, in Address right,
        scope Arg delegate() indexArgument,
        scope Arg delegate() lengthArgument,
        in Loc loc,
    ) {
        compileIndexCheckWith({
            emit(fusedBranchHandler(comparison, CompareKind.unsigned, true,
                    true),
                left, right, size_t.sizeof);
        }, indexArgument, lengthArgument, loc);
    }

    // `emitBranch` emits the compare-and-branch.
    private void compileIndexCheckWith(
        scope void delegate() emitBranch,
        scope Arg delegate() indexArgument,
        scope Arg delegate() lengthArgument,
        in Loc loc,
    ) {
        import snakebite.backends.checkplan:
            boundsPlanOf, cMessageOf, FailurePlan;
        import snakebite.backends.exceptions: cAssertCallOf;

        const plan = boundsPlanOf(_bytecode.checks, _function);
        if (plan.kind == FailurePlan.Kind.ignore)
            return;

        const branchIndex = _instructions.length;
        emitBranch();
        final switch (plan.kind) with (FailurePlan.Kind) {
            case ignore:
                internalFailure();
            case halt: {
                const never = reserveTemp(pointerFacts);
                emit(&opConstant, never, addConstant(0), size_t.sizeof);
                emit(&opAssert, never, haltSite, size_t.sizeof);
                break;
            }
            case cAssert: {
                const call = cAssertCallOf(
                    cMessageOf(BoundsCheck.index).ptr, loc, _function);
                compileCAssertCall(call, constantArgument(
                    Address(Target.Kind.hostSymbol, call.assertion),
                    size_t.sizeof));
                break;
            }
            case raise:
                compileFileLineHookCall(hookOf(BoundsCheck.index),
                    [indexArgument(), lengthArgument()], loc);
                break;
        }
        patchTarget(branchIndex, _instructions.length);
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
                        Address(Target.Kind.hostSymbol, call.assertion),
                        size_t.sizeof)));
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
            addConstant(Address(Target.Kind.frontendString, loc.filename)),
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

            const thenOffset = resolve(
                FullExpressionScope.lvalueOf(expression.e1));
            compiler.emit(&opCopy, result, thenOffset, size_t.sizeof);
            const jumpIndex = compiler._instructions.length;
            compiler.emit(&opJump, 0, 0, 0);

            compiler._instructions[branchIndex].source =
                compiler._instructions.length;
            const elseOffset = resolve(
                FullExpressionScope.lvalueOf(expression.e2));
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

            const facts = typeFacts(expression.e1.type);
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
                typeFacts(expression.e1.type.toBasetype.nextOf).size;
            const strideOffset = compiler.reserveTemp(compiler.pointerFacts);
            compiler.emit(&opConstant, strideOffset,
                compiler.addConstant(cast(long) stride), size_t.sizeof);
            compiler.emit(&opMultiply, index, strideOffset, size_t.sizeof);

            const facts = typeFacts(expression.e1.type);
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
                typeFacts(expression.e1.type.toBasetype.nextOf).size;
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
                typeFacts(expression.e1.type.toBasetype.nextOf).size;
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
            const facts = typeFacts(expression.type);
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
                const address = compiler._bytecode.operandAddress(function_, 0);
                compiler.emit(&opConstant, result,
                    compiler.addConstant(address),
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

    // The address of `expression` as a pointer in a frame slot. A place is
    // its own address: a frame offset needs `opFrameAddress`, and memory
    // behind a pointer already has the pointer in a slot.
    private size_t compileAddress(Expression expression) {
        import snakebite.frontend.storage: StorageResolver;

        with (EXP) switch (expression.op) {
            case variable, dotVariable, star, index: {
                const place = placeOf(expression, false);
                if (place != size_t.max)
                    return addressOfPlace(place);
                break;
            }
            default:
                break;
        }
        return StorageResolver!(size_t, StorageAdapter)(StorageAdapter(this))
            .resolve(expression);
    }

    private size_t addressOfPlace(in size_t place) {
        if (!isIndirect(place)) {
            const address = reserveTemp(pointerFacts);
            emit(&opFrameAddress, address, place, size_t.sizeof);
            return address;
        }
        const slot = (place >> 32) & 0x7fff_ffffUL;
        const displacement = cast(uint) place;
        return displacement == 0 ? slot : addPointerOffset(slot, displacement);
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
