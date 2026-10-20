module snakebite.backends.interpreter.faultslot;

// A guest call's frame has a word in front of its base that names the full
// expression the call runs, so that a guest fault reports its source line.
// A tree node stores into it at a fixed offset from the frame pointer it
// already holds, and the fault handler reads the word of the running call.
// Each call has its own word, so threads and nested calls never share one.
// The word in front of it is the result word of the call (`resultWordOf`).

private:

import snakebite.framestack: FrameStack;

public enum faultSlotBytes = (const(void)*).sizeof;

// The word of the call whose frame starts at `frame`.
public const(void)** faultSlotOf(ubyte* frame) @system @nogc nothrow pure {
    return cast(const(void)**) (frame - faultSlotBytes);
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
