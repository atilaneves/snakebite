module snakebite.backends.bytecode.vm;


private:


import snakebite.internalfailure: internalFailure;


extern(C) void executeCallPlan(
    const(void)* opaquePlan,
    void* returnPlace,
    scope const(void*)* arguments,
    size_t argumentCount,
);

extern(C) bool executeIndirectCallPlan(
    const(void)* opaquePlan, ref const(void)* address, void* returnPlace,
    scope const(void*)* arguments, size_t argumentCount,
    out ptrdiff_t contextAdjustment,
);

import snakebite.backends.argumentflow: ArgumentFlow, Shape, Signature;
import snakebite.backends.builtins: BuiltinCall;
import snakebite.backends.haltprocess: HaltAction, isHalt;
import snakebite.backends.unwindplan:
    ExceptionCandidate, UnwindPlan, unwindPlanOf;
import snakebite.callarguments: CallArguments;
import snakebite.nativevalue: TypeFacts;
import snakebite.nativevalue:
    CastKind, ComplexOperation, floatingToBool, loadFloating, loadSigned,
    loadUnsigned, shiftCount, storeFloating, storeIntegral;
import object: Throwable, TypeInfo_Class;
import core.bitop: bsf;
import std.meta: AliasSeq;
import std.traits: EnumMembers;

private alias storeWidth = storeIntegral;


// One argument a call instruction copies from the caller's frame into the
// callee's, at compile time already resolved to both sides' byte offsets
// and the width to copy - the same three numbers `opCopy` needs for a
// same-frame copy, just crossing into a frame that does not exist yet
// when the call instruction runs.
public struct Arg {
    package size_t callerOffset;
    package size_t calleeOffset;
    package size_t width;
}


// One call site: how `opCall` reaches its callee, the arguments to hand
// it, and the width of the value it hands back (`0` for a `void` callee).
// This is the whole interface the bytecode compiler and this VM agree on
// for a call: the compiler picks a `Kind` and builds the site through
// that kind's own factory below, and `opCall`'s `final switch` reads back
// only the fields its `Kind` names: `guest` and `native` each read either
// the prepared value or the delegate that prepares it on first execution.
public struct CallSite {
    public enum Kind {
        // `callee` names a compiled function, or `prepareGuest` compiles
        // and caches it when the call first executes.
        guest,
        // `nativePlan` is a `snakebite.ffi.plan.CallPlan`, opaque to this
        // module, run through `executeCallPlan` - prepared either for a
        // guest-declared `extern(C)` function or for a druntime hook the
        // compiler resolved by linker symbol (an allocation, a `~=`
        // dchar append, a bounds check): the same shape either way, so
        // this VM hardcodes no druntime signature for any of them.
        // An unresolved target uses `prepareNativePlan` on first execution.
        native,
        // `calleeSlotOffset` is the caller's own frame offset holding a
        // `const(Function)*` value read back at run time in place of a
        // fixed `callee` - a call through a function pointer or delegate
        // value. Native addresses, including vtable entries, use the
        // call site's prepared native plan.
        indirect,
        // An `indirect` call through a function pointer or a delegate value:
        // `value.signature` is the signature of the value's type, and a callee
        // with another signature reads its parameters by register.
        value,
        // `builtinEntry` is a `snakebite.backends.builtins.BuiltinCall`,
        // resolved once by `CallSelection` (`snakebite.backends.calls`)
        // and never re-resolved: a compiler intrinsic (`core.math.fabs`
        // and the like), which has no host symbol FFI could ever find, so this VM calls the entry
        // directly instead of going through `executeCallPlan`.
        builtin,
    }

    // `callee` already compiled, called directly.
    public static CallSite guest(
        const(Function)* callee, Arg[] args, size_t returnWidth,
    ) {
        CallSite site;
        site.kind = Kind.guest;
        site.callee = callee;
        site.args = args;
        site.returnWidth = returnWidth;
        return site;
    }

    public static CallSite guest(
        const(Function)* delegate() prepare, Arg[] args, size_t returnWidth,
    ) {
        auto site = guest(cast(const(Function)*) null, args, returnWidth);
        site.prepareGuest = prepare;
        return site;
    }

    // A prepared FFI plan for a native symbol, called through
    // `executeCallPlan`.
    public static CallSite native(
        const(void)* nativePlan, Arg[] args, size_t returnWidth,
    ) {
        CallSite site;
        site.kind = Kind.native;
        site.nativePlan = nativePlan;
        site.args = args;
        site.returnWidth = returnWidth;
        return site;
    }

    public static CallSite native(
        const(void)* delegate() prepare, Arg[] args, size_t returnWidth,
    ) {
        auto site = native(cast(const(void)*) null, args, returnWidth);
        site.prepareNativePlan = prepare;
        return site;
    }

    // `calleeSlotOffset` names the caller frame slot `opCall` reads the
    // callee's own address back out of at run time.
    // `args` feed a guest callee's frame; `nativeArgs` feed `nativePlan`.
    public static CallSite indirect(
        size_t calleeSlotOffset, Arg[] args, Arg[] nativeArgs,
        size_t returnWidth,
        const(void)* nativePlan = null,
        bool hasContext = false,
    ) {
        CallSite site;
        site.kind = Kind.indirect;
        site.nativePlan = nativePlan;
        site.calleeSlotOffset = calleeSlotOffset;
        site.hasContext = hasContext;
        site.args = args;
        site.nativeArgs = nativeArgs;
        site.returnWidth = returnWidth;
        return site;
    }

    // No lazy-preparation overload: unlike `native`, a builtin's entry
    // is already resolved and never depends on a linker symbol lookup.
    public static CallSite builtin(
        BuiltinCall entry, Arg[] args, size_t returnWidth,
    ) {
        CallSite site;
        site.kind = Kind.builtin;
        site.builtinEntry = entry;
        site.args = args;
        site.returnWidth = returnWidth;
        return site;
    }

    // What a call through a value of a function type adds: the signature of
    // the type, and the variadic arguments of the call with their shapes. A
    // callee with another signature reads its parameters from the arguments
    // that are in the same registers (`ArgumentFlow`). `signature` is null
    // for every other call.
    public struct ValueArguments {
        package const(Signature)* signature;
        package Arg[] surplus;
        package const(Shape)[] surplusShapes;
    }

    package Kind kind;
    package ValueArguments value;
    package Arg[] args;
    package Arg[] nativeArgs;
    package size_t returnWidth;
    package const(Function)* callee;
    package const(Function)* delegate() prepareGuest;

    // What `opCall` needs of a `guest` site whose callee is compiled, in
    // one place. The fields other than `state` are valid once `state` is
    // `ready`.
    package struct FastCall {
        package enum State : uint {
            unprepared,
            preparing,
            ready,
            notEligible,
        }

        package uint state;
        package const(Function)* callee;
        package size_t frameBytes;
        package size_t frameOffset;
        package uint alignment;
        package size_t returnPlaceOffset = size_t.max;
        package size_t returnWidth;
        package const(Arg)* args;
        package size_t argCount;
    }

    package FastCall fast;

    // Compiles the callee of a `guest` site on its first call and keeps it
    // in `callee`: a later call reads the field, not `prepareGuest`. Two
    // threads that race here store the same value.
    package const(Function)* cacheCallee() const {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;

        auto cached = atomicLoad!(MemoryOrder.acq)(
            *cast(const(Function)**) &callee);
        if (cached !is null)
            return cached;
        auto compiled = prepareGuest();
        atomicStore!(MemoryOrder.rel)(
            *cast(const(Function)**) &callee, compiled);
        return compiled;
    }

    // True when `opCall` builds the activation of this site itself. The
    // first call decides once, for good: a site whose callee has a closure
    // or needs a context conversion stays `notEligible`. Only the thread
    // that wins the `preparing` state writes the fields, and it publishes
    // `state` last; a thread that loses takes the generic path for that
    // call.
    package bool prepareFast() const {
        import core.atomic: atomicLoad, atomicStore, cas, MemoryOrder;

        auto slot = cast(FastCall*) &fast;
        const state = atomicLoad!(MemoryOrder.acq)(
            *cast(shared(uint)*) &slot.state);
        if (state == FastCall.State.ready)
            return true;
        if (state != FastCall.State.unprepared)
            return false;
        if (!cas(cast(shared(uint)*) &slot.state,
                uint(FastCall.State.unprepared),
                uint(FastCall.State.preparing)))
            return false;
        const eligible = kind == Kind.guest && fill(*slot);
        atomicStore!(MemoryOrder.rel)(
            *cast(shared(uint)*) &slot.state,
            uint(eligible ? FastCall.State.ready : FastCall.State.notEligible));
        return eligible;
    }

    // Fills `slot` for a callee whose activation `opCall` builds without
    // the generic decoding: no closure and no context conversion. A
    // callee with a return place also needs a result place at the site;
    // `opCall` checks that per call.
    private bool fill(ref FastCall slot) const {
        const function_ = cacheCallee();
        if (function_.closureOffset != size_t.max
                || (hasContext && function_.contextOffset == size_t.max))
            return false;
        assert(function_.frameAlignment > 0
            && (function_.frameAlignment & (function_.frameAlignment - 1)) == 0);
        const alignment = function_.frameAlignment > uint(Activation.alignof)
            ? function_.frameAlignment : uint(Activation.alignof);
        slot.frameOffset =
            (Activation.sizeof + alignment - 1) & ~(size_t(alignment) - 1);
        slot.alignment = alignment;
        slot.frameBytes = slot.frameOffset + function_.frameSize;
        slot.returnPlaceOffset = function_.returnPlace.offset;
        slot.returnWidth = returnWidth;
        slot.args = args.ptr;
        slot.argCount = args.length;
        slot.callee = function_;
        return true;
    }

    package const(void)* nativePlan;
    package const(void)* delegate() prepareNativePlan;
    package BuiltinCall builtinEntry;
    package size_t calleeSlotOffset;
    package bool hasContext;
    package size_t cleanupStartIndex = size_t.max;
    package size_t cleanupEndIndex = size_t.max;
    package const(void)* cleanupStart;
    package const(void)* cleanupEnd;

    public static CallSite temporary() {
        CallSite site;
        return site;
    }
}


// One value moved from a function's activation frame into its closure.
// Both offsets and the width are resolved by the compiler before the VM
// runs.
package struct ClosureSlot {
    package size_t sourceOffset;
    package size_t closureOffset;
    package size_t width;
}


// `opCall`'s own `pc.destination` operand, when the caller has nowhere for
// the call's result to go - a `void` callee, or a non-`void` one run at
// statement level for its effects alone. Not a byte offset any frame ever
// has, so it cannot collide with one: `_tempSize`/`layout.size` never grow
// past a compiled function's own frame size, which stays far short of
// `size_t.max`.
public enum discardResult = size_t.max;


// Storage operands retain byte-offset arithmetic for aggregate fields. The
// upper word names an address slot when the high bit is set; the lower word
// is the displacement from that address. Other instruction operands (branch
// targets, constants, and call sites) are decoded separately from storage.
package size_t indirectStorage(in size_t addressSlot) @safe pure nothrow @nogc {
    assert(addressSlot < (1UL << 31));
    return (1UL << 63) | (addressSlot << 32);
}

// The handler adapter owns operand decoding. An operation receives native
// addresses for storage and integer words for immediates, so it cannot
// accidentally interpret a branch target or constant index as frame storage.
private enum OperandKind {
    storage,
    immediate,
    result,
}

private struct Execution(OperandKind destinationKind, OperandKind sourceKind) {
    static if (destinationKind == OperandKind.immediate)
        public size_t destination;
    else
        public ubyte* destination;
    static if (sourceKind == OperandKind.immediate)
        public size_t source;
    else
        public ubyte* source;

    public void* returnPlace;
    public const(long)[] constants;
    public const(CallSite)[] callSites;
    public const(AssertSite)[] assertSites;
    public FrameStack* frames;
    private DispatchState* _dispatch;

    private const(Instruction)* _pc;
    private ubyte* _frame;
    private size_t _cleanupMark;

