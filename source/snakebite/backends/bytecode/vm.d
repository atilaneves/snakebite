module snakebite.backends.bytecode.vm;


private:


extern(C) void executeCallPlan(
    const(void)* opaquePlan,
    void* returnPlace,
    scope const(void*)* arguments,
    size_t argumentCount,
);

import snakebite.ffi.limits: maxArguments;


// One argument a call instruction copies from the caller's frame into the
// callee's, at compile time already resolved to both sides' byte offsets
// and the width to copy - the same three numbers `opCopy` needs for a
// same-frame copy, just crossing into a frame that does not exist yet
// when the call instruction runs.
package struct Arg {
    package size_t callerOffset;
    package size_t calleeOffset;
    package size_t width;
}


// One call site: which compiled function it calls, the arguments to hand
// it, and the width of the value it hands back (`0` for a `void` callee,
// which `opCall` then never copies out of the scratch return buffer).
package struct CallSite {
    package const(Function)* callee;
    package Arg[] args;
    package size_t returnWidth;
    // A declared `extern(C)` guest callee's prepared FFI call, opaque to
    // this module - see `snakebite.ffi.plan.CallPlan`. `null` for a
    // guest-declared function's call site.
    package const(void)* nativePlan;
    // The other native shape `opCall` knows besides a `nativePlan` call: a
    // druntime allocator call the compiler synthesises for `new T[](n)`/an
    // array literal, never one a guest source declaration resolves to.
    // `allocationBits` is the `GC.BlkAttr` value that call's second
    // argument passes, fixed by the compiler once per call site from the
    // element type it already knows, not read from any frame.
    package void* nativeAddress;
    package bool isAllocation;
    package uint allocationBits;
}


// `opCall`'s own `pc.destination` operand, when the caller has nowhere for
// the call's result to go - a `void` callee, or a non-`void` one run at
// statement level for its effects alone. Not a byte offset any frame ever
// has, so it cannot collide with one: `_tempSize`/`layout.size` never grow
// past a compiled function's own frame size, which stays far short of
// `size_t.max`.
package enum discardResult = size_t.max;


package struct Instruction {
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
}


// One `assert` site: the message and source location `opAssert` builds a
// real `AssertError` from when its condition is false, resolved to plain
// strings and a line number at compile time so this VM never has to reach
// into dmd's own `Loc` to answer them.
package struct AssertSite {
    package string message;
    package string file;
    package size_t line;
}


package struct Function {
    package Instruction[] instructions;
    package long[] constants;
    package CallSite[] callSites;
    package AssertSite[] assertSites;
    package size_t frameSize;
    package uint frameAlignment;
}


import snakebite.framestack: FrameStack;

package struct Vm {
    private FrameStack _frames;

    @disable this();
    @disable this(this);

    package this(in size_t frameCapacity) {
        _frames = FrameStack(frameCapacity);
    }

    package void call(
        scope const ref Function function_,
        void* returnPlace,
    ) {
        assert(function_.instructions.length > 0);
        assert(function_.frameAlignment > 0);

        auto frame = _frames.push(
            function_.frameSize,
            function_.frameAlignment,
        );
        auto pc = function_.instructions.ptr;
        dispatch(
            pc, frame.base, returnPlace, function_.constants,
            function_.callSites, function_.assertSites, &_frames,
        );
    }
}


// Stores `value`'s low `width` bytes at `place`, laid out the way compiled
// D lays out an integral of that width. The VM's own copy of what
// `snakebite.nativelayout.storeIntegral` does: that module reaches into
// dmd for `TypeFacts`/`storeValue`, and importing it here would pull dmd
// frontend modules into a module that must compile without them. Widths
// are the only numeric fact this VM ever receives, from the compiler that
// already asked dmd the question - never a dmd `Type` itself.
private void storeWidth(
    void* place,
    in long value,
    in size_t width,
) @nogc nothrow {
    switch (width) {
        case 1: *cast(ubyte*) place = cast(ubyte) value; return;
        case 2: *cast(ushort*) place = cast(ushort) value; return;
        case 4: *cast(uint*) place = cast(uint) value; return;
        case 8: *cast(ulong*) place = cast(ulong) value; return;
        default: assert(0, "no native layout for this width");
    }
}


// Reads `width` bytes at `place`, laid out the way compiled D lays out an
// integral of that width, widened to 64 bits with the sign bit copied
// down. The VM's own copy of what `snakebite.nativelayout.loadIntegral`
// does for a signed operand, kept here for the same reason `storeWidth`
// is: that module reaches into dmd, and this one must not.
private long loadSigned(const(void)* place, in size_t width) @nogc nothrow {
    switch (width) {
        case 1: return *cast(const(byte)*) place;
        case 2: return *cast(const(short)*) place;
        case 4: return *cast(const(int)*) place;
        case 8: return *cast(const(long)*) place;
        default: assert(0, "no native layout for this width");
    }
}


