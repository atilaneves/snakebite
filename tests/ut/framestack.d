module ut.framestack;


import ut;
import snakebite.framestack: FrameStack;
import core.memory: pageSize;


@("push.alignedAfterOddSizedFrame")
unittest {
    auto stack = FrameStack(1);
    for (uint alignment = 1; alignment <= pageSize; alignment *= 2) {
        auto outer = stack.push(3, 1);
        outer.base[0 .. 3] = 42;
        {
            auto inner = stack.push(alignment, alignment);
            (cast(size_t) inner.base % alignment).should == 0;
            inner.base[0 .. alignment] = 7;
        }
        outer.base[0 .. 3].should == [42, 42, 42];
        auto next = stack.push(1, 1);
        (next.base == outer.base + 3).should == true;
    }
}


@("cleanup.reverseSuccessfulConstruction")
unittest {
    auto stack = FrameStack(16);
    auto outer = stack.push(1, 1);
    auto inner = stack.push(1, 1);
    const mark = stack.cleanupMark;
    size_t[2] order;
    size_t count;

    // The receiver starts before its argument, but it completes after it.
    stack.registerCleanup(1, outer.base);
    stack.suspendCleanup(outer.base);
    stack.registerCleanup(2, inner.base);
    stack.armCleanup(inner.base);
    stack.armCleanup(outer.base);
    stack.finishCleanups(mark, (in size_t site) {
        order[count++] = site;
    });

    order.should == [2, 1];
}


@("cleanup.nestedMarkSkipsFailedConstructor")
unittest {
    auto stack = FrameStack(16);
    auto outer = stack.push(1, 1);
    auto failed = stack.push(1, 1);
    auto inner = stack.push(1, 1);
    size_t[2] order;
    size_t count;

    stack.registerCleanup(1, outer.base);
    stack.armCleanup(outer.base);
    const nestedMark = stack.cleanupMark;
    stack.registerCleanup(2, failed.base);
    stack.suspendCleanup(failed.base);
    stack.finishCleanups(nestedMark, (in size_t site) {
        order[count++] = site;
    });
    count.should == 0;

    stack.registerCleanup(3, inner.base);
    stack.suspendCleanup(inner.base);
    stack.armCleanup(inner.base);
    stack.finishCleanups(nestedMark, (in size_t site) {
        order[count++] = site;
    });
    order[0 .. count].should == [3];

    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
    });
    order.should == [3, 1];
}


@("cleanup.reentrantDestructorKeepsAddressLookup")
unittest {
    auto stack = FrameStack(128);
    auto frame = stack.push(128, 1);
    size_t[102] order;
    size_t count;
    stack.registerCleanup(1, frame.base);
    stack.armCleanup(frame.base);
    stack.registerCleanup(2, frame.base + 1);
    stack.armCleanup(frame.base + 1);
    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
        if (site != 2)
            return;
        const nested = stack.cleanupMark;
        // Reuse an outer address and grow the cleanup storage in a destructor.
        foreach (i; 0 .. 100) {
            stack.registerCleanup(i + 3, frame.base);
            stack.armCleanup(frame.base);
        }
        stack.finishCleanups(nested, (in size_t inner) {
            order[count++] = inner;
        });
    });
    count.should == 102;
    order[0].should == 2;
    foreach (i; 0 .. 100)
        order[i + 1].should == 102 - i;
    order[$ - 1].should == 1;
}


@("cleanup.orderDoesNotChangeRegistrationMarks")
unittest {
    auto stack = FrameStack(16);
    auto frame = stack.push(16, 1);
    size_t[3] order;
    size_t count;
    stack.registerCleanup(1, frame.base);
    const nested = stack.cleanupMark;
    stack.registerCleanup(2, frame.base + 1);
    stack.registerCleanup(3, frame.base + 2);
    stack.armCleanup(frame.base + 2);
    stack.armCleanup(frame.base);
    stack.armCleanup(frame.base + 1);
    stack.finishCleanups(nested, (in size_t site) {
        order[count++] = site;
    });
    order[0 .. count].should == [2, 3];
    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
    });
    order.should == [2, 3, 1];
}


@("cleanup.markKeepsOlderValueWithLaterLifetime")
unittest {
    auto stack = FrameStack(16);
    auto older = stack.push(1, 1);
    auto newer = stack.push(1, 1);
    size_t[2] order;
    size_t count;

    stack.registerCleanup(1, older.base);
    const mark = stack.cleanupMark;
    stack.registerCleanup(2, newer.base);
    stack.armCleanup(newer.base);
    stack.armCleanup(older.base);
    stack.finishCleanups(mark, (in size_t site) {
        order[count++] = site;
    });
    order[0 .. count].should == [2];
    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
    });
    order.should == [2, 1];
}


@("cleanup.destructorCanGrowStackAndFinishNestedMark")
unittest {
    auto stack = FrameStack(256);
    auto storage = stack.push(256, 1);
    size_t[132] order;
    size_t count;

    stack.registerCleanup(1, storage.base);
    stack.armCleanup(storage.base);
    stack.registerCleanup(2, storage.base + 1);
    stack.armCleanup(storage.base + 1);
    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
        if (site != 2)
            return;
        const mark = stack.cleanupMark;
        foreach (i; 0 .. 130) {
            stack.registerCleanup(i + 3, storage.base + i + 2);
            stack.armCleanup(storage.base + i + 2);
        }
        stack.finishCleanups(mark, (in size_t nested) {
            order[count++] = nested;
        });
    });
    count.should == order.length;
    order[0].should == 2;
    foreach (i; 0 .. 130)
        order[i + 1].should == 132 - i;
    order[$ - 1].should == 1;
}


