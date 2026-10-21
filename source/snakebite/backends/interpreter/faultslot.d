module snakebite.backends.interpreter.faultslot;

// A guest call's frame has a word in front of its base, the fault slot, that
// names the function and the full expression the call runs, so that a guest
// fault reports its function and source line. A tree node stores into it at
// a fixed offset from the frame pointer it already holds, and the fault
// handler reads the slot of the running call. Each call has its own slot, so
// threads and nested calls never share one. The word in front of it is the
// result word of the call (`resultWordOf`).

private:

import snakebite.framestack: FrameStack;

public enum faultSlotBytes = (const(void)*).sizeof;

// The fault slot of the call whose frame starts at `frame`. It holds one
// of:
// - a `FaultSite` that `siteWord` tagged: a call node writes the entry site
//   of its callee (the function, no expression), and a tree statement
//   writes its own site before it runs;
// - an untagged full expression, which the original evaluator writes; the
//   function is the evaluator's `_function`, which names the call that ran
//   the evaluator (`syncTree`, `executeRaw`);
// - null: no expression yet, and the function is `_function`.
public const(void)** faultSlotOf(ubyte* frame) @system @nogc nothrow pure {
    return cast(const(void)**) (frame - faultSlotBytes);
}

// A function and the full expression in it that runs, or none.
public struct FaultSite {
    import dmd.func: FuncDeclaration;

    public FuncDeclaration function_;
    public const(void)* expression;
}

// The word of a fault slot that names `site`: its address with bit 0 set,
// which no expression has.
public const(void)* siteWord(const(FaultSite)* site) @trusted @nogc nothrow pure {
    return cast(const(void)*) (cast(size_t) site | 1);
}

// The site that the word of a fault slot names, or null when the word is
// untagged.
public const(FaultSite)* siteOf(const(void)* word) @trusted @nogc nothrow pure {
    const bits = cast(size_t) word;
    return bits & 1 ? cast(const(FaultSite)*) (bits & ~size_t(1)) : null;
}

// What the result word of a call holds. It is decided once for each
// function, by the type of its result (`resultWordFor`), and every entry
// of a call keeps the same rule:
// - `value`: a scalar result by value. The callee writes the value in the
//   word before it returns, extended to 64 bits: an integer by its
//   signedness, a `float` or a `double` as its bits with zeros above them.
//   The original evaluator writes only the bytes of the type, through
//   `_place`, which is then the address of the word, and the call extends
//   the word when it ends (`TreeRoot.extendResult`). The caller loads the
//   word when the call has returned.
// - `place`: any other result: a slice, a struct, a static array, a `ref`
//   result, a delegate. Before the body runs, the caller writes in the word
//   the address where the callee writes the result, or null when the caller
//   discards it. The callee reads the word.
// - `none`: no result. The callee neither reads nor writes the word.
// A caller can write an address or null in the word of any call: only the
// callee of a `place` call reads it.
public enum ResultWord : ubyte { none, value, place }

// The result word of the call whose frame starts at `frame`.
public ulong* resultWordOf(ubyte* frame) @system @nogc nothrow pure {
    return cast(ulong*) (frame - 2 * faultSlotBytes);
}

// The address that the result word of a `place` call holds.
public void** resultPlaceOf(ubyte* frame) @system @nogc nothrow pure {
    return cast(void**) resultWordOf(frame);
}

// The lead of every frame whose alignment is no more than this: a call
// node reserves such a frame with no computation.
public enum uint fastFrameLead = 16;
static assert(fastFrameLead >= 2 * faultSlotBytes);

// The bytes between the start of a reservation and the frame base: room for
// the two words, and a whole alignment unit so the base keeps `alignment`.
public size_t frameLead(in size_t alignment) @safe @nogc nothrow pure {
    return alignment > fastFrameLead ? alignment : fastFrameLead;
}

// A guest call's frame of `size` bytes: its word names no expression yet.
public FrameStack.Frame pushCallFrame(
    ref FrameStack frames, in size_t size, in uint alignment,
) @system {
    const lead = frameLead(alignment);
    auto frame = frames.push(size + lead, cast(uint) lead);
    frame.base += lead;
    *faultSlotOf(frame.base) = null;
    return frame;
}
