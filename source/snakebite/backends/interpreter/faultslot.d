module snakebite.backends.interpreter.faultslot;

// A guest call's frame has a word in front of its base that names the full
// expression the call runs, so that a guest fault reports its source line.
// A tree node stores into it at a fixed offset from the frame pointer it
// already holds, and the fault handler reads the word of the running call.
// Each call has its own word, so threads and nested calls never share one.
// The word in front of it holds where the call's result goes.

private:

import snakebite.framestack: FrameStack;

public enum faultSlotBytes = (const(void)*).sizeof;

// The word of the call whose frame starts at `frame`.
public const(void)** faultSlotOf(ubyte* frame) @system @nogc nothrow pure {
    return cast(const(void)**) (frame - faultSlotBytes);
}

// Where the result of the call whose frame starts at `frame` goes, or null
// when its caller discards it. A call that gives its result in a register
// (`runTreeValue`) never writes the word: its body is one return statement
// that hands the value back, and nothing else reads the word of a frame.
// Every other call writes it before its body runs, and a return statement
// writes through it. A debug build writes `placeNotRead` in the word of a
// call that never writes it, so a store through it faults. Copying the word
// is allowed (`Evaluator.claim` does); using the copy as a place is not.
public void** placeSlotOf(ubyte* frame) @system @nogc nothrow pure {
    return cast(void**) (frame - 2 * faultSlotBytes);
}

// The word of a call that gives its result in a register, in a debug build.
public enum placeNotRead = cast(void*) 1;

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