@("cleanup.throwContinuesAfterNestedCleanup")
unittest {
    auto stack = FrameStack(16);
    auto storage = stack.push(3, 1);
    size_t[3] order;
    size_t count;

    stack.registerCleanup(1, storage.base);
    stack.armCleanup(storage.base);
    stack.registerCleanup(2, storage.base + 1);
    stack.armCleanup(storage.base + 1);
    void finish() {
        stack.finishCleanups(0, (in size_t site) {
            order[count++] = site;
            if (site != 2)
                return;
            const mark = stack.cleanupMark;
            stack.registerCleanup(3, storage.base + 2);
            stack.armCleanup(storage.base + 2);
            stack.finishCleanups(mark, (in size_t nested) {
                order[count++] = nested;
            });
            throw new Exception("cleanup");
        });
    }
    finish.shouldThrowWithMessage("cleanup");
    order.should == [2, 3, 1];
    stack.cleanupMark.should == 0;
}


@("cleanup.nestedDestructorPreservesSkippedOlderLifetimes")
unittest {
    auto stack = FrameStack(16);
    auto storage = stack.push(9, 1);
    size_t[12] order;
    size_t count;
    foreach (i; 0 .. 4)
        stack.registerCleanup(i + 1, storage.base + i);
    const mark = stack.cleanupMark;
    foreach (i; 4 .. 8) {
        stack.registerCleanup(i + 1, storage.base + i);
        stack.armCleanup(storage.base + i);
    }
    // These older registrations have later lifetimes, but belong to the
    // enclosing expression, not the expression being finished.
    foreach (i; 0 .. 4)
        stack.armCleanup(storage.base + i);
    stack.finishCleanups(mark, (in size_t site) {
        order[count++] = site;
        const nested = stack.cleanupMark;
        stack.registerCleanup(9, storage.base + 8);
        stack.armCleanup(storage.base + 8);
        stack.finishCleanups(nested, (in size_t inner) {
            order[count++] = inner;
        });
    });
    order[0 .. count].should == [8, 9, 7, 9, 6, 9, 5, 9];
    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
    });
    order.should == [8, 9, 7, 9, 6, 9, 5, 9, 4, 3, 2, 1];
}


@("cleanup.destructorArmsAnEarlierConstructorLifetime")
unittest {
    auto stack = FrameStack(16);
    auto storage = stack.push(3, 1);
    size_t[3] order;
    size_t count;
    stack.registerCleanup(1, storage.base);
    stack.suspendCleanup(storage.base);
    stack.registerCleanup(2, storage.base + 1);
    stack.armCleanup(storage.base + 1);
    stack.registerCleanup(3, storage.base + 2);
    stack.armCleanup(storage.base + 2);
    stack.finishCleanups(0, (in size_t site) {
        order[count++] = site;
        if (site == 3)
            stack.armCleanup(storage.base);
    });
    order.should == [3, 2, 1];
}


@("cleanup.destructorCannotArmItsConsumedNonTailReceiver")
unittest {
    auto stack = FrameStack(16);
    auto storage = stack.push(3, 1);
    size_t[] order;
    foreach (i; 0 .. 3)
        stack.registerCleanup(i + 1, storage.base + i);
    foreach_reverse (i; 0 .. 3) {
        stack.suspendCleanup(storage.base + i);
        stack.armCleanup(storage.base + i);
    }
    stack.finishCleanups(0, (in size_t site) {
        order ~= site;
        if (site == 1) {
            stack.suspendCleanup(storage.base);
            stack.armCleanup(storage.base);
        }
    });
    order.should == [1, 2, 3];
    stack.cleanupMark.should == 0;
}


@("cleanup.destructorsFinishSuccessivelyDeeperExpressions")
unittest {
    enum depth = 256;
    auto stack = FrameStack(depth);
    auto storage = stack.push(depth, 1);
    size_t count;
    void destroy(in size_t site) {
        site.should == ++count;
        if (site == depth)
            return;
        const nested = stack.cleanupMark;
        stack.registerCleanup(site + 1, storage.base + site);
        stack.armCleanup(storage.base + site);
        stack.finishCleanups(nested, &destroy);
    }
    stack.registerCleanup(1, storage.base);
    stack.armCleanup(storage.base);
    stack.finishCleanups(0, &destroy);
    count.should == depth;
    stack.cleanupMark.should == 0;
}


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
unittest {
    growSurvivesConcurrentCollection;
}


@("nativeAlignment.offsetWidth")
unittest {
    import snakebite.nativevalue: alignUp;

    alignUp(3, 0).should == 3;
    alignUp(3, 1).should == 3;
    alignUp(3, 8).should == 8;
    alignUp(8, 8).should == 8;
    alignUp(uint.max, 8).should == 0;
    static if (size_t.sizeof > uint.sizeof) {
        const wide = cast(size_t) uint.max + 4;
        alignUp(wide, 0).should == wide;
        alignUp(wide, 8).should == 8;
    }
}


@("nativeAlignment.compiledFieldOffsets")
unittest {
    import snakebite.nativevalue: alignUp;

    struct Fields {
        ubyte first;
        ushort second;
        double third;
        ubyte last;
    }

    alignUp(Fields.first.offsetof + ubyte.sizeof, ushort.alignof)
        .should == Fields.second.offsetof;
    alignUp(Fields.second.offsetof + ushort.sizeof, double.alignof)
        .should == Fields.third.offsetof;
    alignUp(Fields.third.offsetof + double.sizeof, ubyte.alignof)
        .should == Fields.last.offsetof;
    alignUp(Fields.last.offsetof + ubyte.sizeof, Fields.alignof)
        .should == Fields.sizeof;
}