    public this(
        const(Instruction)* pc, Activation* activation, DispatchState* state,
    ) pure nothrow @nogc {
        _pc = pc;
        _frame = activation.frame;
        _cleanupMark = activation.cleanupMark;
        this.returnPlace = activation.returnPlace;
        this.constants = activation.constants;
        this.callSites = activation.callSites;
        this.assertSites = activation.assertSites;
        this.frames = state.frames;
        _dispatch = state;
        destination = decode!destinationKind(pc.destination);
        source = decode!sourceKind(pc.source);
    }

    public const(Instruction)* next() const pure nothrow @nogc {
        return _pc + 1;
    }

    public size_t width() const @safe pure nothrow @nogc {
        return _pc.width;
    }

    public size_t sourceWidth() const @safe pure nothrow @nogc {
        return _pc.sourceWidth;
    }

    private auto decode(OperandKind kind)(in size_t operand)
        pure nothrow @nogc
    {
        static if (kind == OperandKind.immediate)
            return operand;
        else static if (kind == OperandKind.result)
            return operand == discardResult ? null : storage(operand);
        else
            return storage(operand);
    }

    public ubyte* storage(in size_t operand) pure nothrow @nogc {
        return operandStorage(_frame, operand);
    }
}

// A frame offset, or an address held in a frame slot plus an offset when the
// top bit is set.
pragma(inline, true)
package ubyte* operandStorage(ubyte* frame, in size_t operand)
        pure nothrow @nogc {
    if ((operand & (1UL << 63)) == 0)
        return frame + operand;
    const addressSlot = (operand >> 32) & 0x7fff_ffffUL;
    return *cast(ubyte**) (frame + addressSlot) + cast(uint) operand;
}

// An optimising build chains handlers: each one ends with a tail call to the
// next instruction's handler, so every handler has its own indirect jump and
// the branch predictor sees one history per handler instead of one per loop.
// Only a compiler that makes the tail call lets the stack stay flat. Other
// builds return to `dispatchLoop` after each instruction.
version (LDC) version (D_Optimized)
    private enum chainedDispatch = true;
private static if (!is(typeof(chainedDispatch)))
    private enum chainedDispatch = false;

// Under `-version=BytecodeCount` (the `bin/sb-count` build), every handler
// instantiation owns one counter slot. Its first execution registers the slot;
// the slots are printed to stderr at exit as `BCOUNT <count> <handler name>`.
// The counts are not atomic: a guest with several threads gives approximate
// counts.
version (BytecodeCount) {
    private struct CountSlot {
        ulong n;
        string name;
        shared bool registered;
    }

    private enum maxCountSlots = 4096;
    private __gshared CountSlot*[maxCountSlots] _countSlots;
    private shared size_t _countUsed;
    private shared bool _countExitHooked;

    private enum countName(string op, OperandKind d, OperandKind s, P...) =
        op ~ "/" ~ d.stringof ~ "/" ~ s.stringof ~ P.stringof;

    private extern(C) void dumpCounts() {
        import core.atomic: atomicLoad;
        import core.stdc.stdio: fprintf, stderr;
        const used = atomicLoad(_countUsed);
        foreach (slot; _countSlots[0 .. used < maxCountSlots ? used : maxCountSlots]) {
            if (slot is null)
                continue;
            fprintf(stderr, "BCOUNT %llu %.*s\n", slot.n,
                cast(int) slot.name.length, slot.name.ptr);
        }
    }

    // Exactly once for each slot, whatever the number of threads: the thread
    // that wins the compare-and-swap on `registered` appends the slot.
    private void registerCount(CountSlot* slot, string name) {
        import core.atomic: atomicOp, atomicStore, cas, MemoryOrder;
        import core.stdc.stdio: fprintf, stderr;
        import core.stdc.stdlib: atexit, abort;
        if (!cas(&slot.registered, false, true))
            return;
        if (cas(&_countExitHooked, false, true))
            atexit(&dumpCounts);
        const index = atomicOp!"+="(_countUsed, 1) - 1;
        if (index >= maxCountSlots) {
            fprintf(stderr, "bin/sb-count: more than %zu handler instantiations; raise maxCountSlots\n",
                maxCountSlots);
            abort;
        }
        slot.name = name;
        atomicStore!(MemoryOrder.rel)(*cast(shared) &_countSlots[index], cast(shared) slot);
    }

    // Counts one execution of a handler. The counts are not atomic; the
    // registration is.
    private void countExecution(CountSlot* slot, string name) {
        import core.atomic: atomicLoad, MemoryOrder;
        if (!atomicLoad!(MemoryOrder.raw)(slot.registered))
            registerCount(slot, name);
        slot.n++;
    }
}

private const(Instruction)* execute(
    alias operation,
    OperandKind destinationKind,
    OperandKind sourceKind,
    Parameters...,
)(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    version (BytecodeCount) {
        static __gshared CountSlot slot;
        countExecution(&slot, countName!(__traits(identifier, operation),
            destinationKind, sourceKind, Parameters));
    }
    // The position of a throw selects its handler.
    activation.pc = pc;
    // const would prevent operations from writing through storage pointers.
    auto execution = Execution!(destinationKind, sourceKind)(
        pc, activation, state,
    );
    const next = operation!Parameters(execution);
    static if (chainedDispatch) {
        if (next is null || next is activation.end)
            return next;
        return next.handler(next, activation, state);
    } else
        return next;
}

// As `execute`, for an operation that LDC does not inline. Such an operation
// receives the address of `execution`, a local of this function, so the frame
// stays live during the call and the call to the next handler cannot be a
// tail call. This one returns to `dispatchLoop` rather than grow the stack.
// `runAssert` throws, so LDC does not inline it, and it needs this.
private const(Instruction)* executeOnce(
    alias operation,
    OperandKind destinationKind,
    OperandKind sourceKind,
    Parameters...,
)(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    version (BytecodeCount) {
        static __gshared CountSlot slot;
        countExecution(&slot, countName!(__traits(identifier, operation),
            destinationKind, sourceKind, Parameters));
    }
    activation.pc = pc;
    auto execution = Execution!(destinationKind, sourceKind)(
        pc, activation, state,
    );
    return operation!Parameters(execution);
}

// As `execute`, for the instruction that can switch the activation. It
// returns to `dispatchLoop`, which owns that switch.
private const(Instruction)* executeCall(
    alias operation,
    OperandKind destinationKind,
    OperandKind sourceKind,
)(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    version (BytecodeCount) {
        static __gshared CountSlot slot;
        countExecution(&slot, countName!(__traits(identifier, operation),
            destinationKind, sourceKind));
    }
    activation.pc = pc;
    state.current = activation;
    auto execution = Execution!(destinationKind, sourceKind)(
        pc, activation, state,
    );
    return operation(execution);
}


public struct Instruction {
    // A handler stores `activation.pc = pc` before it can throw, because the
    // position of a throw selects the exception handler. In an optimised LDC
    // build it also ends with a tail call to the handler of the instruction it
    // returns, unless that is null or `activation.end`, so it must not keep a
    // local alive over that call. `dispatchLoop` runs what the chain returns.
    public alias Handler = const(Instruction)* function(
        const(Instruction)* pc,
        Activation* activation,
        DispatchState* state,
    );

    package Handler handler;
    // What a field means is decided by the opcode alone - never dmd's own
    // numeric types, so this VM has none of them to import. `0` means an
    // opcode does not use a given field. The roles a field plays, across
    // every opcode this VM has:
    //
    //  - a storage operand, for `opCopy`/`opReturn` and for every arithmetic,
    //    comparison, unary and cast opcode below, whose `destination` is
    //    also where their one or two operands already sit: a binary
    //    opcode reads its left operand from `destination` and its right
    //    one from `source`, then overwrites `destination` with the
    //    answer, in `width` bytes for one that produces a value of the
    //    operands' own type, or in the compiler's own choosing of a
    //    single byte for one that produces a `bool` (a comparison, `!`,
    //    `cast(bool)`) - the compiler copies that byte out to wherever it
    //    is actually needed, the same way it already copies an
    //    `opCopy`/`opCall` result out of a slot it does not itself own.
    //  - a constant index, for `opConstant`'s `source`.
    //  - a call-site index, for `opCall`'s `source`.
    //  - a source width, for `opCastWidenSigned`/`opCastWidenUnsigned`'s
    //    `source`: the one thing a widening cast needs besides its own
    //    `destination`/`width` (the destination width) that neither
    //    already carries.
    //  - a resolved static-storage address, cast to a `size_t`: the
    //    `source` of `opStaticLoad`/`opStaticAddress` and the
    //    `destination` of `opStaticStore`.
    //  - a source offset's width, for floating-point conversions whose
    //    destination and source widths can differ.
    //  - a resolved instruction address, cast to a `size_t`: `opJump`'s
    //    `destination`, and `opBranchFalse`/`opBranchTrue`'s `source`.
    //    The compiler patches every branch with a plain instruction
    //    index while it is still emitting code - the same currency
    //    `resolveBranches` validates every one of before this VM ever
    //    sees it - then rewrites each index to the address it names, once
    //    the function's instructions have stopped growing and so can no
    //    longer move.
    package size_t destination;
    package size_t source;
    package size_t width;
    package size_t sourceWidth;
}


// One run-time check site, resolved to plain values at compile time so this
// VM never has to reach into dmd's own `Loc`. Assertions use all fields;
// range checks only need the source location.
package struct AssertSite {
    package string message;
    package string file;
    package size_t line;
    // Not null for a check that halts rather than throws.
    package HaltAction halt;
}


// One guest catch clause. The compiler resolves the three instruction
// pointers after code generation; the VM only needs native runtime metadata
// to decide whether a Throwable belongs to the clause and where to resume.
package struct ExceptionHandler {
    package TypeInfo_Class type;
    package const(Instruction)* bodyStart;
    package const(Instruction)* bodyEnd;
    package const(Instruction)* handler;
    package size_t catchOffset;
    package const(Instruction)* cleanupEnd;
}


// What a caller needs to copy a small leaf function into its own
// instruction stream: the instructions before the compiler fuses them and
// resolves their branches, so a branch target is still an index.
package struct InlineBody {
    package Instruction[] instructions;
    package long[] constants;
    package size_t frameSize;
    package uint frameAlignment;
}


public struct Function {
    package Instruction[] instructions;
    package long[] constants;
    package CallSite[] callSites;
    package AssertSite[] assertSites;
    package ExceptionHandler[] exceptionHandlers;
    package size_t frameSize;
    package uint frameAlignment;
    // `size_t.max` means this function's locals stay in its activation
    // frame. Otherwise this private frame slot holds its closure pointer.
    package size_t closureOffset = size_t.max;
    // The hidden context slot is copied into the first word of the closure.
    package size_t contextOffset = size_t.max;
    package size_t closureSize;
    package uint closureAlignment = 1;
    package ClosureSlot[] closureSlots;
    package size_t[] parameterOffsets;
    // Where a C-variadic function reads its cursor, and how many parameters
    // it declares before it; `size_t.max` for any other function.
    package size_t cursorOffset = size_t.max;
    package size_t declaredParameters;
    package const(Signature)* signature;
    package imported!"snakebite.backends.returnplace".ReturnPlace returnPlace;
    // Not null when a caller can copy this function in place of a call.
    package const(InlineBody)* inlineBody;
}


import snakebite.framestack: FrameStack;

public struct Vm {
    private FrameStack _frames;

    @disable this();
    @disable this(this);

    import snakebite.tlsstorage: TlsSlots;

    public this(in size_t frameCapacity, TlsSlots* tls = null) {
        _frames = FrameStack(frameCapacity, tls);
    }

    // One argument the host hands a guest function: the callee frame
    // slot it fills, and the bytes that fill it.
    public struct HostArgument {
        public size_t offset;
        public const(void)* source;
        public size_t width;
    }

    public void call(
        scope const ref Function function_,
        void* returnPlace,
    ) {
        call(function_, returnPlace, null);
    }

