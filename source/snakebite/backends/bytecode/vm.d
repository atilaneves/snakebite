module snakebite.backends.bytecode.vm;


private:


extern(C) void executeCallPlan(
    const(void)* opaquePlan,
    void* returnPlace,
    scope const(void*)* arguments,
    size_t argumentCount,
);

import snakebite.ffi.limits: maxArguments;
import snakebite.nativevalue: loadSigned, loadUnsigned, storeIntegral;
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
        // value, or through a vtable slot the compiler already resolved
        // into a temporary (`compileClassVtableSlot`/
        // `compileInterfaceVtableSlot`).
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
    ) {
        CallSite site;
        site.kind = Kind.indirect;
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
}


// Finds `object`'s own override of the interface method at `methodIndex`
// (`interfaceInfo`'s own vtable order - see `opResolveInterfaceMethod`'s
// doc) by walking `object`'s real class hierarchy, base first to most
// derived... actually most-derived first, since `object`'s own vptr names
// its most-derived `TypeInfo_Class` directly, and `.base` walks upward
// from there. `TypeInfo_Class`/`Interface` are plain druntime shapes, so
// this needs nothing from dmd's frontend to read them.
package extern(C) void* resolveInterfaceMethod(
    void* object, void* interfaceInfo, size_t methodIndex,
) {
    import object: Interface;

    if (object is null)
        return null;

    auto target = cast(TypeInfo_Class) interfaceInfo;
    for (auto info = *cast(TypeInfo_Class*) (*cast(void**) object);
            info !is null; info = info.base)
        foreach (entry; info.interfaces)
            if (entry.classinfo is target)
                return entry.vtbl[methodIndex];

    return null;
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
    //  - a frame offset, for `opCopy`/`opReturn` and for every arithmetic,
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
    //    `destination` of `opStaticStore`. `opResolveInterfaceMethod`'s
    //    `sourceWidth` carries an `interfaceInfo` address the same way.
    //  - a source offset's width, for floating-point conversions whose
    //    destination and source widths can differ - or, for
    //    `opResolveInterfaceMethod`, the interface method's own index
    //    (`width`).
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

    public this(in size_t frameCapacity) {
        _frames = FrameStack(frameCapacity);
    }

    public void call(
        scope const ref Function function_,
        void* returnPlace,
    ) {
        assert(function_.instructions.length > 0);
        assert(function_.frameAlignment > 0);

        auto frame = _frames.push(
            function_.frameSize,
            function_.frameAlignment,
        );
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


// Returns `pc`'s successor: what every opcode below does once it has done
// its own work, unless it is a branch that took the other path. The
// dispatch loop invokes the returned handler.
// Not `@nogc nothrow`; see `opConstant`.
private const(Instruction)* advance(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    const next = pc + 1;
    return next;
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
) {
    while (pc !is null) {
        try {
            while (pc !is null)
                pc = pc.handler(
                    pc, frame, returnPlace, constants, callSites,
                    assertSites, frames);
        } catch (Throwable throwable) {
            auto handler = findHandler(
                exceptionHandlers, pc, throwable.classinfo);
            if (handler is null)
                throw throwable;

            if (handler.catchOffset != size_t.max)
                *cast(void**)(frame + handler.catchOffset) = cast(void*) throwable;
            pc = handler.handler;
        }
    }
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


// Writes `constants[pc.source]`, narrowed to `pc.width` bytes, at
// `frame + pc.destination`.
//
// Not `@nogc nothrow`: dispatching a returned handler can reach `opCall`,
// which can throw (a frame stack overflow) - and the handler alias itself
// is declared without those attributes for exactly that reason, so every
// handler that returns through it, this one included, has to go without
// them too even though nothing this handler itself does allocates or
// throws.
public const(Instruction)* opConstant(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    storeWidth(frame + pc.destination, constants[pc.source], pc.width);
    const next = pc + 1;
    return next;
}


// Copies `pc.width` bytes from `frame + pc.source` to `frame +
// pc.destination`: a parameter or local read into another slot, or an
// assignment's right side already evaluated into the target's own slot
// copied out to wherever the assignment's value is also needed. Not
// `@nogc nothrow`; see `opConstant`.
package const(Instruction)* opCopy(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    memcpy(frame + pc.destination, frame + pc.source, pc.width);
    const next = pc + 1;
    return next;
}


// Constant lengths let the native compiler inline copies without requiring
// aligned frame slots or typed pointer access.
package const(Instruction)* opCopyFixed(size_t width, bool staticSource = false)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    static if (staticSource)
        const source = cast(const(void)*) pc.source;
    else
        const source = frame + pc.source;
    memcpy(frame + pc.destination, source, width);
    return pc + 1;
}


// Persistent storage can belong to a constant or a data-segment variable.
package const(Instruction)* opStaticLoad(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    memcpy(frame + pc.destination, cast(const(void)*) pc.source, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


package const(Instruction)* opStaticStore(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    memcpy(cast(void*) pc.destination, frame + pc.source, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// Writes the address of a function-local static into the current frame.
// The address remains stable for the lifetime of the compiled function and
// is used by native druntime calls such as array append.
package const(Instruction)* opStaticAddress(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    *cast(void**) (frame + pc.destination) = cast(void*) pc.source;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// `assert(cond)`: when the `pc.width` bytes at `frame + pc.destination` are
// nonzero, execution just continues. Otherwise this throws a real
// `AssertError` - the same `Throwable` compiled D throws for a failing
// assertion - built from `assertSites[pc.source]`, so a guest catch or an
// unhandled failure both see the genuine object, never a second exception
// type standing in for it. Each `opCall` this throw unwinds through pops
// its own callee `Frame` via that struct's destructor (see
// `snakebite.framestack`), so no explicit cleanup is needed here.
package const(Instruction)* opAssert(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    if (loadUnsigned(frame + pc.destination, pc.width) != 0)
        return advance(pc, frame, returnPlace, constants, callSites,
            assertSites, frames);

    import core.exception: AssertError;

    const site = assertSites[pc.source];
    throw new AssertError(site.message, site.file, site.line);
}


// Throws the Throwable reference at `pc.destination`. The expression has
// already been evaluated into the frame, so this preserves the original
// object while dispatch unwinds through guest catch handlers and frames.
package const(Instruction)* opThrow(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto throwable = cast(Throwable) *cast(void**) (frame + pc.destination);
    throw throwable;
}


// Calls `callSites[pc.source]`'s callee, one of the three `CallSite.Kind`s:
// a guest callee already compiled to `Instruction`s, a native one reached
// through a prepared FFI plan, or an indirect one whose own address sits
// in the caller's frame. `pc.width` is unused.
public const(Instruction)* opCall(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    const site = callSites[pc.source];
    final switch (site.kind) with (CallSite.Kind) {
        case guest:
            return callFunction(pc, frame, site, site.callee, frames);
        case indirect:
            auto callee =
                *cast(const(Function)**) (frame + site.calleeSlotOffset);
            return callFunction(pc, frame, site, callee, frames);
        case native:
            const(void)*[maxArguments] arguments;
            foreach (i, arg; site.args)
                arguments[i] = frame + arg.callerOffset;
            auto result = pc.destination == discardResult
                ? null
                : frame + pc.destination;
            executeCallPlan(
                site.nativePlan, result, arguments.ptr, site.args.length,
            );
            return pc + 1;
    }
}


// `opCall`'s own `guest`/`indirect` arms, once each has found its own
// `callee`: pushes its frame, copies `site.args` into it, and runs it to
// its own return instruction through the nested dispatch loop with
// `frame + pc.destination` as its result slot (unless `pc.destination` is
// `discardResult`).
private const(Instruction)* callFunction(
    const(Instruction)* pc,
    ubyte* frame,
    scope const ref CallSite site,
    const(Function)* callee,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    auto calleeFrame = frames.push(callee.frameSize, callee.frameAlignment);

    foreach (arg; site.args)
        memcpy(
            calleeFrame.base + arg.calleeOffset,
            frame + arg.callerOffset,
            arg.width,
        );

    initializeClosure(callee, calleeFrame.base, frames);

    // The caller frame stays at a fixed address during nested calls.
    // This pointer must stay mutable so the callee can write the result.
    auto returnDestination = pc.destination == discardResult || site.returnWidth == 0
        ? null
        : frame + pc.destination;

    auto calleePc = callee.instructions.ptr;
    dispatch(
        calleePc, calleeFrame.base, returnDestination, callee.constants,
        callee.callSites, callee.assertSites, callee.exceptionHandlers, frames,
    );

    return pc + 1;
}


// Not a call: the concrete override a guest class gives an interface
// method is not at a fixed vtable index the way a class's own virtual
// method is - the same interface method sits at a different index in
// every implementing class's own vtable, and a call site only ever knows
// the interface's own index, never which class it will reach at run time.
// This resolves `frame + pc.source`'s own override through
// `resolveInterfaceMethod` and stores the result at `frame +
// pc.destination`, for `compileVirtualCall`'s interface branch to call
// through the same way it would any other indirect call. `pc.width` is
// the interface's own `methodIndex`; `pc.sourceWidth` is `interfaceInfo`,
// cast to a `size_t` the same way `opStaticLoad`'s own `source` carries a
// resolved address.
public const(Instruction)* opResolveInterfaceMethod(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto object = *cast(void**) (frame + pc.source);
    auto result = resolveInterfaceMethod(
        object, cast(void*) pc.sourceWidth, pc.width);
    *cast(void**) (frame + pc.destination) = result;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// Copies `pc.width` bytes from `frame + pc.source` to `returnPlace` -
// `null` when the caller discarded the result, the same convention every
// backend uses for a call whose value nothing reads. `pc.destination` is
// unused: there is no frame slot on the receiving end, only `returnPlace`.
public const(Instruction)* opReturn(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) @nogc nothrow {
    import core.stdc.string: memcpy;

    if (returnPlace !is null)
        memcpy(returnPlace, frame + pc.source, pc.width);
    return null;
}


public const(Instruction)* opReturnVoid(
    const(Instruction)*,
    ubyte*,
    void*,
    scope const long[],
    scope const CallSite[],
    scope const AssertSite[],
    FrameStack*,
) @nogc nothrow {
    return null;
}


// Unconditionally transfers control to the instruction `pc.destination`
// already names, resolved (see `Instruction.destination`'s own doc) to
// that instruction's address by the compiler before this VM ever runs it.
package const(Instruction)* opJump(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    const target = cast(const(Instruction)*) pc.destination;
    return target;
}


// Transfers control to `pc.source` (resolved the same way `opJump`'s own
// target is) when the `pc.width` bytes at `frame + pc.destination` are all
// zero - an `if` whose condition was false, a loop whose condition no
// longer holds, the left side of a short-circuiting `&&` - and falls
// through to the next instruction otherwise.
package const(Instruction)* opBranchFalse(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    if (loadUnsigned(frame + pc.destination, pc.width) == 0) {
        const target = cast(const(Instruction)*) pc.source;
        return target;
    }

    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}


// As `opBranchFalse`, taking the branch when the tested bytes are instead
// nonzero - the left side of a short-circuiting `||`.
package const(Instruction)* opBranchTrue(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    if (loadUnsigned(frame + pc.destination, pc.width) != 0) {
        const target = cast(const(Instruction)*) pc.source;
        return target;
    }

    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}


// The arithmetic and bitwise opcodes whose bits do not depend on either
// operand's signedness: dmd's usual arithmetic conversions already bring
// both operands to `destination`'s own type before the compiler emits
// one of these, so the low bits `+`, `-`, `*`, `&`, `|`, `^` and `<<`
// leave are the same whichever way the wider intermediate was extended.
// `destination` holds the left operand on entry and the answer on exit;
// `source` holds the right operand, read but not written.
package const(Instruction)* opAdd(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a + b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opSubtract(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a - b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opMultiply(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a * b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

private T applyFloatBinary(string operation, T)(T left, T right)
        @nogc nothrow pure {
    return mixin("left " ~ operation ~ " right");
}

private const(Instruction)* opFloatBinary(string operation)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    if (pc.width == float.sizeof)
        *cast(float*) place = applyFloatBinary!operation(
            *cast(float*) place,
            *cast(const float*) (frame + pc.source),
        );
    else if (pc.width == double.sizeof)
        *cast(double*) place = applyFloatBinary!operation(
            *cast(double*) place,
            *cast(const double*) (frame + pc.source),
        );
    else {
        assert(pc.width == real.sizeof);
        *cast(real*) place = applyFloatBinary!operation(
            *cast(real*) place,
            *cast(const real*) (frame + pc.source),
        );
    }
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package alias opFloatAdd = opFloatBinary!"+";
package alias opFloatSubtract = opFloatBinary!"-";
package alias opFloatMultiply = opFloatBinary!"*";
package alias opFloatDivide = opFloatBinary!"/";
package alias opFloatModulo = opFloatBinary!"%";

package const(Instruction)* opBitAnd(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a & b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opBitOr(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a | b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opBitXor(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a ^ b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opShiftLeft(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a << b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// `>>` on an unsigned left operand, and `>>>` whatever the left operand's
// signedness: both fill the vacated high bits with zero.
package const(Instruction)* opShiftRightLogical(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a >> b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// `>>` on a signed left operand: the vacated high bits copy the sign bit
// down instead, so the left operand is read signed - the one binary
// opcode besides the divisions and comparisons below whose bits depend on
// an operand's signedness, and the only one of those where reading
// `source` signed as well would be wrong: the right operand is a shift
// count, not a value in the left operand's own domain.
package const(Instruction)* opShiftRightArithmetic(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, a >> b, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// Division and modulo, unlike every other binary opcode above, answer
// differently depending on how both operands were read - so unlike those,
// this pair (and their `Unsigned` counterparts below) read `source`
// according to the same signedness as `destination` rather than always
// unsigned. D's own `/` and `%` on `long` already truncate toward zero
// and take the dividend's sign the way this needs, so this opcode is
// nothing more than that operator applied to the widened operands.
package const(Instruction)* opDivideSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadSigned(frame + pc.source, pc.width);
    storeWidth(place, a / b, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opModuloSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadSigned(frame + pc.source, pc.width);
    storeWidth(place, a % b, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opDivideUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a / b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opModuloUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    storeWidth(place, cast(long) (a % b), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}


// The eight relational-comparison opcodes: `destination` holds the left
// operand and `source` the right one on entry, both read at `pc.width`
// with the signedness the opcode's own name commits to, since an
// ordering answers differently depending on it - `uint.max < 1u` is
// false, but the same bits read signed (`-1 < 1`) are true. Only the
// answer's single byte at `destination` is written; the compiler copies
// it out to wherever the `bool` result is actually needed.
package const(Instruction)* opLessThanSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadSigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a < b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opLessThanUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a < b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opLessOrEqualSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadSigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a <= b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opLessOrEqualUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a <= b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opGreaterThanSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadSigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a > b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opGreaterThanUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a > b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opGreaterOrEqualSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadSigned(place, pc.width);
    const b = loadSigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a >= b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

package const(Instruction)* opGreaterOrEqualUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a >= b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// `==`/`!=`: both operands share one type by the time the compiler emits
// either of these, so the same bits compare equal whichever way they are
// read - neither needs a signed and an unsigned form.
package const(Instruction)* opEqual(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a == b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// Integral comparison whose result is used only to choose a control-flow
// target. `sourceWidth` stores the resolved target address; unlike the
// value-producing comparison handlers this does not write a temporary bool.
private const(Instruction)* opCompareBranch(string operation, bool unsigned,
    bool branchWhenTrue)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    static if (unsigned)
        alias load = loadUnsigned;
    else
        alias load = loadSigned;
    const left = load(frame + pc.destination, pc.width);
    const right = load(frame + pc.source, pc.width);
    const result = mixin("left " ~ operation ~ " right");
    if (result == branchWhenTrue)
        return cast(const(Instruction)*) pc.sourceWidth;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
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
package const(Instruction)* opArrayEqual(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcmp;

    const left = *cast(const(void)[]*) (frame + pc.destination);
    const right = *cast(const(void)[]*) (frame + pc.source);
    const byteLength = left.length * pc.width;
    const equal = left.length == right.length
        && (byteLength == 0 || memcmp(left.ptr, right.ptr, byteLength) == 0);
    *cast(ubyte*) (frame + pc.destination) = equal ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

// Bytewise equality for two native static-array values, laid out in place
// in the frame with no length/pointer header of their own - unlike
// `opArrayEqual`'s dynamic arrays, `destination` and `source` already are
// the arrays' own bytes, not a `{length, pointer}` pair pointing at them.
// `width` is the whole array's own byte size, every element's bytes
// together, since a static array's dimension is part of its type rather
// than a run-time value to compare separately.
package const(Instruction)* opStaticArrayEqual(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcmp;

    const equal = pc.width == 0
        || memcmp(frame + pc.destination, frame + pc.source, pc.width) == 0;
    *cast(ubyte*) (frame + pc.destination) = equal ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package const(Instruction)* opNotEqual(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    const b = loadUnsigned(frame + pc.source, pc.width);
    *cast(ubyte*) place = (a != b) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// Floating comparisons read values in their declared precision instead of
// reusing integral bit comparisons. This preserves IEEE 754 equality for
// NaN and signed zero and gives ordering the host's floating semantics.
private bool applyFloatComparison(string operation, T)(T left, T right)
        @nogc nothrow pure {
    return mixin("left " ~ operation ~ " right");
}

private const(Instruction)* opFloatComparison(string operation)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    bool result;
    if (pc.width == float.sizeof)
        result = applyFloatComparison!operation(
            *cast(float*) place,
            *cast(const float*) (frame + pc.source),
        );
    else if (pc.width == double.sizeof)
        result = applyFloatComparison!operation(
            *cast(double*) place,
            *cast(const double*) (frame + pc.source),
        );
    else {
        assert(pc.width == real.sizeof);
        result = applyFloatComparison!operation(
            *cast(real*) place,
            *cast(const real*) (frame + pc.source),
        );
    }
    *cast(ubyte*) place = result ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
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
package const(Instruction)* opNegate(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    storeWidth(place, cast(long) (-a), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

private T applyFloatUnary(string operation, T)(T value) @nogc nothrow pure {
    return mixin(operation ~ "value");
}

private const(Instruction)* opFloatUnary(string operation)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    if (pc.width == float.sizeof)
        *cast(float*) place = applyFloatUnary!operation(*cast(float*) place);
    else if (pc.width == double.sizeof)
        *cast(double*) place =
            applyFloatUnary!operation(*cast(double*) place);
    else {
        assert(pc.width == real.sizeof);
        *cast(real*) place = applyFloatUnary!operation(*cast(real*) place);
    }
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package alias opFloatNegate = opFloatUnary!"-";

package const(Instruction)* opComplement(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    storeWidth(place, cast(long) (~a), pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// `!x`: true when `x` is zero. `destination` holds the operand, at
// `pc.width`, on entry and the single-byte `bool` answer on exit.
package const(Instruction)* opLogicalNot(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    *cast(ubyte*) place = (a == 0) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// `cast(bool) x`: true when `x` is nonzero - dmd classifies `bool` as an
// integral type, so a plain narrowing copy of the operand's low byte would
// answer wrongly for an operand like `256`, whose low byte is zero.
package const(Instruction)* opCastToBool(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const a = loadUnsigned(place, pc.width);
    *cast(ubyte*) place = (a != 0) ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// Widens the `pc.source`-byte operand already at `destination` to fill
// `pc.width` bytes there instead, copying the sign bit into the new high
// bits. A narrowing cast needs no opcode of its own: on this VM's
// little-endian host, the low bytes of any stored integral already are
// its truncation to a narrower width, so the compiler reaches for
// `opCopy` instead. Reinterpreting a same-width operand as a differently
// signed one changes no bits at all, so the compiler does not even emit
// a copy for that.
package const(Instruction)* opCastWidenSigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const value = loadSigned(place, pc.source);
    storeWidth(place, value, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

// As `opCastWidenSigned`, filling the new high bits with zero instead.
package const(Instruction)* opCastWidenUnsigned(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const value = loadUnsigned(place, pc.source);
    storeWidth(place, cast(long) value, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites, assertSites, frames);
}

private void storeFloating(T)(void* place, in T value, in size_t width)
        @nogc nothrow {
    if (width == float.sizeof)
        *cast(float*) place = cast(float) value;
    else if (width == double.sizeof)
        *cast(double*) place = cast(double) value;
    else {
        assert(width == real.sizeof);
        *cast(real*) place = value;
    }
}

// Returns `real` rather than `double`, wide enough to carry a `real`
// source's own precision without narrowing it first - `float` and
// `double` both widen to `real` exactly, so the one return type serves
// every source width.
private real loadFloating(const(void)* place, in size_t width)
        @nogc nothrow {
    if (width == float.sizeof)
        return *cast(const float*) place;
    if (width == double.sizeof)
        return *cast(const double*) place;

    assert(width == real.sizeof);
    return *cast(const real*) place;
}

private const(Instruction)* opIntegralToFloat(bool unsigned_)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    static if (unsigned_)
        const value = loadUnsigned(frame + pc.source, pc.sourceWidth);
    else
        const value = loadSigned(frame + pc.source, pc.sourceWidth);
    storeFloating(frame + pc.destination, value, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package alias opIntegralToFloatSigned = opIntegralToFloat!false;
package alias opIntegralToFloatUnsigned = opIntegralToFloat!true;

private const(Instruction)* opFloatToIntegral(bool unsigned_)(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    const value = loadFloating(frame + pc.source, pc.sourceWidth);
    static if (unsigned_)
        const converted = cast(long) cast(ulong) value;
    else
        const converted = cast(long) value;
    storeWidth(frame + pc.destination, converted, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package alias opFloatToIntegralSigned = opFloatToIntegral!false;
package alias opFloatToIntegralUnsigned = opFloatToIntegral!true;

package const(Instruction)* opFloatWidthCast(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    const value = loadFloating(frame + pc.source, pc.sourceWidth);
    storeFloating(frame + pc.destination, value, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// Reads `pc.width` bytes from the address held at `frame + pc.source` -
// a dynamic array's element, at an address the compiler computed from its
// pointer word and an index - and writes them to `frame + pc.destination`.
package const(Instruction)* opLoadIndirect(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    auto address = *cast(void**) (frame + pc.source);
    memcpy(frame + pc.destination, address, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package const(Instruction)* opLoadBitfield(
    const(Instruction)* pc, ubyte* frame, void* returnPlace,
    scope const long[] constants, scope const CallSite[] callSites,
    scope const AssertSite[] assertSites, FrameStack* frames,
) {
    auto address = *cast(void**) (frame + pc.source);
    const metadata = pc.sourceWidth;
    const bitOffset = metadata & 0xffff;
    const fieldWidth = (metadata >> 16) & 0xffff;
    const resultWidth = (metadata >> 40) & 0xff;
    const isSigned = (metadata & (1UL << 32)) != 0;
    const storage = loadUnsigned(address, pc.width);
    const mask = ulong.max >> (64 - fieldWidth);
    ulong value = (storage >> bitOffset) & mask;
    if (isSigned && fieldWidth < 64 && (value & (1UL << (fieldWidth - 1))))
        value |= ulong.max << fieldWidth;
    storeWidth(frame + pc.destination, cast(long) value, resultWidth);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// Writes `frame + pc.source` itself - not the bytes stored there, the
// address of that slot - to `frame + pc.destination`, always `size_t.sizeof`
// bytes: the one place this VM turns a frame slot into a value a `ref`
// binding, a `~=`'s `ref` argument to druntime, or a `ref` return can carry
// around and dereference later through `opLoadIndirect`/`opStoreIndirect`.
package const(Instruction)* opFrameAddress(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    *cast(void**) (frame + pc.destination) = frame + pc.source;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

// Zeroes `pc.width` bytes at `frame + pc.destination` - a zero-init struct
// local or array element wider than the 8 bytes `opConstant`'s `storeWidth`
// lays out, the only width this VM's integral opcodes cannot already carry
// as a single constant.
package const(Instruction)* opZero(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memset;

    memset(frame + pc.destination, 0, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// As `opLoadIndirect`, the other way: writes `pc.width` bytes from `frame +
// pc.source` to the address held at `frame + pc.destination`.
package const(Instruction)* opStoreIndirect(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    auto address = *cast(void**) (frame + pc.destination);
    memcpy(address, frame + pc.source, pc.width);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package const(Instruction)* opStoreBitfield(
    const(Instruction)* pc, ubyte* frame, void* returnPlace,
    scope const long[] constants, scope const CallSite[] callSites,
    scope const AssertSite[] assertSites, FrameStack* frames,
) {
    auto address = *cast(void**) (frame + pc.destination);
    const metadata = pc.sourceWidth;
    const bitOffset = metadata & 0xffff;
    const fieldWidth = (metadata >> 16) & 0xffff;
    auto value = loadUnsigned(frame + pc.source, pc.width);
    const mask = (ulong.max >> (64 - fieldWidth)) << bitOffset;
    auto storage = loadUnsigned(address, (metadata >> 40) & 0xff);
    storage = (storage & ~mask) | ((value << bitOffset) & mask);
    storeWidth(address, cast(long) storage, (metadata >> 40) & 0xff);
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// `dest[] = src[]`, `{length, pointer}` pairs at `frame + pc.destination`
// and `frame + pc.source`, with `pc.width` the element size baked in at
// compile time (both sides share one element size - the compiler checked
// that before emitting this). The two lengths are trusted equal - the
// compiler emits a conditional call to druntime's own bounds hook
// immediately before this, the same way it already guards a run-time
// slice's own bounds - so only `dest`'s own pointer, not its length, is
// read here.
//
// The one opcode a plain-element slice assignment ever reaches for its
// own copy: dmd's own semantic pass rewrites an assignment whose element
// type has a postblit or destructor into a call to
// `_d_arrayassign_l`/`_d_arrayassign_r` before this compiler ever sees it
// (`expressionsem.d`'s `lowerArrayAssign`), so every element this opcode
// ever copies is plain bytes - exactly what `_d_newclassT`'s own
// `p[0 .. init.length] = init[];` (`core/lifetime.d`) needs, since a
// class's `.init` image is `void[]`, and what a real compiled `a[] =
// b[]` between two `int[]` locals needs too.
package const(Instruction)* opSliceCopy(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;
    import snakebite.nativevalue: arrayLengthOffset, arrayPointerOffset;

    auto dest = frame + pc.destination;
    auto src = frame + pc.source;
    const length = *cast(const(size_t)*) (src + arrayLengthOffset);
    auto destPtr = *cast(void**) (dest + arrayPointerOffset);
    auto srcPtr = *cast(const(void)**) (src + arrayPointerOffset);
    if (length != 0)
        memcpy(destPtr, srcPtr, length * pc.width);

    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


// `p[a .. b] = v;`/`a[] = v;` for a dynamic-length target and a scalar
// right side (`v` is a single element, not an array): the run-time
// counterpart to `compileSliceAssign`'s own compile-time-unrolled fill
// loop for a static array, whose element count is not known until the
// program runs here. `v`'s bytes (`pc.width` wide, at `frame +
// pc.source`) are copied into every element of the `{length, pointer}`
// pair at `frame + pc.destination`.
package const(Instruction)* opSliceFill(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;
    import snakebite.nativevalue: arrayLengthOffset, arrayPointerOffset;

    auto dest = frame + pc.destination;
    auto value = frame + pc.source;
    const length = *cast(const(size_t)*) (dest + arrayLengthOffset);
    auto destPtr = *cast(ubyte**) (dest + arrayPointerOffset);
    foreach (_; 0 .. length) {
        memcpy(destPtr, value, pc.width);
        destPtr += pc.width;
    }

    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}
