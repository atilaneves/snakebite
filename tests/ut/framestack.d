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

    // A parameterless guest function has no frame bytes to reserve, but
    // it still has a frame: compiled D always has a context address for
    // a nested function to point at, even an empty one. A push after it
    // must not be moved by bytes that were never reserved.
    auto frame = stack.push(0, 1);
    (frame.base is null).should == false;

    auto next = stack.push(1, 1);
    (next.base == frame.base).should == true;
}


// A guest reference already written into the committed part of the
// frame stack must stay visible to the collector while `push` commits
// more pages for a later reservation. `commit` used to unregister the
// whole committed range and then register the grown one back
// (`GC.removeRange` then `GC.addRange`), so a collection that ran
// between those two calls saw no range there at all and could free a
// guest object this thread's own frame stack was still the only root
// for. This drives many grow points next to a thread that never stops
// collecting, so that window - if it were still open - loses the race
// against this test almost every run instead of two in twenty full
// suites (finding for issue #40).
private void growSurvivesConcurrentCollection() @system {
    import core.memory: GC, pageSize;
    import core.atomic: atomicLoad, atomicStore, atomicOp;
    import core.thread: Thread;
    import core.time: MonoTime, seconds;
    import ut.threadsync: beginExplicitCollect, endExplicitCollect;

    static final class Box {
        int value;
        this(int value) { this.value = value; }
    }

    // The collector loop must stay bounded on its own, with no wait
    // and no pause between calls: its job is to run `GC.collect` as
    // many times as it can while the main loop below grows a frame
    // stack. Without a cap, this loop used to run for as long as the
    // rest of the whole test binary took, which is why one test could
    // cost minutes: every `GC.collect` here stops every thread in the
    // process, not only this one, and a slower process (kcov, a busy
    // machine) does not make the loop do less work, it makes each
    // collection more expensive while the loop keeps running just as
    // long (issue #40 review, finding 1). Two independent caps close
    // that off: `maxCollections` is well above what 50 grow points
    // need to catch the bug most runs, and `deadline` is a hard wall
    // -clock ceiling on this test's own cost that holds even when a
    // single collection itself is slow, which a count alone cannot
    // promise.
    enum maxCollections = 20;
    enum deadline = 2.seconds;
    shared bool stop = false;
    shared uint collections = 0;
    const started = MonoTime.currTime;
    // Each `GC.collect` is gated through `ut.threadsync` so it never
    // overlaps a foreign thread's attach in a wholly different test
    // unit-threaded happens to run at the same time (a druntime bug,
    // not one of this test's own - see ADR-0006's "Known
    // limitation"). The gate is taken once per collection, not once
    // for the whole loop, so a foreign attach only ever waits between
    // collections, never for the full two seconds.
    auto collector = new Thread({
        while (!atomicLoad(stop) && atomicLoad(collections) < maxCollections
                && MonoTime.currTime - started < deadline) {
            beginExplicitCollect();
            GC.collect();
            endExplicitCollect();
            atomicOp!"+="(collections, 1);
        }
    });
    collector.start;
    scope(exit) {
        atomicStore(stop, true);
        collector.join;
    }

    enum iterations = 50;
    foreach (i; 0 .. iterations) {
        auto stack = FrameStack(pageSize, pageSize * 64);

        // The frame stack ends up the only root: the local `box`
        // handle is cleared right after the pointer is copied into
        // frame storage, the same way a guest local's only copy can
        // live in a pushed frame.
        auto box = new Box(41);
        auto slot = stack.push(Box.sizeof, Box.alignof);
        *cast(Box*) slot.base = box;
        box = null;

        // Commits more pages than the initial capacity, so this is a
        // real grow, not a no-op.
        auto grown = stack.push(pageSize * 4, 1);

        // Encourage the allocator to reuse a freed slot's memory
        // immediately, so a premature collection shows up as a wrong
        // value here rather than as leftover bytes that happen to
        // still read back correctly.
        foreach (_; 0 .. 4)
            cast(void) new Box(-1);

        (*cast(Box*) slot.base).value.should == 41;
    }
}


@("push.growSurvivesConcurrentCollection")
@Serial
unittest {
    growSurvivesConcurrentCollection;
}
