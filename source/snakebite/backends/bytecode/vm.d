module snakebite.backends.bytecode.vm;


private:


extern(C) void executeCallPlan(
    const(void)* opaquePlan,
    void* returnPlace,
    scope const(void*)* arguments,
    size_t argumentCount,
);

extern(C) bool executeIndirectCallPlan(
    const(void)* opaquePlan, ref const(void)* address, void* returnPlace,
    scope const(void*)* arguments, size_t argumentCount,
);

import snakebite.callarguments: CallArguments;
import snakebite.nativevalue:
    floatingToBool, floatingToIntegral, integralToFloating, loadFloating,
    loadSigned, loadUnsigned, storeFloating, storeIntegral;
import object: Throwable, TypeInfo_Class;

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
// only the one field its `Kind` names.
public struct CallSite {
    public enum Kind {
        // `callee` already names a function this compiler compiled to
        // its own `Instruction`s.
        guest,
        // `nativePlan` is a `snakebite.ffi.plan.CallPlan`, opaque to this
        // module, run through `executeCallPlan` - prepared either for a
        // guest-declared `extern(C)` function or for a druntime hook the
        // compiler resolved by linker symbol (an allocation, a `~=`
        // dchar append, a bounds check): the same shape either way, so
        // this VM hardcodes no druntime signature for any of them.
        native,
        // `calleeSlotOffset` is the caller's own frame offset holding a
        // `const(Function)*` value read back at run time in place of a
        // fixed `callee` - a call through a function pointer or delegate
        // value. Native addresses, including vtable entries, use the
        // call site's prepared native plan.
        indirect,
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

    // `calleeSlotOffset` names the caller frame slot `opCall` reads the
    // callee's own address back out of at run time.
    public static CallSite indirect(
        size_t calleeSlotOffset, Arg[] args, size_t returnWidth,
        const(void)* nativePlan = null,
    ) {
        CallSite site;
        site.kind = Kind.indirect;
        site.nativePlan = nativePlan;
        site.calleeSlotOffset = calleeSlotOffset;
        site.args = args;
        site.returnWidth = returnWidth;
        return site;
    }

    package Kind kind;
    package Arg[] args;
    package size_t returnWidth;
    package const(Function)* callee;
    package const(void)* nativePlan;
    package size_t calleeSlotOffset;
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

    private const(Instruction)* _pc;
    private ubyte* _frame;

    public this(
        const(Instruction)* pc, ubyte* frame, void* returnPlace,
        const(long)[] constants, const(CallSite)[] callSites,
        const(AssertSite)[] assertSites, FrameStack* frames,
    ) pure nothrow @nogc {
        _pc = pc;
        _frame = frame;
        this.returnPlace = returnPlace;
        this.constants = constants;
        this.callSites = callSites;
        this.assertSites = assertSites;
        this.frames = frames;
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
        if ((operand & (1UL << 63)) == 0)
            return _frame + operand;
        const addressSlot = (operand >> 32) & 0x7fff_ffffUL;
        return *cast(ubyte**) (_frame + addressSlot) + cast(uint) operand;
    }
}

private const(Instruction)* execute(
    alias operation,
    OperandKind destinationKind,
    OperandKind sourceKind,
    Parameters...,
)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    // const would prevent operations from writing through storage pointers.
    auto execution = Execution!(destinationKind, sourceKind)(
        pc, frame, returnPlace, constants, callSites, assertSites, frames,
    );
    return operation!Parameters(execution);
}