    // As `call`, with the callee's parameter slots filled from `arguments`
    // first - the way `callFunction` fills them from a caller's frame for
    // a guest call site.
    public void call(
        scope const ref Function function_,
        void* returnPlace,
        scope const HostArgument[] arguments,
    ) {
        import core.stdc.string: memcpy;

        assert(function_.instructions.length > 0);
        assert(function_.frameAlignment > 0);

        auto frame = _frames.push(
            function_.frameSize,
            function_.frameAlignment,
        );
        if (function_.contextOffset != size_t.max)
            *cast(size_t*) (frame.base + function_.contextOffset) = 0;
        foreach (argument; arguments)
            memcpy(frame.base + argument.offset, argument.source,
                argument.width);
        returnPlace = function_.returnPlace.bind(
            &_frames, frame.base, returnPlace);
        initializeClosure(&function_, frame.base, &_frames);
        auto pc = function_.instructions.ptr;
        dispatch(
            pc, frame.base, returnPlace, function_.constants,
            function_.callSites, function_.assertSites,
            function_.exceptionHandlers, &_frames,
            &this,
        );
    }
}


private void initializeClosure(
    const(Function)* function_,
    ubyte* frame,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy, memset;

    if (function_.closureOffset == size_t.max)
        return;

    auto closure = frames.allocate(
        function_.closureSize, function_.closureAlignment);
    memset(closure, 0, function_.closureSize);

    if (function_.contextOffset != size_t.max)
        memcpy(
            closure,
            frame + function_.contextOffset,
            size_t.sizeof,
        );
    foreach (slot; function_.closureSlots)
        memcpy(
            closure + slot.closureOffset,
            frame + slot.sourceOffset,
            slot.width,
        );

    *cast(void**)(frame + function_.closureOffset) = closure;
}


// Guest calls reserve activations beside their values. Native stack use
// therefore depends on barrier crossings, not guest call depth.
private struct Activation {
    const(Instruction)* pc;
    const(Instruction)* start;
    const(Instruction)* end;
    const(Instruction)* resume;
    ubyte* frame;
    void* returnPlace;
    const(long)[] constants;
    const(CallSite)[] callSites;
    const(AssertSite)[] assertSites;
    const(ExceptionHandler)[] exceptionHandlers;
    size_t cleanupMark;
    FrameStack.Mark frameMark;
    Activation* parent;

    void cleanup(FrameStack* frames) {
        // Most activations leave no temporary to destroy.
        if (frames.cleanupMark > cleanupMark)
            cleanupSince(cleanupMark, &this, frames);
    }

    // Forgets the temporaries that `cleanup` would destroy.
    void discardCleanups(FrameStack* frames) {
        frames.finishCleanups(cleanupMark, (in size_t) {});
    }
}

private struct DispatchState {
    FrameStack* frames;
    Activation* current;
    Activation* pending;
    // The first handler of `current` that an exception that is no
    // `Throwable` must still unwind, while a `finally` body of `current`
    // runs. Zero at all other times.
    size_t nextHandler;
    Vm* vm;
    DispatchState* parent;
}

// Thrown after guest code has resumed from a handler that took an exception
// that cleanup threw while an exception that is no `Throwable` unwound. It
// replaces the foreign exception, as the exception that cleanup threw does
// in compiled D, and `dispatch` stops it.
private class ForeignUnwindEnd : Throwable {
    this() @safe pure nothrow @nogc {
        super("foreign exception replaced");
    }
}

private void dispatch(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    scope const ExceptionHandler[] exceptionHandlers,
    FrameStack* frames,
    Vm* vm,
    const(Instruction)* end = null,
) {
    // Fill each field once. Default initialization otherwise clears the
    // arrays before these assignments on every callback entry.
    Activation root = void;
    root.pc = root.start = pc;
    root.end = end;
    root.resume = null;
    root.frame = frame;
    root.returnPlace = returnPlace;
    root.constants = constants;
    root.callSites = callSites;
    root.assertSites = assertSites;
    root.exceptionHandlers = exceptionHandlers;
    root.cleanupMark = frames.cleanupMark;
    root.frameMark = FrameStack.Mark.init;
    root.parent = null;
    auto state = DispatchState(frames, null, null, 0, vm,
        cast(DispatchState*) frames.backendEntry);
    // A halt must also discard a partially reserved activation.
    const frameMark = frames.mark;
    scope(exit) frames.backendEntry = state.parent;
    frames.backendEntry = &state;
    bool returned;
    bool thrown;
    scope(exit) if (!returned) {
        frames.finishCleanups(root.cleanupMark, (in size_t) {});
        frames.release(frameMark);
    }
    try {
        // Only `finally` and `scope(exit)` run for an exception that is no
        // `Throwable`, such as one a C++ callee throws, and `dispatchLoop`
        // has not seen it. A `Throwable` has already run the cleanups of
        // every activation by the time it leaves `dispatchLoop`.
        scope(exit) if (!returned && !thrown && state.current !is null) {
            auto resumed = handleException(
                state.current, frames, null, vm, state.nextHandler);
            if (resumed !is null) {
                dispatchLoop(resumed.pc, resumed, &state);
                throw new ForeignUnwindEnd;
            }
        }
        scope(failure) thrown = true;
        dispatchLoop(root.pc, &root, &state);
        returned = true;
    } catch (ForeignUnwindEnd) {
        returned = true;
    }
}

pragma(inline, true)
private void dispatchLoop(
    const(Instruction)* pc,
    Activation* active,
    DispatchState* state,
) {
    // Cleanup writes the frame stack.
    auto frames = state.frames;

    while (true) {
        try {
            if (pc is null || pc is active.end) {
                active.pc = pc;
                active.cleanup(frames);
                if (active.parent is null)
                    return;
                active = popActivation(active, frames);
                pc = active.resume;
                continue;
            }

            pc = pc.handler(pc, active, state);
            if (state.pending !is null) {
                active = state.pending;
                state.pending = null;
                pc = active.pc;
            }
        } catch (Throwable throwable) {
            active = handleException(active, frames, throwable, state.vm);
            pc = active.pc;
        }
    }
}

// Cleanup delegates must not capture the normal dispatch loop's state:
// an escaped activation pointer forces a reload after every instruction.
// A `null` throwable is an exception that is no `Throwable`: no handler
// takes it, so it unwinds every activation, and the result is `null`.
private Activation* handleException(
    Activation* active,
    FrameStack* frames,
    Throwable throwable,
    Vm* vm,
    size_t firstHandler = 0,
) {
    while (true) {
        // A halt that ends a cell is not an error guest code handles: no
        // temporary's destructor, `catch` or `finally` sees it.
        const halting = isHalt(throwable);
        try {
            unwindFinally(throwable, () {
                if (halting)
                    active.discardCleanups(frames);
                else
                    active.cleanup(frames);
            });
        } catch (Throwable chained) {
            throwable = chained;
        }
        ExceptionCandidate[handlerBufferLength] handlerBuffer;
        const plan = isHalt(throwable)
            ? UnwindPlan.init
            : exceptionPlanOf(
                active.exceptionHandlers[firstHandler .. $], active.pc,
                throwable is null ? null : throwable.classinfo, handlerBuffer);
        const step = plan.finalizers.length != 0
            ? plan.finalizers[0]
            : plan.handler;
        const handler = plan.finalizers.length != 0 || plan.hasHandler
            ? cast(const(ExceptionHandler)*) step.payload : null;
        if (handler is null || (active.end !is null
                && (handler.handler < active.start
                    || handler.handler >= active.end))) {
            if (active.parent is null) {
                if (throwable is null)
                    return null;
                throw throwable;
            }
            active = popActivation(active, frames);
            firstHandler = 0;
            continue;
        }

        if (handler.cleanupEnd !is null) {
            auto state = cast(DispatchState*) frames.backendEntry;
            state.nextHandler = handler - active.exceptionHandlers.ptr + 1;
            try {
                unwindFinally(throwable, () {
                    state.current = active;
                    dispatch(handler.handler, active.frame,
                        active.returnPlace, active.constants,
                        active.callSites, active.assertSites,
                        active.exceptionHandlers, frames, vm,
                        handler.cleanupEnd);
                });
            } catch (Throwable chained) {
                throwable = chained;
            }
            state.nextHandler = 0;
            firstHandler = handler - active.exceptionHandlers.ptr + 1;
            continue;
        }

        if (handler.catchOffset != size_t.max)
            *cast(void**)(active.frame + handler.catchOffset) =
                cast(void*) throwable;
        active.pc = handler.handler;
        return active;
    }
}

private Activation* popActivation(Activation* active, FrameStack* frames) {
    const mark = active.frameMark;
    auto parent = active.parent;
    frames.release(mark);
    return parent;
}


private void unwindFinally(Throwable throwable, scope void delegate() cleanup) {
    import snakebite.backends.unwindplan: sharedUnwindFinally = unwindFinally;

    sharedUnwindFinally(throwable, cleanup);
}


private void cleanupSince(
    in size_t mark,
    Activation* active,
    FrameStack* frames,
) {
    frames.finishCleanups(mark, (in size_t siteIndex) {
        auto site = &active.callSites[siteIndex];
        assert(site.cleanupStart !is null, "temporary cleanup start missing");
        assert(site.cleanupEnd !is null, "temporary cleanup end missing");
        auto state = cast(DispatchState*) frames.backendEntry;
        state.current = active;
        dispatch(cast(const(Instruction)*) site.cleanupStart,
            active.frame, null, active.constants, active.callSites,
            active.assertSites, null, frames, state.vm,
            cast(const(Instruction)*) site.cleanupEnd);
    });
}