// As `loadSigned`, filling the widened bits with zero instead. The
// arithmetic and comparison opcodes below read whichever of the two an
// operator's own signedness calls for - already decided by the compiler,
// which picked this handler over `loadSigned`'s for exactly that reason.
private ulong loadUnsigned(const(void)* place, in size_t width) @nogc nothrow {
    switch (width) {
        case 1: return *cast(const(ubyte)*) place;
        case 2: return *cast(const(ushort)*) place;
        case 4: return *cast(const(uint)*) place;
        case 8: return *cast(const(ulong)*) place;
        default: assert(0, "no native layout for this width");
    }
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
    FrameStack* frames,
) {
    while (pc !is null)
        pc = pc.handler(
            pc, frame, returnPlace, constants, callSites, assertSites, frames);
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
package const(Instruction)* opConstant(
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


// Calls `callSites[pc.source]`'s callee: pushes its frame, copies each
// argument in, runs it to its own return instruction through the nested
// dispatch loop, then copies the result to `frame + pc.destination`
// (unless `pc.destination` is `discardResult`) and returns this call's own
// next instruction. `pc.width` is unused: the width to copy out comes
// from the call site's own `returnWidth` instead.
package const(Instruction)* opCall(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    const site = callSites[pc.source];
    if (site.isAllocation) {
        assert(site.args.length == 1);
        assert(site.returnWidth == (void*).sizeof);
        alias Allocate =
            extern(C) void* function(size_t, uint, const(void)*);
        auto size = *cast(const size_t*) (frame + site.args[0].callerOffset);
        auto block = (cast(Allocate) site.nativeAddress)(
            size, site.allocationBits, null);
        if (pc.destination != discardResult)
            *cast(void**) (frame + pc.destination) = block;
        return pc + 1;
    }
    if (site.nativePlan !is null) {
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
    auto callee = site.callee;

    auto calleeFrame = frames.push(callee.frameSize, callee.frameAlignment);

    foreach (arg; site.args)
        memcpy(
            calleeFrame.base + arg.calleeOffset,
            frame + arg.callerOffset,
            arg.width,
        );

    // Sized for the widest value this VM ever returns - a dynamic array's
    // two words - a scratch return buffer that outlives the callee's own
    // frame, unlike one carved from it, since `opCall` reads back out of
    // it after `calleeFrame` has already popped.
    ubyte[16] returnScratch = void;
    void* returnDestination = site.returnWidth == 0 ? null : returnScratch.ptr;

    auto calleePc = callee.instructions.ptr;
    dispatch(
        calleePc, calleeFrame.base, returnDestination, callee.constants,
        callee.callSites, callee.assertSites, frames,
    );

    if (pc.destination != discardResult && site.returnWidth != 0)
        memcpy(frame + pc.destination, returnScratch.ptr, site.returnWidth);

    const next = pc + 1;
    return next;
}


// Copies `pc.width` bytes from `frame + pc.source` to `returnPlace` -
// `null` when the caller discarded the result, the same convention every
// backend uses for a call whose value nothing reads. `pc.destination` is
// unused: there is no frame slot on the receiving end, only `returnPlace`.
package const(Instruction)* opReturn(
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


package const(Instruction)* opReturnVoid(
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

// `==`/`!=` on `float`/`double`: unlike the integral form above, the same
// bits do not always compare equal to themselves - IEEE 754 makes NaN
// compare unequal to every value, itself included - so this reads both
// operands as the floating type their shared `pc.width` (4 or 8) names and
// lets the host's own float comparison answer, rather than reusing
// `opEqual`/`opNotEqual`'s bit-pattern test.
package const(Instruction)* opFloatEqual(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const result = pc.width == 4
        ? *cast(float*) place == *cast(const float*) (frame + pc.source)
        : *cast(double*) place == *cast(const double*) (frame + pc.source);
    *cast(ubyte*) place = result ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}

package const(Instruction)* opFloatNotEqual(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    scope const AssertSite[] assertSites,
    FrameStack* frames,
) {
    auto place = frame + pc.destination;
    const result = pc.width == 4
        ? *cast(float*) place != *cast(const float*) (frame + pc.source)
        : *cast(double*) place != *cast(const double*) (frame + pc.source);
    *cast(ubyte*) place = result ? 1 : 0;
    return advance(pc, frame, returnPlace, constants, callSites,
        assertSites, frames);
}


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
