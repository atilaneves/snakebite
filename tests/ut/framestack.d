module ut.framestack;


import ut;
import snakebite.framestack: FrameStack;


// `push`'s return value is a non-copyable `Frame` that frees its bytes in
// its own destructor, which is not `@safe` - `shouldThrowWithMessage`
// evaluates its argument inside a `@safe` wrapper when it can, and a
// `Frame` temporary discarded there would need to destroy itself under
// that wrapper. Routing the call through an explicitly `@system`,
// void-returning function sidesteps that: nothing crosses back out for
// `shouldThrowWithMessage` to destroy.
private void pushAlignmentAboveMallocator() @system {
    import std.experimental.allocator.mallocator: Mallocator;

    auto stack = FrameStack(1024);
    cast(void) stack.push(4, cast(uint) Mallocator.alignment * 2);
}


@("push.alignmentAboveMallocator")
unittest {
    import std.experimental.allocator.mallocator: Mallocator;
    import std.conv: text;

    const alignment = cast(uint) Mallocator.alignment * 2;

    // The backing buffer is only ever aligned to `Mallocator.alignment`;
    // a request beyond that could not be honored, so `push` refuses it
    // instead of silently handing back a misaligned slot.
    pushAlignmentAboveMallocator.shouldThrowWithMessage(
        text("frame stack cannot honor a ", alignment,
            "-byte alignment: the backing buffer is only aligned to ",
            Mallocator.alignment, " byte(s)"));
}


private void pushBeyondCapacity() @system {
    auto stack = FrameStack(4);
    cast(void) stack.push(100, 1);
}


@("push.overflow")
unittest {
    // A reservation bigger than the whole backing buffer can never fit,
    // no matter how empty the stack is.
    pushBeyondCapacity.shouldThrowWithMessage(
        "frame stack overflow: need 100 byte(s) at "
        ~ "offset 0 of 4");
}


@("push.zeroSize")
unittest {
    auto stack = FrameStack(16);

    // `Region.allocate(0)` treats a zero-size request as a failed one,
    // not an empty reservation - the shape every no-argument guest
    // function's frame takes. `push` special-cases it so that call still
    // gets a `Frame` back, one whose `base` nothing will dereference,
    // instead of `push` reporting an overflow that never happened.
    auto frame = stack.push(0, 1);
    (frame.base is null).should == true;
}