public struct Instruction {
    public alias Handler = const(Instruction)* function(
        const(Instruction)* pc,
        ubyte* frame,
        void* returnPlace,
        scope const long[] constants,
        scope const CallSite[] callSites,
        scope const AssertSite[] assertSites,
        FrameStack* frames,
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
        initializeClosure(&function_, frame.base, &_frames);
        auto pc = function_.instructions.ptr;
        dispatch(
            pc, frame.base, returnPlace, function_.constants,
            function_.callSites, function_.assertSites,
            function_.exceptionHandlers, &_frames,
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


// Runs one guest function without consuming host stack space per opcode.
private void dispatch(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    scope const ExceptionHandler[] exceptionHandlers,
    FrameStack* frames,
    const(Instruction)* end = null,
) {
    const start = pc;
    const cleanupMark = frames.cleanupMark;
    scope (exit)
        cleanupSince(
            cleanupMark, frame, constants, callSites, assertSites, frames);

    while (pc !is null && pc !is end) {
        try {
            while (pc !is null && pc !is end)
                pc = pc.handler(
                    pc, frame, returnPlace, constants, callSites,
                    assertSites, frames);
        } catch (Throwable throwable) {
            cleanupSince(
                cleanupMark, frame, constants, callSites, assertSites, frames);
            size_t firstHandler;
            while (true) {
                const handler = findHandler(
                    exceptionHandlers[firstHandler .. $], pc,
                    throwable.classinfo);
                if (handler is null || (end !is null
                        && (handler.handler < start || handler.handler >= end)))
                    throw throwable;

                if (handler.cleanupEnd !is null) {
                    try {
                        unwindFinally(throwable, () {
                            dispatch(handler.handler, frame, returnPlace,
                                constants, callSites, assertSites,
                                exceptionHandlers, frames, handler.cleanupEnd);
                        });
                    } catch (Throwable chained) {
                        throwable = chained;
                    }
                    // Inner handlers have already had their chance to catch
                    // this unwind. Continue with the scopes outside finally.
                    firstHandler = handler - exceptionHandlers.ptr + 1;
                    continue;
                }

                if (handler.catchOffset != size_t.max)
                    *cast(void**)(frame + handler.catchOffset) = cast(void*) throwable;
                pc = handler.handler;
                break;
            }
        }
    }
}


private void unwindFinally(Throwable throwable, scope void delegate() cleanup) {
    try {
        throw throwable;
    } finally {
        cleanup();
    }
}


private void cleanupSince(
    in size_t mark,
    ubyte* frame,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    frames.finishCleanups(mark, (in size_t siteIndex) {
        auto site = &callSites[siteIndex];
        assert(site.cleanupStart !is null, "temporary cleanup start missing");
        assert(site.cleanupEnd !is null, "temporary cleanup end missing");
        auto pc = cast(const(Instruction)*) site.cleanupStart;
        const end = cast(const(Instruction)*) site.cleanupEnd;
        while (pc !is end) {
            pc = pc.handler(
                pc, frame, null, constants, callSites, assertSites, frames);
        }
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
    execution.frames.suspendCleanup(*cast(ubyte**) execution.source);
    return execution.next;
}


public alias opTemporaryArm =
    execute!(runTemporaryArm, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runTemporaryArm(Decoded)(
    ref Decoded execution,
) {
    execution.frames.armCleanup(*cast(ubyte**) execution.source);
    return execution.next;
}


public alias opTemporaryArmAddress =
    execute!(runTemporaryArmAddress, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runTemporaryArmAddress(Decoded)(
    ref Decoded execution,
) {
    execution.frames.armCleanup(execution.source);
    return execution.next;
}


public alias opTemporaryEnd =
    execute!(runTemporaryEnd, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runTemporaryEnd(Decoded)(
    ref Decoded execution,
) {
    const mark = loadUnsigned(execution.destination, size_t.sizeof);
    cleanupSince(mark, execution._frame, execution.constants,
        execution.callSites, execution.assertSites, execution.frames);
    return execution.next;
}


private const(ExceptionHandler)* findHandler(
    const(ExceptionHandler)[] handlers,
    const(Instruction)* pc,
    TypeInfo_Class actual,
) @nogc nothrow {
    import snakebite.backends.exceptions: catchMatches;

    foreach (ref handler; handlers) {
        if (pc < handler.bodyStart || pc >= handler.bodyEnd)
            continue;
        if (catchMatches(handler.type, actual))
            return &handler;
    }
    return null;
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
    execute!(runAssert, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runAssert(Decoded)(
    ref Decoded execution,
) {
    if (loadUnsigned(execution.destination, execution.width) != 0)
        return execution.next;

    import core.exception: AssertError;

    const site = execution.assertSites[execution.source];
    throw new AssertError(site.message, site.file, site.line);
}


// Throws the Throwable reference at `execution.destination`. The expression has
// already been evaluated into the frame, so this preserves the original
// object while dispatch unwinds through guest catch handlers and frames.
package alias opThrow =
    execute!(runThrow, OperandKind.storage, OperandKind.immediate);

private const(Instruction)* runThrow(Decoded)(
    ref Decoded execution,
) {
    auto throwable = cast(Throwable) *cast(void**) (execution.destination);
    throw throwable;
}


// Calls `callSites[execution.source]`'s callee, one of the three
// `CallSite.Kind`s:
// a guest callee already compiled to `Instruction`s, a native one reached
// through a prepared FFI plan, or an indirect one whose own address sits
// in the caller's frame. `execution.width` is unused.
public alias opCall =
    execute!(runCall, OperandKind.result, OperandKind.immediate);

private const(Instruction)* runCall(Decoded)(
    ref Decoded execution,
) {
    const site = execution.callSites[execution.source];
    final switch (site.kind) with (CallSite.Kind) {
    case guest:
        return callFunction(execution, site, site.callee);
    case indirect:
        auto callee =
            *cast(const(void)**) (execution.storage(site.calleeSlotOffset));
        if (site.nativePlan !is null) {
            auto arguments = CallArguments(site.args.length);
            auto values = arguments.values;
            foreach (i, arg; site.args)
                values[i] = execution.storage(arg.callerOffset);
            if (executeIndirectCallPlan(site.nativePlan, callee,
                    execution.destination, values.ptr, values.length))
                return execution.next;
        }
        return callFunction(execution, site, cast(const(Function)*) callee);
    case native:
        auto arguments = CallArguments(site.args.length);
        // const would make the address slots read-only.
        auto values = arguments.values;
        foreach (i, arg; site.args)
            values[i] = execution.storage(arg.callerOffset);
        auto result = execution.destination;
        executeCallPlan(
            site.nativePlan, result, values.ptr, values.length,
        );
        return execution.next;
    }
}


// `opCall`'s own `guest`/`indirect` arms, once each has found its own
// `callee`: pushes its frame, copies `site.args` into it, and runs it to
// its own return instruction through the nested dispatch loop with
// `execution.destination` as its result slot, or null for a discarded result.
private const(Instruction)* callFunction(Decoded)(
    ref Decoded execution,
    scope const ref CallSite site,
    const(Function)* callee,
) {
    import core.stdc.string: memcpy;

    auto calleeFrame = execution.frames.push(callee.frameSize, callee.frameAlignment);

    foreach (arg; site.args)
        memcpy(
            calleeFrame.base + arg.calleeOffset,
            execution.storage(arg.callerOffset),
            arg.width,
        );

    initializeClosure(callee, calleeFrame.base, execution.frames);

    // The caller frame stays at a fixed address during nested calls.
    // This pointer must stay mutable so the callee can write the result.
    auto returnDestination = site.returnWidth == 0
        ? null
        : execution.destination;

    auto calleePc = callee.instructions.ptr;
    dispatch(
        calleePc, calleeFrame.base, returnDestination, callee.constants,
        callee.callSites, callee.assertSites, callee.exceptionHandlers, execution.frames,
    );

    return execution.next;
}


// Copies `execution.width` bytes from `execution.source` to `returnPlace` -
// `null` when the caller discarded the result, the same convention every
// backend uses for a call whose value nothing reads. `execution.destination` is
// unused: there is no frame slot on the receiving end, only `returnPlace`.
public alias opReturn =
    execute!(runReturn, OperandKind.immediate, OperandKind.storage);

private const(Instruction)* runReturn(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    if (execution.returnPlace !is null)
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
    const b = loadUnsigned(execution.source, execution.width);
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
    const b = loadUnsigned(execution.source, execution.width);
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
    const b = loadUnsigned(execution.source, execution.width);
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

// Integral comparison whose result is used only to choose a control-flow
// target. `sourceWidth` stores the resolved target address; unlike the
// value-producing comparison handlers this does not write a temporary bool.
private alias opCompareBranch(string operation, bool unsigned,
    bool branchWhenTrue) =
    execute!(runCompareBranch, OperandKind.storage, OperandKind.storage,
        operation, unsigned, branchWhenTrue);

private const(Instruction)* runCompareBranch(string operation, bool unsigned,
    bool branchWhenTrue, Decoded)(
    ref Decoded execution,
) {
    static if (unsigned)
        alias load = loadUnsigned;
    else
        alias load = loadSigned;
    const left = load(execution.destination, execution.width);
    const right = load(execution.source, execution.width);
    const result = mixin("left " ~ operation ~ " right");
    if (result == branchWhenTrue)
        return cast(const(Instruction)*) execution.sourceWidth;
    return execution.next;
}

package alias opLessThanSignedBranch =
    opCompareBranch!("<", false, false);
package alias opLessThanUnsignedBranch =
    opCompareBranch!("<", true, false);
package alias opLessOrEqualSignedBranch =
    opCompareBranch!("<=", false, false);
package alias opLessOrEqualUnsignedBranch =
    opCompareBranch!("<=", true, false);
package alias opGreaterThanSignedBranch =
    opCompareBranch!(">", false, false);
package alias opGreaterThanUnsignedBranch =
    opCompareBranch!(">", true, false);
package alias opGreaterOrEqualSignedBranch =
    opCompareBranch!(">=", false, false);
package alias opGreaterOrEqualUnsignedBranch =
    opCompareBranch!(">=", true, false);
package alias opEqualBranch = opCompareBranch!("==", false, false);
package alias opNotEqualBranch = opCompareBranch!("!=", false, false);

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
// bits. A narrowing cast needs no opcode of its own: on this VM's
// little-endian host, the low bytes of any stored integral already are
// its truncation to a narrower width, so the compiler reaches for
// `opCopy` instead. Reinterpreting a same-width operand as a differently
// signed one changes no bits at all, so the compiler does not even emit
// a copy for that.
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

private alias opIntegralToFloat(bool unsigned_) =
    execute!(runIntegralToFloat, OperandKind.storage, OperandKind.storage, unsigned_);

private const(Instruction)* runIntegralToFloat(bool unsigned_, Decoded)(
    ref Decoded execution,
) {
    integralToFloating(
        execution.destination,
        execution.source,
        execution.width,
        execution.sourceWidth,
        unsigned_,
    );
    return execution.next;
}

package alias opIntegralToFloatSigned = opIntegralToFloat!false;
package alias opIntegralToFloatUnsigned = opIntegralToFloat!true;

private alias opFloatToIntegral(bool unsigned_) =
    execute!(runFloatToIntegral, OperandKind.storage, OperandKind.storage, unsigned_);

private const(Instruction)* runFloatToIntegral(bool unsigned_, Decoded)(
    ref Decoded execution,
) {
    floatingToIntegral(
        execution.destination,
        execution.source,
        execution.width,
        execution.sourceWidth,
        unsigned_,
    );
    return execution.next;
}

package alias opFloatToIntegralSigned = opFloatToIntegral!false;
package alias opFloatToIntegralUnsigned = opFloatToIntegral!true;

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

private const(Instruction)* runLoadIndirect(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    auto address = *cast(void**) (execution.source);
    memcpy(execution.destination, address, execution.width);
    return execution.next;
}

package alias opLoadBitfield =
    execute!(runLoadBitfield, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runLoadBitfield(Decoded)(
    ref Decoded execution,
) {
    auto address = *cast(void**) (execution.source);
    const metadata = execution.sourceWidth;
    const bitOffset = metadata & 0xffff;
    const fieldWidth = (metadata >> 16) & 0xffff;
    const resultWidth = (metadata >> 40) & 0xff;
    const isSigned = (metadata & (1UL << 32)) != 0;
    const storage = loadUnsigned(address, execution.width);
    const mask = ulong.max >> (64 - fieldWidth);
    ulong value = (storage >> bitOffset) & mask;
    if (isSigned && fieldWidth < 64 && (value & (1UL << (fieldWidth - 1))))
        value |= ulong.max << fieldWidth;
    storeWidth(execution.destination, cast(long) value, resultWidth);
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

private const(Instruction)* runStoreIndirect(Decoded)(
    ref Decoded execution,
) {
    import core.stdc.string: memcpy;

    auto address = *cast(void**) (execution.destination);
    memcpy(address, execution.source, execution.width);
    return execution.next;
}

package alias opStoreBitfield =
    execute!(runStoreBitfield, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runStoreBitfield(Decoded)(
    ref Decoded execution,
) {
    auto address = *cast(void**) (execution.destination);
    const metadata = execution.sourceWidth;
    const bitOffset = metadata & 0xffff;
    const fieldWidth = (metadata >> 16) & 0xffff;
    auto value = loadUnsigned(execution.source, execution.width);
    const mask = (ulong.max >> (64 - fieldWidth)) << bitOffset;
    auto storage = loadUnsigned(address, (metadata >> 40) & 0xff);
    storage = (storage & ~mask) | ((value << bitOffset) & mask);
    storeWidth(address, cast(long) storage, (metadata >> 40) & 0xff);
    return execution.next;
}


// `dest[] = src[]`, `{length, pointer}` pairs at `execution.destination`
// and `execution.source`, with `execution.width` the element size baked in at
// compile time (both sides share one element size - the compiler checked
// that before emitting this). Druntime owns the length and overlap checks.
package alias opSliceCopy =
    execute!(runSliceCopy, OperandKind.storage, OperandKind.storage);

private const(Instruction)* runSliceCopy(Decoded)(
    ref Decoded execution,
) {
    import snakebite.druntime.arraycopy: _d_arraycopy;

    auto dest = execution.destination;
    auto src = execution.source;
    _d_arraycopy(
        execution.width,
        *cast(void[]*) src,
        *cast(void[]*) dest,
    );

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
