module snakebite.backends.bytecode.vm;


private:


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
}


// `opCall`'s own `pc.destination` operand, when the caller has nowhere for
// the call's result to go - a `void` callee, or a non-`void` one run at
// statement level for its effects alone. Not a byte offset any frame ever
// has, so it cannot collide with one: `_tempSize`/`layout.size` never grow
// past a compiled function's own frame size, which stays far short of
// `size_t.max`.
package enum discardResult = size_t.max;


package struct Instruction {
    public alias Handler = extern(C) void function(
        const(Instruction)* pc,
        ubyte* frame,
        void* returnPlace,
        scope const long[] constants,
        scope const CallSite[] callSites,
        FrameStack* frames,
    );

    package Handler handler;
    // `destination` and `source` are frame offsets for `opCopy`/`opReturn`
    // - `source` is the constant or call-site index instead for
    // `opConstant`/`opCall`, which have no frame offset to read a value's
    // identity from. `width` is the byte count `storeWidth`/`memcpy` moves.
    // Never dmd's own numeric types, whichever role a field plays - so this
    // VM has none of them to import. `0` means an opcode does not use a
    // given field, the same way `width` is already unused by `opCall`
    // (the width to copy out lives on its `CallSite` instead) and by
    // `opReturnVoid`.
    package size_t destination;
    package size_t source;
    package size_t width;
}


package struct Function {
    package Instruction[] instructions;
    package long[] constants;
    package CallSite[] callSites;
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
        pc.handler(
            pc, frame.base, returnPlace, function_.constants,
            function_.callSites, &_frames,
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


// Writes `constants[pc.source]`, narrowed to `pc.width` bytes, at
// `frame + pc.destination`.
//
// Not `@nogc nothrow`: a tail call through `Instruction.Handler` can reach
// `opCall`, which can throw (a frame stack overflow) - and the handler
// alias itself is declared without those attributes for exactly that
// reason, so every handler that tail-calls through it, this one included,
// has to go without them too even though nothing this handler itself does
// allocates or throws.
package extern(C) void opConstant(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    FrameStack* frames,
) {
    storeWidth(frame + pc.destination, constants[pc.source], pc.width);
    const next = pc + 1;
    next.handler(next, frame, returnPlace, constants, callSites, frames);
}


// Copies `pc.width` bytes from `frame + pc.source` to `frame +
// pc.destination`: a parameter or local read into another slot, or an
// assignment's right side already evaluated into the target's own slot
// copied out to wherever the assignment's value is also needed. Not
// `@nogc nothrow`; see `opConstant`.
package extern(C) void opCopy(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    memcpy(frame + pc.destination, frame + pc.source, pc.width);
    const next = pc + 1;
    next.handler(next, frame, returnPlace, constants, callSites, frames);
}


// Calls `callSites[pc.source]`'s callee: pushes its frame, copies each
// argument in, runs it to its own return instruction - a plain (recursive)
// call, not a tail one, so control comes back here once the callee's own
// `opReturn`/`opReturnVoid` stops instead of chaining to a next
// instruction of its own - copies the result to `frame + pc.destination`
// (unless `pc.destination` is `discardResult`), and only then tail-calls
// this call's own next instruction. `pc.width` is unused: the width to
// copy out comes from the call site's own `returnWidth` instead.
package extern(C) void opCall(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    FrameStack* frames,
) {
    import core.stdc.string: memcpy;

    const site = callSites[pc.source];
    auto callee = site.callee;

    auto calleeFrame = frames.push(callee.frameSize, callee.frameAlignment);

    foreach (arg; site.args)
        memcpy(
            calleeFrame.base + arg.calleeOffset,
            frame + arg.callerOffset,
            arg.width,
        );

    // Sized for the widest integral this VM lays out - a scratch return
    // buffer that outlives the callee's own frame, unlike one carved from
    // it, since `opCall` reads back out of it after `calleeFrame` has
    // already popped.
    ubyte[8] returnScratch = void;
    void* returnDestination = site.returnWidth == 0 ? null : returnScratch.ptr;

    auto calleePc = callee.instructions.ptr;
    calleePc.handler(
        calleePc, calleeFrame.base, returnDestination, callee.constants,
        callee.callSites, frames,
    );

    if (pc.destination != discardResult && site.returnWidth != 0)
        memcpy(frame + pc.destination, returnScratch.ptr, site.returnWidth);

    const next = pc + 1;
    next.handler(next, frame, returnPlace, constants, callSites, frames);
}


// Copies `pc.width` bytes from `frame + pc.source` to `returnPlace` -
// `null` when the caller discarded the result, the same convention every
// backend uses for a call whose value nothing reads. `pc.destination` is
// unused: there is no frame slot on the receiving end, only `returnPlace`.
package extern(C) void opReturn(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const long[] constants,
    scope const CallSite[] callSites,
    FrameStack* frames,
) @nogc nothrow {
    import core.stdc.string: memcpy;

    if (returnPlace !is null)
        memcpy(returnPlace, frame + pc.source, pc.width);
}


package extern(C) void opReturnVoid(
    const(Instruction)*,
    ubyte*,
    void*,
    scope const long[],
    scope const CallSite[],
    FrameStack*,
) @nogc nothrow {
}