public alias opTemporaryBegin =
    execute!(runTemporaryBegin, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runTemporaryBegin(Decoded)(
    ref Decoded execution,
) {
    storeIntegral(execution.destination, execution.frames.cleanupMark,
        size_t.sizeof);
    return execution.next;
}


public alias opTemporaryRegister =
    execute!(runTemporaryRegister, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runTemporaryRegister(Decoded)(
    ref Decoded execution,
) {
    execution.frames.registerCleanup(execution.source, execution.destination);
    return execution.next;
}


public alias opTemporarySuspend =
    execute!(runTemporarySuspend, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runTemporarySuspend(Decoded)(
    ref Decoded execution,
) {
    execution.frames.suspendCleanup(*cast(ubyte**) execution.source,
        execution._cleanupMark);
    return execution.next;
}


public alias opTemporaryArm =
    execute!(runTemporaryArm, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runTemporaryArm(Decoded)(
    ref Decoded execution,
) {
    execution.frames.armCleanup(*cast(ubyte**) execution.source,
        execution._cleanupMark);
    return execution.next;
}


public alias opTemporaryArmAddress =
    execute!(runTemporaryArmAddress, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runTemporaryArmAddress(Decoded)(
    ref Decoded execution,
) {
    execution.frames.armCleanup(execution.source,
        execution._cleanupMark);
    return execution.next;
}


public const(Instruction)* opTemporaryEnd(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    version (BytecodeCount) {
        static __gshared CountSlot slot;
        countExecution(&slot, "opTemporaryEnd");
    }
    auto execution = Execution!(OperandKind.storage, OperandKind.immediate)(
        pc, activation, state);
    const mark = loadUnsigned(execution.destination, size_t.sizeof);
    activation.pc = pc;
    cleanupSince(mark, activation, execution.frames);
    return execution.next;
}


// The candidates of a throw fit `buffer` unless more than
// `handlerBufferLength` handlers protect `pc`: a throw in a destructor that
// the GC finalizer runs cannot allocate, and nesting that deep is rare.
private enum handlerBufferLength = 16;

private UnwindPlan exceptionPlanOf(
    const(ExceptionHandler)[] handlers,
    const(Instruction)* pc,
    TypeInfo_Class actual,
    return scope ref ExceptionCandidate[handlerBufferLength] buffer,
) {
    size_t count;
    ExceptionCandidate[] overflow;

    foreach (ref handler; handlers) {
        if (pc < handler.bodyStart || pc >= handler.bodyEnd)
            continue;
        auto candidate = ExceptionCandidate(
            null,
            handler.cleanupEnd is null
                ? ExceptionCandidate.Kind.catch_
                : ExceptionCandidate.Kind.finally_,
            cast(TypeInfo_Class) handler.type,
            cast(const(void)*) &handler,
        );
        if (overflow !is null)
            overflow ~= candidate;
        else if (count < buffer.length)
            buffer[count++] = candidate;
        else {
            overflow = buffer[0 .. count].dup;
            overflow ~= candidate;
        }
    }

    return unwindPlanOf(overflow !is null ? overflow : buffer[0 .. count],
        actual);
}


// Writes a constant into the decoded destination storage.
public alias opConstant =
    execute!(runConstant, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runConstant(Decoded)(
    ref Decoded execution,
) {
    storeWidth(execution.destination, execution.constants[execution.source],
        execution.width);
    return execution.next;
}


// Copies `execution.width` bytes from `execution.source` to
// `execution.destination`: a parameter or local read into another slot, or
// an
// assignment's right side already evaluated into the target's own slot
// copied out to wherever the assignment's value is also needed.
package alias opCopy =
    execute!(runCopy, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runCopy(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    memcpy(execution.destination, execution.source, execution.width);
    return execution.next;
}


// Constant lengths let the native compiler inline copies without requiring
// aligned frame slots or typed pointer access.
package alias opCopyFixed(size_t width, bool staticSource = false) =
    execute!(runCopyFixed, OperandKind.storage,
        staticSource ? OperandKind.immediate : OperandKind.storage,
        width, staticSource);

private const(Instruction)* runCopyFixed(size_t width, bool staticSource = false, Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    static if (staticSource)
        const source = cast(const(void)*) execution.source;
    else
        const source = execution.source;
    memcpy(execution.destination, source, width);
    return execution.next;
}


// Persistent storage can belong to a constant or a data-segment variable.
package alias opStaticLoad =
    execute!(runStaticLoad, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runStaticLoad(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    memcpy(execution.destination, cast(const(void)*) execution.source, execution.width);
    return execution.next;
}


package alias opStaticStore =
    execute!(runStaticStore, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runStaticStore(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    memcpy(cast(void*) execution.destination, execution.source, execution.width);
    return execution.next;
}


// Writes the address of a function-local static into the current frame.
// The address remains stable for the lifetime of the compiled function and
// is used by native druntime calls such as array append.
package alias opStaticAddress =
    execute!(runStaticAddress, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runStaticAddress(Decoded)(
    ref Decoded execution,
) {
    *cast(void**) (execution.destination) = cast(void*) execution.source;
    return execution.next;
}


// A thread-local guest variable's own storage differs by thread, so its
// address is never a compile-time constant (finding 1.3, ADR-0006) the
// way a `shared`/`__gshared` variable's is: `opStatic*`'s `source`/
// `destination` immediate holds a resolved address directly, but
// `opTls*`'s holds a `snakebite.tlsstorage.TlsDescriptor*` instead,
// resolved through `frames.tlsSlotFor` - this thread's own storage, on
// this thread's own frame stack - on every access, never cached in the
// instruction itself.
package alias opTlsLoad =
    execute!(runTlsLoad, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runTlsLoad(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;
    import snakebite.tlsstorage: TlsDescriptor;

    auto slot = execution.frames.tlsSlotFor(
        cast(const(TlsDescriptor)*) execution.source);
    memcpy(execution.destination, slot.ptr, execution.width);
    return execution.next;
}


package alias opTlsStore =
    execute!(runTlsStore, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runTlsStore(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;
    import snakebite.tlsstorage: TlsDescriptor;

    auto slot = execution.frames.tlsSlotFor(
        cast(const(TlsDescriptor)*) execution.destination);
    memcpy(slot.ptr, execution.source, execution.width);
    return execution.next;
}


package alias opTlsAddress =
    execute!(runTlsAddress, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runTlsAddress(Decoded)(
    ref Decoded execution,
) {
    import snakebite.tlsstorage: TlsDescriptor;

    auto slot = execution.frames.tlsSlotFor(
        cast(const(TlsDescriptor)*) execution.source);
    *cast(void**) (execution.destination) = slot.ptr;
    return execution.next;
}


// `assert(cond)`: when the `execution.width` bytes at
// `execution.destination` are
// nonzero, execution just continues. Otherwise this throws a real
// `AssertError` - the same `Throwable` compiled D throws for a failing
// assertion - built from `assertSites[execution.source]`, so a guest catch
// or an
// unhandled failure both see the genuine object, never a second exception
// type standing in for it. Each `opCall` this throw unwinds through pops
// its own callee `Frame` via that struct's destructor (see
// `snakebite.framestack`), so no explicit cleanup is needed here.
package alias opAssert =
    executeOnce!(runAssert, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runAssert(Decoded)(
    ref Decoded execution,
) {
    if (loadUnsigned(execution.destination, execution.width) != 0)
        return execution.next;

    import core.exception: AssertError;

    const site = execution.assertSites[execution.source];
    if (site.halt !is null)
        site.halt();
    throw new AssertError(site.message, site.file, site.line);
}


// Throws the Throwable reference at `execution.destination`. The expression has
// already been evaluated into the frame, so this preserves the original
// object while dispatch unwinds through guest catch handlers and frames.
package const(Instruction)* opThrow(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    version (BytecodeCount) {
        static __gshared CountSlot slot;
        countExecution(&slot, "opThrow");
    }
    activation.pc = pc;
    auto execution = Execution!(OperandKind.storage, OperandKind.immediate)(
        pc, activation, state);
    auto throwable = cast(Throwable) *cast(void**) (execution.destination);
    throw throwable;
}


// Calls `callSites[execution.source]`'s callee, one of the four
// `CallSite.Kind`s:
// a guest callee already compiled to `Instruction`s, a native one reached
// through a prepared FFI plan, an indirect one whose own address sits in
// the caller's frame, or a builtin one reached through its own resolved
// entry directly. `execution.width` is unused.
private alias opCallGeneral =
    executeCall!(runCall, OperandKind.result, OperandKind.immediate);

// A call of a compiled guest function whose activation needs no closure,
// no discarded memory-class result slot and no context conversion: the
// activation is built here without the generic `Execution` decoding, from
// the facts `CallSite.prepare` keeps. Any other call takes `opCallGeneral`,
// which has the same effect.
public const(Instruction)* opCall(
    const(Instruction)* pc,
    Activation* active,
    DispatchState* state,
) {
    version (BytecodeCount) {
        static __gshared CountSlot slot;
        countExecution(&slot, "opCall");
    }
    import core.stdc.string: memcpy;

    import core.atomic: atomicLoad, MemoryOrder;

    // The position of a throw selects its handler, and the new activation
    // resumes this one.
    active.pc = pc;
    state.current = active;
    const site = &active.callSites[pc.source];
    const ready = atomicLoad!(MemoryOrder.acq)(
        *cast(shared(uint)*) &site.fast.state) == CallSite.FastCall.State.ready;
    if (!ready && !site.prepareFast)
        return opCallGeneral(pc, active, state);
    const fast = &site.fast;
    const callee = fast.callee;
    const hasPlace = fast.returnWidth != 0 && pc.destination != discardResult;
    if (!hasPlace && fast.returnPlaceOffset != size_t.max)
        return opCallGeneral(pc, active, state);

    ubyte* storage(in size_t operand) {
        return operandStorage(active.frame, operand);
    }

    auto frames = state.frames;
    const mark = frames.mark;
    auto activation = cast(Activation*) frames.reserveCommitted(
        fast.frameBytes, fast.alignment);
    activation.frameMark = mark;
    ubyte* frame = cast(ubyte*) activation + fast.frameOffset;
    activation.frame = frame;

    foreach (arg; fast.args[0 .. fast.argCount]) {
        auto destination = frame + arg.calleeOffset;
        const source = storage(arg.callerOffset);
        // Constant widths let the compiler copy without a call.
        switch (arg.width) {
        case 1: memcpy(destination, source, 1); break;
        case 2: memcpy(destination, source, 2); break;
        case 4: memcpy(destination, source, 4); break;
        case 8: memcpy(destination, source, 8); break;
        case 16: memcpy(destination, source, 16); break;
        default: memcpy(destination, source, arg.width); break;
        }
    }

    activation.pc = activation.start = callee.instructions.ptr;
    activation.end = null;
    activation.resume = null;
    void* place = null;
    if (hasPlace)
        place = storage(pc.destination);
    if (fast.returnPlaceOffset != size_t.max)
        *cast(void**) (frame + fast.returnPlaceOffset) = place;
    activation.returnPlace = place;
    activation.constants = callee.constants;
    activation.callSites = callee.callSites;
    activation.assertSites = callee.assertSites;
    activation.exceptionHandlers = callee.exceptionHandlers;
    activation.cleanupMark = frames.cleanupMark;
    activation.parent = state.current;
    activation.parent.resume = pc + 1;
    state.pending = activation;
    return pc + 1;
}

private const(Instruction)* runCall(Decoded)(
    ref Decoded execution,
) {
    const site = &execution.callSites[execution.source];
    final switch (site.kind) with (CallSite.Kind) {
    case guest:
        return callFunction(execution, *site,
            site.callee !is null ? site.callee : site.prepareGuest());
    case indirect:
        return runIndirect!false(execution, site);
    case value:
        return runIndirect!true(execution, site);
    case native:
        auto arguments = gatherArguments(execution, site.args);
        auto values = arguments.values;
        auto result = execution.destination;
        executeCallPlan(
            site.nativePlan !is null ? site.nativePlan : site.prepareNativePlan(),
            result, values.ptr, values.length,
        );
        return execution.next;
    case builtin:
        auto arguments = gatherArguments(execution, site.args);
        auto values = arguments.values;
        site.builtinEntry(execution.destination, values.ptr, values.length);
        return execution.next;
    }
}


pragma(inline, true)
private const(Instruction)* runIndirect(bool isValue, Decoded)(
    ref Decoded execution, const(CallSite)* site,
) {
    auto callee =
        *cast(const(void)**) (execution.storage(site.calleeSlotOffset));
    ptrdiff_t contextAdjustment;
    if (site.nativePlan !is null) {
        auto arguments = gatherArguments(execution, site.nativeArgs);
        auto values = arguments.values;
        if (executeIndirectCallPlan(site.nativePlan, callee,
                execution.destination, values.ptr, values.length,
                contextAdjustment))
            return execution.next;
    }
    auto function_ = cast(const(Function)*) callee;
    static if (isValue)
        if (site.value.signature !is function_.signature)
            return callFunction!true(
                execution, *site, function_, contextAdjustment);
    return callFunction(execution, *site, function_, contextAdjustment);
}


// A call through a value whose type has another signature than the callee.
// The context goes to the context of the callee, and each parameter takes the
// argument that is in its register. A C-variadic callee gets a cursor over
// the arguments that no named parameter reads.
pragma(inline, false)
private void redirectArguments(Decoded)(
    ref Decoded execution, scope const ref CallSite site,
    const(Function)* callee, ubyte* frame,
) {
    import core.stdc.string: memcpy, memset;
    import snakebite.backends.variadic: VariadicLayout;
    import std.algorithm: min;

    const value = &site.value;
    const parameters = callee.signature.parameters;
    const declared = value.signature.parameters.length;
    const first = site.hasContext ? 1 : 0;
    const calleeHasContext = callee.contextOffset != size_t.max;
    const flow = ArgumentFlow(
        value.signature.parameters, value.surplusShapes, parameters,
        site.hasContext && calleeHasContext);
    const(ubyte)* addressOf(in size_t argument) {
        return execution.storage(argument < declared
            ? site.args[first + argument].callerOffset
            : value.surplus[argument - declared].callerOffset);
    }

    if (calleeHasContext) {
        // A function pointer has no context: its callee gets a null one.
        auto context = frame + callee.contextOffset;
        if (site.hasContext)
            memcpy(context, execution.storage(site.args[0].callerOffset),
                size_t.sizeof);
        else
            memset(context, 0, size_t.sizeof);
    }
    foreach (i, shape; parameters) {
        auto place = frame + callee.parameterOffsets[i];
        memset(place, 0, shape.size);
        const source = flow.sourceOf(i);
        if (source != size_t.max)
            memcpy(place, addressOf(source),
                min(shape.size, flow.argumentAt(source).size));
    }

    if (callee.cursorOffset != size_t.max) {
        const unread = flow.unread;
        TypeFacts[] facts;
        foreach (argument; unread)
            facts ~= flow.argumentAt(argument).facts;
        const plan = VariadicLayout.of(facts);
        auto storage = execution.frames.reserve(plan.size, plan.alignment);
        plan.initialize(storage);
        foreach (i, offset; plan.offsets)
            memcpy(storage + offset, addressOf(unread[i]), facts[i].size);
        *cast(ubyte**) (frame + callee.cursorOffset) = storage;
        return;
    }

    // `types` and `cursor` are the last two arguments of the site and the two
    // parameters of the callee after the declared ones.
    if (callee.signature.variadic == Signature.Variadic.d
            && value.signature.variadic == Signature.Variadic.d)
        foreach (i; 0 .. 2) {
            const argument = site.args[$ - 2 + i];
            memcpy(frame + callee.parameterOffsets[parameters.length + i],
                execution.storage(argument.callerOffset), argument.width);
        }
}


// Copies each argument's address out of the caller's frame, in the order
// `args` names, for a call reached through a plan or a resolved entry
// (`indirect`, `native`, `builtin` in `runCall`'s switch) rather than a
// callee frame `callFunction` copies into directly.
private CallArguments gatherArguments(Decoded)(
    ref Decoded execution, in Arg[] args,
) {
    auto arguments = CallArguments(args.length);
    // const would make the address slots read-only.
    auto values = arguments.values;
    foreach (i, arg; args)
        values[i] = execution.storage(arg.callerOffset);
    return arguments;
}


// The dispatcher starts the callee after this opcode returns. The saved
// caller pc remains the call site until the callee returns, so exceptions
// can find the caller's handler while unwinding guest activations.
private const(Instruction)* callFunction(bool redirected = false, Decoded)(
    ref Decoded execution,
    scope const ref CallSite site,
    const(Function)* callee,
    in ptrdiff_t contextAdjustment = 0,
) {
    import core.stdc.string: memcpy;
    import std.algorithm: max;

    const mark = execution.frames.mark;
    scope(failure) execution.frames.release(mark);
    assert(callee.frameAlignment > 0
        && (callee.frameAlignment & (callee.frameAlignment - 1)) == 0);
    const alignment = max(callee.frameAlignment, uint(Activation.alignof));
    const mask = size_t(alignment) - 1;
    const frameOffset = (Activation.sizeof + mask) & ~mask;
    auto activation = cast(Activation*) execution.frames.reserve(
        frameOffset + callee.frameSize, alignment);
    activation.frameMark = mark;
    activation.frame = cast(ubyte*) activation + frameOffset;

    // An inferred function literal can convert to a delegate without
    // gaining a context parameter. Use its declared parameter layout;
    // removing a context word can also change argument alignment.
    static if (redirected)
        redirectArguments(execution, site, callee, activation.frame);
    else if (site.hasContext && callee.contextOffset == size_t.max) {
        foreach (i, arg; site.args[1 .. $]) {
            if (i >= callee.parameterOffsets.length)
                internalFailure("a callee with the signature of the value has a "
                    ~ "parameter for each argument");
            memcpy(activation.frame + callee.parameterOffsets[i],
                execution.storage(arg.callerOffset), arg.width);
        }
    } else {
        foreach (arg; site.args)
            memcpy(activation.frame + arg.calleeOffset,
                execution.storage(arg.callerOffset), arg.width);
    }

    if (contextAdjustment != 0) {
        static if (redirected)
            const contextOffset = callee.contextOffset;
        else
            const contextOffset = site.args[0].calleeOffset;
        if (contextOffset != size_t.max)
            *cast(ubyte**) (activation.frame + contextOffset) +=
                contextAdjustment;
    }
    initializeClosure(callee, activation.frame, execution.frames);

    activation.pc = activation.start = callee.instructions.ptr;
    activation.end = null;
    activation.resume = null;
    activation.returnPlace = callee.returnPlace.bind(
        execution.frames, activation.frame,
        site.returnWidth == 0 ? null : execution.destination);
    activation.constants = callee.constants;
    activation.callSites = callee.callSites;
    activation.assertSites = callee.assertSites;
    activation.exceptionHandlers = callee.exceptionHandlers;
    activation.cleanupMark = execution.frames.cleanupMark;
    activation.parent = execution._dispatch.current;
    activation.parent.resume = execution.next;
    execution._dispatch.pending = activation;
    return execution.next;
}


// Copies `execution.width` bytes from `execution.source` to `returnPlace` -
// `null` when the caller discarded the result, the same convention every
// backend uses for a call whose value nothing reads. `execution.destination` is
// unused: there is no frame slot on the receiving end, only `returnPlace`.
public alias opReturn =
    execute!(runReturn, OperandKind.immediate, OperandKind.storage);

package const(Instruction)* opThenReturn(alias operation)(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    static if (chainedDispatch)
        // The chain reaches the separate return by itself.
        return operation(pc, activation, state);
    else {
        const next = operation(pc, activation, state);
        // Cleanup can execute only the producer, with the return outside its
        // instruction range.
        return next is activation.end
            ? next : opReturn(next, activation, state);
    }
}

private const(Instruction)* runReturn(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    if (execution.returnPlace !is null
            && execution.returnPlace != execution.source)
        memcpy(execution.returnPlace, execution.source, execution.width);
    return null;
}


public alias opReturnVoid =
    execute!(runReturnVoid, OperandKind.immediate, OperandKind.immediate);

private const(Instruction)* runReturnVoid(Decoded)(
    ref Decoded execution,
) {
    return null;
}


// Unconditionally transfers control to the instruction `execution.destination`
// already names, resolved (see `Instruction.destination`'s own doc) to
// that instruction's address by the compiler before this VM ever runs it.
package alias opJump =
    execute!(runJump, OperandKind.immediate, OperandKind.immediate);

private const(Instruction)* runJump(Decoded)(
    ref Decoded execution,
) {
    const target = cast(const(Instruction)*) execution.destination;
    return target;
}


// Transfers control to `execution.source` (resolved the same way `opJump`'s own
// target is) when the `execution.width` bytes at `execution.destination` are
// all
// zero - an `if` whose condition was false, a loop whose condition no
// longer holds, the left side of a short-circuiting `&&` - and falls
// through to the next instruction otherwise.
package alias opBranchFalse =
    execute!(runBranchFalse, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runBranchFalse(Decoded)(
    ref Decoded execution,
) {
    if (loadUnsigned(execution.destination, execution.width) == 0) {
        const target = cast(const(Instruction)*) execution.source;
        return target;
    }

    return execution.next;
}


// As `opBranchFalse`, taking the branch when the tested bytes are instead
// nonzero - the left side of a short-circuiting `||`.
package alias opBranchTrue =
    execute!(runBranchTrue, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runBranchTrue(Decoded)(
    ref Decoded execution,
) {
    if (loadUnsigned(execution.destination, execution.width) != 0) {
        const target = cast(const(Instruction)*) execution.source;
        return target;
    }

    return execution.next;
}


// The arithmetic and bitwise opcodes whose bits do not depend on either
// operand's signedness: dmd's usual arithmetic conversions already bring
// both operands to `destination`'s own type before the compiler emits
// one of these, so the low bits `+`, `-`, `*`, `&`, `|`, `^` and `<<`
// leave are the same whichever way the wider intermediate was extended.
// `destination` holds the left operand on entry and the answer on exit;
// `source` holds the right operand, read but not written.
public alias opAdd =
    execute!(runAdd, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runAdd(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a + b), execution.width);
    return execution.next;
}

package alias opSubtract =
    execute!(runSubtract, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runSubtract(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a - b), execution.width);
    return execution.next;
}

package alias opMultiply =
    execute!(runMultiply, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runMultiply(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a * b), execution.width);
    return execution.next;
}

private T applyFloatBinary(string operation, T)(T left, T right)
        @nogc nothrow pure {
    return mixin("left " ~ operation ~ " right");
}

private alias opFloatBinary(string operation) =
    execute!(runFloatBinary, OperandKind.storage, OperandKind.storage, operation);

private const(Instruction)* runFloatBinary(string operation, Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    if (execution.width == float.sizeof)
        *cast(float*) place = applyFloatBinary!operation(
            *cast(float*) place,
            *cast(const float*) (execution.source),
        );
    else if (execution.width == double.sizeof)
        *cast(double*) place = applyFloatBinary!operation(
            *cast(double*) place,
            *cast(const double*) (execution.source),
        );
    else {
        assert(execution.width == real.sizeof);
        *cast(real*) place = applyFloatBinary!operation(
            *cast(real*) place,
            *cast(const real*) (execution.source),
        );
    }
    return execution.next;
}

// A complex operation: `destination` holds the left operand on entry and
// the answer on exit, `source` the right operand, `width` the part width,
// and `sourceWidth` what each operand holds, as `ComplexOperands.packed`.
package alias opComplex(ComplexOperation operation) =
    executeOnce!(runComplex, OperandKind.storage, OperandKind.storage, operation);

private const(Instruction)* runComplex(ComplexOperation operation, Decoded)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: applyComplex, ComplexOperands;

    applyComplex!operation(execution.destination, execution.destination,
        execution.source, ComplexOperands.unpack(execution.sourceWidth),
        execution.width);
    return execution.next;
}

// `-x` for a complex `x` in `destination`, whose part width is `width`.
package alias opComplexNegate =
    execute!(runComplexNegate, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runComplexNegate(Decoded)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: negateComplex;

    negateComplex(execution.destination, execution.destination,
        execution.width);
    return execution.next;
}

package alias opFloatAdd = opFloatBinary!"+";
package alias opFloatSubtract = opFloatBinary!"-";
package alias opFloatMultiply = opFloatBinary!"*";
package alias opFloatDivide = opFloatBinary!"/";
package alias opFloatModulo = opFloatBinary!"%";

package alias opBitAnd =
    execute!(runBitAnd, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runBitAnd(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a & b), execution.width);
    return execution.next;
}

package alias opBitOr =
    execute!(runBitOr, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runBitOr(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a | b), execution.width);
    return execution.next;
}

package alias opBitXor =
    execute!(runBitXor, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runBitXor(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a ^ b), execution.width);
    return execution.next;
}

package alias opShiftLeft =
    execute!(runShiftLeft, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runShiftLeft(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = shiftCount(
        loadUnsigned(execution.source, execution.width), execution.width);
    storeWidth(place, cast(long) (a << b), execution.width);
    return execution.next;
}

// `>>` on an unsigned left operand, and `>>>` whatever the left operand's
// signedness: both fill the vacated high bits with zero.
package alias opShiftRightLogical =
    execute!(runShiftRightLogical, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runShiftRightLogical(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = shiftCount(
        loadUnsigned(execution.source, execution.width), execution.width);
    storeWidth(place, cast(long) (a >> b), execution.width);
    return execution.next;
}

// `>>` on a signed left operand: the vacated high bits copy the sign bit
// down instead, so the left operand is read signed - the one binary
// opcode besides the divisions and comparisons below whose bits depend on
// an operand's signedness, and the only one of those where reading
// `source` signed as well would be wrong: the right operand is a shift
// count, not a value in the left operand's own domain.
package alias opShiftRightArithmetic =
    execute!(runShiftRightArithmetic, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runShiftRightArithmetic(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = shiftCount(
        loadUnsigned(execution.source, execution.width), execution.width);
    storeWidth(place, a >> b, execution.width);
    return execution.next;
}

// Division and modulo, unlike every other binary opcode above, answer
// differently depending on how both operands were read - so unlike those,
// this pair (and their `Unsigned` counterparts below) read `source`
// according to the same signedness as `destination` rather than always
// unsigned. D's own `/` and `%` on `long` already truncate toward zero
// and take the dividend's sign the way this needs, so this opcode is
// nothing more than that operator applied to the widened execution.
package alias opDivideSigned =
    execute!(runDivideSigned, OperandKind.storage, OperandKind.storage);

package alias opDivideSigned32 =
    execute!(runSigned32, OperandKind.storage, OperandKind.storage, "/");

package alias opModuloSigned32 =
    execute!(runSigned32, OperandKind.storage, OperandKind.storage, "%");

private const(Instruction)* runSigned32(string operation, Decoded)(
    ref Decoded execution,
) {
    const dividend = *cast(int*) execution.destination;
    const divisor = *cast(int*) execution.source;
    mixin("*cast(int*) execution.destination = dividend "
        ~ operation ~ " divisor;");
    return execution.next;
}

private const(Instruction)* runDivideSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = loadSigned(execution.source, execution.width);
    storeWidth(place, a / b, execution.width);
    return execution.next;
}

package alias opModuloSigned =
    execute!(runModuloSigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runModuloSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = loadSigned(execution.source, execution.width);
    storeWidth(place, a % b, execution.width);
    return execution.next;
}

package alias opDivideUnsigned =
    execute!(runDivideUnsigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runDivideUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a / b), execution.width);
    return execution.next;
}

package alias opModuloUnsigned =
    execute!(runModuloUnsigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runModuloUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    storeWidth(place, cast(long) (a % b), execution.width);
    return execution.next;
}


// The eight relational-comparison opcodes: `destination` holds the left
// operand and `source` the right one on entry, both read at `execution.width`
// with the signedness the opcode's own name commits to, since an
// ordering answers differently depending on it - `uint.max < 1u` is
// false, but the same bits read signed (`-1 < 1`) are true. Only the
// answer's single byte at `destination` is written; the compiler copies
// it out to wherever the `bool` result is actually needed.
package alias opLessThanSigned =
    execute!(runLessThanSigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runLessThanSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = loadSigned(execution.source, execution.width);
    *cast(ubyte*) place = (a < b) ? 1 : 0;
    return execution.next;
}

package alias opLessThanUnsigned =
    execute!(runLessThanUnsigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runLessThanUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    *cast(ubyte*) place = (a < b) ? 1 : 0;
    return execution.next;
}

package alias opLessOrEqualSigned =
    execute!(runLessOrEqualSigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runLessOrEqualSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = loadSigned(execution.source, execution.width);
    *cast(ubyte*) place = (a <= b) ? 1 : 0;
    return execution.next;
}

package alias opLessOrEqualUnsigned =
    execute!(runLessOrEqualUnsigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runLessOrEqualUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    *cast(ubyte*) place = (a <= b) ? 1 : 0;
    return execution.next;
}

package alias opGreaterThanSigned =
    execute!(runGreaterThanSigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runGreaterThanSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = loadSigned(execution.source, execution.width);
    *cast(ubyte*) place = (a > b) ? 1 : 0;
    return execution.next;
}

package alias opGreaterThanUnsigned =
    execute!(runGreaterThanUnsigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runGreaterThanUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    *cast(ubyte*) place = (a > b) ? 1 : 0;
    return execution.next;
}

package alias opGreaterOrEqualSigned =
    execute!(runGreaterOrEqualSigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runGreaterOrEqualSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadSigned(place, execution.width);
    const b = loadSigned(execution.source, execution.width);
    *cast(ubyte*) place = (a >= b) ? 1 : 0;
    return execution.next;
}

package alias opGreaterOrEqualUnsigned =
    execute!(runGreaterOrEqualUnsigned, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runGreaterOrEqualUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    *cast(ubyte*) place = (a >= b) ? 1 : 0;
    return execution.next;
}

// `==`/`!=`: both operands share one type by the time the compiler emits
// either of these, so the same bits compare equal whichever way they are
// read - neither needs a signed and an unsigned form.
package alias opEqual =
    execute!(runEqual, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runEqual(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    *cast(ubyte*) place = (a == b) ? 1 : 0;
    return execution.next;
}

// Bytewise equality for two native dynamic-array values. The compiler emits
// this only when DMD left EqualExp.lowering null, which means the element
// types are safe for memcmp. `destination` holds the left array on entry and
// the bool result on exit; `source` holds the right array; `width` is the
// element size.
package alias opArrayEqual =
    execute!(runArrayEqual, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runArrayEqual(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcmp;

    const left = *cast(const(void)[]*) (execution.destination);
    const right = *cast(const(void)[]*) (execution.source);
    const byteLength = left.length * execution.width;
    const equal = left.length == right.length
        && (byteLength == 0 || memcmp(left.ptr, right.ptr, byteLength) == 0);
    *cast(ubyte*) (execution.destination) = equal ? 1 : 0;
    return execution.next;
}

// Bytewise equality for two native static-array values, laid out in place
// in the frame with no length/pointer header of their own - unlike
// `opArrayEqual`'s dynamic arrays, `destination` and `source` already are
// the arrays' own bytes, not a `{length, pointer}` pair pointing at them.
// `width` is the whole array's own byte size, every element's bytes
// together, since a static array's dimension is part of its type rather
// than a run-time value to compare separately.
package alias opStaticArrayEqual =
    execute!(runStaticArrayEqual, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runStaticArrayEqual(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcmp;

    const equal = execution.width == 0
        || memcmp(execution.destination, execution.source, execution.width) == 0;
    *cast(ubyte*) (execution.destination) = equal ? 1 : 0;
    return execution.next;
}

package alias opNotEqual =
    execute!(runNotEqual, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runNotEqual(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    const b = loadUnsigned(execution.source, execution.width);
    *cast(ubyte*) place = (a != b) ? 1 : 0;
    return execution.next;
}

// Floating comparisons read values in their declared precision instead of
// reusing integral bit comparisons. This preserves IEEE 754 equality for
// NaN and signed zero and gives ordering the host's floating semantics.
private bool applyFloatComparison(string operation, T)(T left, T right)
        @nogc nothrow pure {
    return mixin("left " ~ operation ~ " right");
}

private alias opFloatComparison(string operation) =
    execute!(runFloatComparison, OperandKind.storage, OperandKind.storage, operation);

private const(Instruction)* runFloatComparison(string operation, Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    bool result;
    if (execution.width == float.sizeof)
        result = applyFloatComparison!operation(
            *cast(float*) place,
            *cast(const float*) (execution.source),
        );
    else if (execution.width == double.sizeof)
        result = applyFloatComparison!operation(
            *cast(double*) place,
            *cast(const double*) (execution.source),
        );
    else {
        assert(execution.width == real.sizeof);
        result = applyFloatComparison!operation(
            *cast(real*) place,
            *cast(const real*) (execution.source),
        );
    }
    *cast(ubyte*) place = result ? 1 : 0;
    return execution.next;
}

package alias opFloatEqual = opFloatComparison!"==";
package alias opFloatNotEqual = opFloatComparison!"!=";
package alias opFloatLessThan = opFloatComparison!"<";
package alias opFloatLessOrEqual = opFloatComparison!"<=";
package alias opFloatGreaterThan = opFloatComparison!">";
package alias opFloatGreaterOrEqual = opFloatComparison!">=";


// Element addressing. `destination` receives the address of an element:
// `source` is the array operand, `sourceWidth` the index operand (a
// `size_t`) and `width` the element size. The compiler emits the bounds
// check as a branch before them, so they cannot throw.
private enum IndexBase {
    // `source` holds a `{length, pointer}` slice.
    slice,
    // `source` is the storage of the elements.
    staticArray,
    // `source` holds a pointer to the elements.
    pointer,
}

private alias opIndex(IndexBase base) =
    execute!(runIndex, OperandKind.storage, OperandKind.storage, base);

private const(Instruction)* runIndex(IndexBase base, Decoded)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: arrayPointerOffset;

    static if (base == IndexBase.slice)
        auto first = *cast(ubyte**) (execution.source + arrayPointerOffset);
    else static if (base == IndexBase.staticArray)
        auto first = execution.source;
    else
        auto first = *cast(ubyte**) execution.source;
    const index = *cast(const(size_t)*) execution.storage(execution.sourceWidth);
    *cast(ubyte**) execution.destination = first + index * execution.width;
    return execution.next;
}

package alias opIndexSlice = opIndex!(IndexBase.slice);
package alias opIndexStatic = opIndex!(IndexBase.staticArray);
package alias opIndexPointer = opIndex!(IndexBase.pointer);


// Three-address forms. `source` is the left operand,
// `sourceWidth` the right operand, `destination` the result. All three are
// storage operands, except that with `constant` the right operand is the
// address of a constant in the native constant pool; the result is written
// after both operands are read.
private ubyte* rightOperand(bool constant, Decoded)(ref Decoded execution) {
    static if (constant)
        return cast(ubyte*) execution.sourceWidth;
    else
        return execution.storage(execution.sourceWidth);
}

private alias opInt3(string operation, bool constant = false) =
    execute!(runInt3, OperandKind.storage, OperandKind.storage, operation,
        constant);

private const(Instruction)* runInt3(string operation, bool constant, Decoded)(
    ref Decoded execution,
) {
    const a = loadUnsigned(execution.source, execution.width);
    const b = loadUnsigned(rightOperand!constant(execution), execution.width);
    storeWidth(execution.destination,
        cast(long) mixin("a " ~ operation ~ " b"), execution.width);
    return execution.next;
}

private alias opShift3(string operation, bool signed, bool constant = false) =
    execute!(runShift3, OperandKind.storage, OperandKind.storage, operation,
        signed, constant);

private const(Instruction)* runShift3(string operation, bool signed,
    bool constant, Decoded)(
    ref Decoded execution,
) {
    static if (signed)
        const a = loadSigned(execution.source, execution.width);
    else
        const a = loadUnsigned(execution.source, execution.width);
    const b = shiftCount(
        loadUnsigned(rightOperand!constant(execution), execution.width),
        execution.width);
    storeWidth(execution.destination,
        cast(long) mixin("a " ~ operation ~ " b"), execution.width);
    return execution.next;
}

// `/` and `%` read both operands with the signedness of the operation.
private alias opDivide3(string operation, bool signed, bool constant = false) =
    execute!(runDivide3, OperandKind.storage, OperandKind.storage, operation,
        signed, constant);

private const(Instruction)* runDivide3(string operation, bool signed,
    bool constant, Decoded)(
    ref Decoded execution,
) {
    // Signed 32-bit division is native `int` division, so `int.min / -1`
    // traps as it does in compiled D. The widened path below would not.
    static if (signed) {
        if (execution.width == int.sizeof) {
            const dividend = *cast(const int*) execution.source;
            const divisor = *cast(const int*) rightOperand!constant(execution);
            *cast(int*) execution.destination = mixin("dividend "
                ~ operation ~ " divisor");
            return execution.next;
        }
    }
    static if (signed)
        alias load = loadSigned;
    else
        alias load = loadUnsigned;
    const a = load(execution.source, execution.width);
    const b = load(rightOperand!constant(execution), execution.width);
    storeWidth(execution.destination, cast(long) mixin("a " ~ operation ~ " b"),
        execution.width);
    return execution.next;
}

private alias opFloat3(string operation, bool constant = false) =
    execute!(runFloat3, OperandKind.storage, OperandKind.storage, operation,
        constant);

private const(Instruction)* runFloat3(string operation, bool constant, Decoded)(
    ref Decoded execution,
) {
    const right = rightOperand!constant(execution);
    if (execution.width == double.sizeof)
        *cast(double*) execution.destination = applyFloatBinary!operation(
            *cast(const double*) execution.source,
            *cast(const double*) right);
    else if (execution.width == float.sizeof)
        *cast(float*) execution.destination = applyFloatBinary!operation(
            *cast(const float*) execution.source,
            *cast(const float*) right);
    else
        *cast(real*) execution.destination = applyFloatBinary!operation(
            *cast(const real*) execution.source,
            *cast(const real*) right);
    return execution.next;
}

private alias opCompare3(string operation, bool signed, bool constant = false) =
    execute!(runCompare3, OperandKind.storage, OperandKind.storage,
        operation, signed, constant);

private const(Instruction)* runCompare3(string operation, bool signed,
    bool constant, Decoded)(
    ref Decoded execution,
) {
    static if (signed)
        alias load = loadSigned;
    else
        alias load = loadUnsigned;
    const a = load(execution.source, execution.width);
    const b = load(rightOperand!constant(execution), execution.width);
    *cast(ubyte*) execution.destination = mixin("a " ~ operation ~ " b")
        ? 1 : 0;
    return execution.next;
}

private alias opFloatCompare3(string operation, bool constant = false) =
    execute!(runFloatCompare3, OperandKind.storage, OperandKind.storage,
        operation, constant);

private const(Instruction)* runFloatCompare3(string operation, bool constant,
    Decoded)(
    ref Decoded execution,
) {
    const right = rightOperand!constant(execution);
    bool result;
    if (execution.width == double.sizeof)
        result = applyFloatComparison!operation(
            *cast(const double*) execution.source, *cast(const double*) right);
    else if (execution.width == float.sizeof)
        result = applyFloatComparison!operation(
            *cast(const float*) execution.source, *cast(const float*) right);
    else
        result = applyFloatComparison!operation(
            *cast(const real*) execution.source, *cast(const real*) right);
    *cast(ubyte*) execution.destination = result ? 1 : 0;
    return execution.next;
}

private enum threeAddressNames = [
    ["opAdd3", "opInt3", `"+"`],
    ["opSubtract3", "opInt3", `"-"`],
    ["opMultiply3", "opInt3", `"*"`],
    ["opBitAnd3", "opInt3", `"&"`],
    ["opBitOr3", "opInt3", `"|"`],
    ["opBitXor3", "opInt3", `"^"`],
    ["opShiftLeft3", "opShift3", `"<<", false`],
    ["opShiftRightLogical3", "opShift3", `">>", false`],
    ["opShiftRightArithmetic3", "opShift3", `">>", true`],
    ["opDivideSigned3", "opDivide3", `"/", true`],
    ["opDivideUnsigned3", "opDivide3", `"/", false`],
    ["opModuloSigned3", "opDivide3", `"%", true`],
    ["opModuloUnsigned3", "opDivide3", `"%", false`],
    ["opFloatAdd3", "opFloat3", `"+"`],
    ["opFloatSubtract3", "opFloat3", `"-"`],
    ["opFloatMultiply3", "opFloat3", `"*"`],
    ["opFloatDivide3", "opFloat3", `"/"`],
    ["opLessThanSigned3", "opCompare3", `"<", true`],
    ["opLessThanUnsigned3", "opCompare3", `"<", false`],
    ["opLessOrEqualSigned3", "opCompare3", `"<=", true`],
    ["opLessOrEqualUnsigned3", "opCompare3", `"<=", false`],
    ["opGreaterThanSigned3", "opCompare3", `">", true`],
    ["opGreaterThanUnsigned3", "opCompare3", `">", false`],
    ["opGreaterOrEqualSigned3", "opCompare3", `">=", true`],
    ["opGreaterOrEqualUnsigned3", "opCompare3", `">=", false`],
    ["opEqual3", "opCompare3", `"==", false`],
    ["opNotEqual3", "opCompare3", `"!=", false`],
    ["opFloatEqual3", "opFloatCompare3", `"=="`],
    ["opFloatNotEqual3", "opFloatCompare3", `"!="`],
    ["opFloatLessThan3", "opFloatCompare3", `"<"`],
    ["opFloatLessOrEqual3", "opFloatCompare3", `"<="`],
    ["opFloatGreaterThan3", "opFloatCompare3", `">"`],
    ["opFloatGreaterOrEqual3", "opFloatCompare3", `">="`],
];

static foreach (triple; threeAddressNames) {
    mixin("package alias " ~ triple[0] ~ " = " ~ triple[1] ~ "!("
        ~ triple[2] ~ ", false);");
    mixin("package alias " ~ triple[0] ~ "K = " ~ triple[1] ~ "!("
        ~ triple[2] ~ ", true);");
}

// Every three-address handler, and the form of each with a constant right
// operand at the same position.
package alias threeAddressHandlers = mixin(handlerList(""));
package alias threeAddressConstantHandlers = mixin(handlerList("K"));

private string handlerList(in string suffix) {
    string list = "AliasSeq!(";
    foreach (triple; threeAddressNames)
        list ~= triple[0] ~ suffix ~ ", ";
    return list ~ ")";
}

// The form of a three-address handler whose right operand is a constant, or
// null.
package Instruction.Handler constantForm(Instruction.Handler handler) {
    static foreach (triple; threeAddressNames)
        if (handler is mixin("&" ~ triple[0]))
            return mixin("&" ~ triple[0] ~ "K");
    return null;
}

// How a fused compare-and-branch reads its operands. A floating compare is
// never rewritten as the opposite compare (`!(a < b)` is not `a >= b` for
// NaN): each handler jumps when its own answer equals `jumpWhen`.
package enum CompareKind {
    signed,
    unsigned,
    floating,
}

package enum Comparison {
    lessThan,
    lessOrEqual,
    greaterThan,
    greaterOrEqual,
    equal,
    notEqual,
}

private enum comparisonSymbols = ["<", "<=", ">", ">=", "==", "!="];

// Compare and branch in one instruction. `destination` is the left operand,
// `source` the right operand (or, with `constant`, the address of a
// constant in the native constant pool), `sourceWidth` the branch target.
private alias opFusedBranch(Comparison comparison, CompareKind kind,
    bool jumpWhen, bool constant) =
    execute!(runFusedBranch, OperandKind.storage,
        constant ? OperandKind.immediate : OperandKind.storage,
        comparisonSymbols[comparison], kind, jumpWhen);

private const(Instruction)* runFusedBranch(string operation, CompareKind kind,
    bool jumpWhen, Decoded)(
    ref Decoded execution,
) {
    static if (is(typeof(execution.source) == size_t))
        const right = cast(const(ubyte)*) execution.source;
    else
        const right = execution.source;
    bool result;
    static if (kind == CompareKind.floating) {
        if (execution.width == double.sizeof)
            result = applyFloatComparison!operation(
                *cast(const double*) execution.destination,
                *cast(const double*) right);
        else if (execution.width == float.sizeof)
            result = applyFloatComparison!operation(
                *cast(const float*) execution.destination,
                *cast(const float*) right);
        else
            result = applyFloatComparison!operation(
                *cast(const real*) execution.destination,
                *cast(const real*) right);
    } else {
        static if (kind == CompareKind.signed)
            alias load = loadSigned;
        else
            alias load = loadUnsigned;
        const a = load(execution.destination, execution.width);
        const b = load(right, execution.width);
        result = mixin("a " ~ operation ~ " b");
    }
    if (result == jumpWhen)
        return cast(const(Instruction)*) execution.sourceWidth;
    return execution.next;
}

private enum fusedCount = EnumMembers!Comparison.length
    * EnumMembers!CompareKind.length * 2 * 2;

private size_t fusedIndex(
    in Comparison comparison, in CompareKind kind, in bool jumpWhen,
    in bool constant,
) {
    return ((comparison * EnumMembers!CompareKind.length + kind) * 2
        + jumpWhen) * 2 + constant;
}

// The compiler asks about every instruction it has emitted whether it is a
// branch, so the handlers are also kept in a hash set.
private enum fusedSlots = 256;
static assert(fusedSlots >= 2 * fusedCount);
private __gshared Instruction.Handler[fusedCount] fusedHandlers;
private __gshared Instruction.Handler[fusedSlots] fusedSet;

static assert((fusedSlots & (fusedSlots - 1)) == 0,
    "the hash keeps the top bits, so the slot count is a power of two");
private enum fusedSlotShift = size_t.sizeof * 8 - bsf(fusedSlots);

private size_t fusedSlot(in Instruction.Handler handler) {
    return (cast(size_t) handler * 0x9E37_79B9_7F4A_7C15UL) >> fusedSlotShift;
}

shared static this() {
    static foreach (comparison; EnumMembers!Comparison)
        static foreach (kind; EnumMembers!CompareKind)
            static foreach (jumpWhen; [false, true])
                static foreach (constant; [false, true])
                    fusedHandlers[fusedIndex(comparison, kind, jumpWhen,
                        constant)] = &opFusedBranch!(comparison, kind,
                        jumpWhen, constant);
    foreach (handler; fusedHandlers) {
        auto slot = fusedSlot(handler);
        while (fusedSet[slot] !is null)
            slot = (slot + 1) % fusedSlots;
        fusedSet[slot] = handler;
    }
}

package Instruction.Handler fusedBranchHandler(
    in Comparison comparison, in CompareKind kind, in bool jumpWhen,
    in bool constant,
) {
    return fusedHandlers[fusedIndex(comparison, kind, jumpWhen, constant)];
}

// Whether a fused compare-and-branch compares against a constant, so that
// its `source` is a constant-pool address and not a frame operand.
package bool fusesConstant(Instruction.Handler handler) {
    foreach (index, candidate; fusedHandlers)
        if (candidate is handler)
            return index % 2 == 1;
    return false;
}

package bool isFusedBranch(Instruction.Handler handler) {
    for (auto slot = fusedSlot(handler); fusedSet[slot] !is null;
            slot = (slot + 1) % fusedSlots)
        if (fusedSet[slot] is handler)
            return true;
    return false;
}


// `-x` and `~x`: `destination` holds the one operand on entry and the
// answer on exit; `source` is unused. Neither depends on the operand's
// signedness - the same low bits result whichever way it was widened.
package alias opNegate =
    execute!(runNegate, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runNegate(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    storeWidth(place, cast(long) (-a), execution.width);
    return execution.next;
}

private T applyFloatUnary(string operation, T)(T value) @nogc nothrow pure {
    return mixin(operation ~ "value");
}

private alias opFloatUnary(string operation) =
    execute!(runFloatUnary, OperandKind.storage, OperandKind.immediate, operation);

private const(Instruction)* runFloatUnary(string operation, Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    if (execution.width == float.sizeof)
        *cast(float*) place = applyFloatUnary!operation(*cast(float*) place);
    else if (execution.width == double.sizeof)
        *cast(double*) place =
            applyFloatUnary!operation(*cast(double*) place);
    else {
        assert(execution.width == real.sizeof);
        *cast(real*) place = applyFloatUnary!operation(*cast(real*) place);
    }
    return execution.next;
}

package alias opFloatNegate = opFloatUnary!"-";

package alias opComplement =
    execute!(runComplement, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runComplement(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    storeWidth(place, cast(long) (~a), execution.width);
    return execution.next;
}

// `!x`: true when `x` is zero. `destination` holds the operand, at
// `execution.width`, on entry and the single-byte `bool` answer on exit.
package alias opLogicalNot =
    execute!(runLogicalNot, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runLogicalNot(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    *cast(ubyte*) place = (a == 0) ? 1 : 0;
    return execution.next;
}

// `cast(bool) x`: true when `x` is nonzero - dmd classifies `bool` as an
// integral type, so a plain narrowing copy of the operand's low byte would
// answer wrongly for an operand like `256`, whose low byte is zero.
package alias opCastToBool =
    execute!(runCastToBool, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runCastToBool(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const a = loadUnsigned(place, execution.width);
    *cast(ubyte*) place = (a != 0) ? 1 : 0;
    return execution.next;
}

// Widens the `execution.source`-byte operand already at `destination` to fill
// `execution.width` bytes there instead, copying the sign bit into the new high
// bits. This op is for `snakebite.backends.bytecode.compiler`'s own
// internal widening of an already-evaluated operand into a wider storage
// slot - `readScalar`/`evalOperandInto` - where there is no `CastExp` to
// drive `compileCast`. A source-level cast, narrowing included, reaches
// `compileCast`, which always emits the `opCastAs!(CastKind)` instance
// for its own kind instead, `narrow`/`widenSigned`/`widenUnsigned`
// included. Reinterpreting a same-width operand as a differently signed
// one changes no bits at all, so neither caller emits a copy for that.
package alias opCastWidenSigned =
    execute!(runCastWidenSigned, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runCastWidenSigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const value = loadSigned(place, execution.source);
    storeWidth(place, value, execution.width);
    return execution.next;
}

// As `opCastWidenSigned`, filling the new high bits with zero instead.
package alias opCastWidenUnsigned =
    execute!(runCastWidenUnsigned, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runCastWidenUnsigned(Decoded)(
    ref Decoded execution,
) {
    auto place = execution.destination;
    const value = loadUnsigned(place, execution.source);
    storeWidth(place, cast(long) value, execution.width);
    return execution.next;
}

// A cast whose `CastKind` is a pure transformation of its source's own
// bytes into its destination's - `snakebite.nativevalue.applyCastAs`
// carries out every one, with `kind` itself a template parameter, so
// `snakebite.backends.bytecode.compiler.compileCast`'s own `final
// switch` on `CastPlan.kind` picks one instance of this op per
// `CastKind`, at compile time, rather than one op that reads its
// `CastKind` back out of `execution.constants` on every execution. The
// two sizes every kind but `sarrayToSlice`/`reinterpretSlice` needs
// come from `width`/`sourceWidth` directly, the same fields
// `opCastWidenSigned` above already spends on the one size it needs;
// `sarrayToSlice` reads `width` as its element count instead, and
// `reinterpretSlice` reads both as its two element sizes. Only
// `integralToFloat`, `floatToIntegral`, `complexToIntegral`, and
// `integralToComplex` also need a signedness bit that neither field
// has room for on top of its own size - `castSizeWithSignedness` below
// packs that bit into the same field's own top bit, the way
// `indirectStorage` above already tells an address slot from a plain
// displacement, rather than spending an `execution.constants` entry
// on it. Only `classReference` and `zero` still reach
// for a `CastExp` opcode of their own.
package alias opCastAs(CastKind kind) =
    execute!(runCastAs, OperandKind.storage, OperandKind.storage, kind);

private const(Instruction)* runCastAs(CastKind kind, Decoded)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: applyCastAs, CastLayout;

    with (CastKind) {
    static if (kind == integralToFloat || kind == integralToComplex)
        applyCastAs!kind(
            CastLayout(
                kind, castSize(execution.sourceWidth), execution.width,
                castUnsigned(execution.sourceWidth),
            ),
            execution.source, execution.destination,
        );
    else static if (kind == floatToIntegral || kind == complexToIntegral)
        applyCastAs!kind(
            CastLayout(
                kind, execution.sourceWidth, castSize(execution.width),
                false, castUnsigned(execution.width),
            ),
            execution.source, execution.destination,
        );
    else static if (kind == reinterpretSlice)
        applyCastAs!kind(
            CastLayout(
                kind, 0, 0, false, false,
                execution.sourceWidth, execution.width,
            ),
            execution.source, execution.destination,
        );
    else static if (kind == sarrayToSlice)
        applyCastAs!kind(
            CastLayout(kind, 0, 0, false, false, 0, 0, execution.width),
            execution.source, execution.destination,
        );
    else static if (kind == sarrayToPointer || kind == sliceToPointer
            || kind == pointerToArray || kind == pointerToIntegral
            || kind == delegateToPointer)
        applyCastAs!kind(
            CastLayout(kind, 0, execution.width),
            execution.source, execution.destination,
        );
    else
        // complexToReal, complexToImaginary, complexWidth, realToComplex,
        // imaginaryToComplex, floatWidth, narrow, widenSigned,
        // widenUnsigned: `applyCastAs` needs nothing beyond the two
        // plain sizes.
        applyCastAs!kind(
            CastLayout(kind, execution.sourceWidth, execution.width),
            execution.source, execution.destination,
        );
    }
    return execution.next;
}

// The one bit `integralToFloat`/`floatToIntegral`/`complexToIntegral`/
// `integralToComplex` need beyond the size `width`/`sourceWidth` above
// already carry for every cast op: their source's or destination's own
// signedness. `size` here is always small - a source or destination
// byte count - so its own top bit is always free to hold that one
// extra bit instead, the same trick `indirectStorage` above already
// uses to tell an address slot from a plain displacement.
package size_t castSizeWithSignedness(
    in size_t size, in bool unsigned,
) @safe pure nothrow @nogc {
    assert(size < (1UL << 63));
    return unsigned ? (size | (1UL << 63)) : size;
}

private size_t castSize(in size_t packed) @safe pure nothrow @nogc {
    return packed & ~(1UL << 63);
}

private bool castUnsigned(in size_t packed) @safe pure nothrow @nogc {
    return (packed & (1UL << 63)) != 0;
}

// As `opCastAs`, but for `narrow`/`widenSigned`/`widenUnsigned`
// only, and with both sizes template parameters instead of `width`/
// `sourceWidth` - the same idea as `opCopyFixed!size` above for a
// fixed-width `opCopy`: every D integral width is one of `1`/`2`/`4`/
// `8`, known at compile time to whichever `compileCast` call site
// reaches one of these four kinds, so `applyCastAs!kind`'s two
// `storeIntegral`/`loadIntegral` calls see compile-time-constant sizes
// and fold their own `switch` away entirely, the same straight-line
// code `opCopyFixed!size` already gets for a plain copy.
// `snakebite.backends.bytecode.compiler.emit`'s own peephole is what
// actually picks this over `opCastAs!kind`, once it sees both sizes
// are one of those four.
package alias opCastFixedAs(CastKind kind, size_t destSize, size_t sourceSize) =
    execute!(
        runCastFixedAs, OperandKind.storage, OperandKind.storage,
        kind, destSize, sourceSize,
    );

private const(Instruction)* runCastFixedAs(
    CastKind kind, size_t destSize, size_t sourceSize, Decoded,
)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: applyCastAs, CastLayout;

    applyCastAs!kind(
        CastLayout(kind, sourceSize, destSize),
        execution.source, execution.destination,
    );
    return execution.next;
}

package alias opFloatToBool =
    execute!(runFloatToBool, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runFloatToBool(Decoded)(
    ref Decoded execution,
) {
    floatingToBool(
        execution.destination,
        execution.source,
        execution.width,
    );
    return execution.next;
}

package alias opFloatWidthCast =
    execute!(runFloatWidthCast, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runFloatWidthCast(Decoded)(
    ref Decoded execution,
) {
    const value = loadFloating(execution.source, execution.sourceWidth);
    storeFloating(execution.destination, value, execution.width);
    return execution.next;
}


// Reads `execution.width` bytes from the address held at `execution.source` -
// a dynamic array's element, at an address the compiler computed from its
// pointer word and an index - and writes them to `execution.destination`.
public alias opLoadIndirect =
    execute!(runLoadIndirect, OperandKind.storage, OperandKind.storage);

package alias opLoadIndirectFixed(size_t width) =
    execute!(runLoadIndirect, OperandKind.storage, OperandKind.storage, width);

// These memory operations cannot throw a D exception or transfer control.
// Decode the copy after the load: its address slot can alias the load target.
package const(Instruction)* opLoadThenCopy(size_t loadWidth, size_t copyWidth)(
    const(Instruction)* pc,
    Activation* activation,
    DispatchState* state,
) {
    static if (chainedDispatch)
        // The chain reaches the copy by itself.
        return opLoadIndirectFixed!loadWidth(pc, activation, state);
    else {
        const next = opLoadIndirectFixed!loadWidth(pc, activation, state);
        // A cleanup range can end between the two instructions.
        return next is activation.end
            ? next : opCopyFixed!copyWidth(next, activation, state);
    }
}

private const(Instruction)* runLoadIndirect(size_t width = 0, Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    auto address = *cast(void**) (execution.source);
    static if (width)
        memcpy(execution.destination, address, width);
    else
        memcpy(execution.destination, address, execution.width);
    return execution.next;
}

package alias opLoadBitfield =
    execute!(runLoadBitfield, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runLoadBitfield(Decoded)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: BitfieldAccess;

    auto address = *cast(void**) (execution.source);
    const metadata = execution.sourceWidth;
    const value = BitfieldAccess.decode(metadata).load(address);
    storeWidth(execution.destination, value,
        BitfieldAccess.resultWidth(metadata));
    return execution.next;
}


// Writes `execution.source` itself - not the bytes stored there, the
// address of that slot - to `execution.destination`, always `size_t.sizeof`
// bytes: the one place this VM turns a frame slot into a value a `ref`
// binding, a `~=`'s `ref` argument to druntime, or a `ref` return can carry
// around and dereference later through `opLoadIndirect`/`opStoreIndirect`.
package alias opFrameAddress =
    execute!(runFrameAddress, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runFrameAddress(Decoded)(
    ref Decoded execution,
) {
    *cast(void**) (execution.destination) = execution.source;
    return execution.next;
}

// Reserves the `size_t` bytes held at `execution.source` and writes their
// address to `execution.destination`. The reservation lies above the
// running activation, so it goes when that activation returns - how long
// `alloca` memory lives.
package alias opAlloca =
    execute!(runAlloca, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runAlloca(Decoded)(
    ref Decoded execution,
) {
    const size = *cast(const(size_t)*) (execution.source);
    *cast(void**) (execution.destination) =
        execution.frames.reserve(size, 16);
    return execution.next;
}


// Zeroes `execution.width` bytes at `execution.destination` - a zero-init
// struct
// local or array element wider than the 8 bytes `opConstant`'s `storeWidth`
// lays out, the only width this VM's integral opcodes cannot already carry
// as a single constant.
package alias opZero =
    execute!(runZero, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runZero(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memset;

    memset(execution.destination, 0, execution.width);
    return execution.next;
}


// As `opLoadIndirect`, the other way: writes `execution.width` bytes from
// `execution.source` to the address held at `execution.destination`.
package alias opStoreIndirect =
    execute!(runStoreIndirect, OperandKind.storage, OperandKind.storage);

package alias opStoreIndirectFixed(size_t width) =
    execute!(runStoreIndirect, OperandKind.storage, OperandKind.storage, width);

private const(Instruction)* runStoreIndirect(size_t width = 0, Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    auto address = *cast(void**) (execution.destination);
    static if (width)
        memcpy(address, execution.source, width);
    else
        memcpy(address, execution.source, execution.width);
    return execution.next;
}

package alias opStoreBitfield =
    execute!(runStoreBitfield, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runStoreBitfield(Decoded)(
    ref Decoded execution,
) {
    import snakebite.nativevalue: BitfieldAccess;

    auto address = *cast(void**) (execution.destination);
    BitfieldAccess.decode(execution.sourceWidth).store(
        address, loadUnsigned(execution.source, execution.width));
    return execution.next;
}


// `dest[] = src[]`, `{length, pointer}` pairs at `execution.destination`
// and `execution.source`, with `execution.width` the element size baked in at
// compile time (both sides share one element size - the compiler checked
// that before emitting this). It copies `dest.length` elements and checks
// nothing: the compiler has already decided the length and overlap checks
// (`opSlicesConform`), or the flags have none.
package alias opSliceCopy =
    execute!(runSliceCopy, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runSliceCopy(Decoded)(
    ref Decoded execution,
) {
    import snakebite.backends.slicecopy: copyUnchecked;

    copyUnchecked(
        *cast(void[]*) execution.destination,
        *cast(void[]*) execution.source,
        execution.width);

    return execution.next;
}


// Whether `dest[] = src[]` passes dmd's length and overlap check, as one
// byte that replaces the `{length, pointer}` pair at `execution.destination`
// (a scratch copy: a binary opcode overwrites its left operand).
package alias opSlicesConform =
    execute!(runSlicesConform, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runSlicesConform(Decoded)(
    ref Decoded execution,
) {
    import snakebite.backends.slicecopy: slicesConform;

    auto dest = execution.destination;
    *cast(ubyte*) dest = slicesConform(
        *cast(void[]*) dest, *cast(void[]*) execution.source,
        execution.width);

    return execution.next;
}


// `p[a .. b] = v;`/`a[] = v;` for a dynamic-length target and a scalar
// right side (`v` is a single element, not an array): the run-time
// counterpart to `compileSliceAssign`'s own compile-time-unrolled fill
// loop for a static array, whose element count is not known until the
// program runs here. `v`'s bytes (`execution.width` wide, at
// `execution.source`) are copied into every element of the `{length,
// pointer}`
// pair at `execution.destination`.
package alias opSliceFill =
    execute!(runSliceFill, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runSliceFill(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;
    import snakebite.nativevalue: arrayLengthOffset, arrayPointerOffset;

    auto dest = execution.destination;
    auto value = execution.source;
    const length = *cast(const(size_t)*) (dest + arrayLengthOffset);
    auto destPtr = *cast(ubyte**) (dest + arrayPointerOffset);
    foreach (_; 0 .. length) {
        memcpy(destPtr, value, execution.width);
        destPtr += execution.width;
    }

    return execution.next;
}
