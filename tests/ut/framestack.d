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
private void pushAlignmentAbovePage() @system {
    import core.memory: pageSize;

    auto stack = FrameStack(1024);
    cast(void) stack.push(4, cast(uint) pageSize * 2);
}


@("push.alignmentAbovePage")
unittest {
    import core.memory: pageSize;
    import std.conv: text;

    const alignment = cast(uint) pageSize * 2;

    // The reservation is page-aligned, so a larger alignment could return
    // a pointer outside the reserved range.
    pushAlignmentAbovePage.shouldThrowWithMessage(
        text("frame stack cannot honor a ", alignment,
            "-byte alignment: the backing buffer is page-aligned"));
}


private void pushBeyondCapacity() @system {
    auto stack = FrameStack(4, 4);
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


@("push.growsWithoutMoving")
unittest {
    import core.memory: pageSize;

    auto stack = FrameStack(1, pageSize * 2);
    auto outer = stack.push(1, 1);
    auto address = outer.base;
    auto inner = stack.push(pageSize, 1);

    (outer.base == address).should == true;
}


@("push.zeroSize")
unittest {
    auto stack = FrameStack(16);

    // A parameterless guest function has no frame bytes to reserve.
    auto frame = stack.push(0, 1);
    (frame.base is null).should == true;
}
