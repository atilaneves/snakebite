module ut.frontend.memory;


// The frontend allocates like dmd does: from an arena that is never
// freed and never scanned (`snakebite.gc`). Guest and host code keep
// the GC, exactly like compiled D.


import core.memory: GC;
import core.sync.mutex: Mutex;
import snakebite.frontend.compiler: arenaReport, parseSnippet;
import ut.backends;


// The arena report covers the whole arena, and one test plants a GC
// pointer in it. A test that reads the report, or plants, holds this lock.
private __gshared Mutex arenaReportLock;

shared static this() {
    arenaReportLock = new Mutex;
}


// Fresh declarations and template instances, so dmd does real work
// however much of the frontend earlier tests already filled.
private string manyInstances(in string moduleName) {
    return "module " ~ moduleName ~ ";\n" ~ q{
        import std.algorithm: filter, map, sum;
        import std.conv: text;
        import std.range: iota;
        static foreach (i; 0 .. 200)
            mixin("int f", i, "() { return iota(", i, ")",
                ".map!(x => x * ", i, ").filter!(x => x % 3 == ", i % 3, ")",
                ".sum + cast(int) text(", i, ").length; }");
    };
}


// dmd's `-lowmem` puts the frontend back on the GC; `--lowmem` does the
// same for a snakebite executable.
@("frontendWorkAllocatesFromTheArena")
unittest {
    import snakebite.gc: lowmem;

    const before = GC.allocatedInCurrentThread;
    auto module_ = parseSnippet(manyInstances("frontendWorkAllocatesFromTheArena"));
    const allocated = GC.allocatedInCurrentThread - before;

    if (lowmem) {
        (allocated > 1 << 20).should == true;
        (GC.addrOf(cast(void*) module_) !is null).should == true;
    } else {
        (allocated < 64 << 10).should == true;
        (GC.addrOf(cast(void*) module_) is null).should == true;
    }
}


// The GC never scans the arena, so a GC block that only the arena points
// to would be freed while the AST still uses it.
debug
@("arenaHoldsNoGCPointers.largeImport")
unittest {
    parseSnippet(q{
        module arenaHoldsNoGCPointersLargeImport;
        import std;
        string describe() {
            return iota(10).map!(i => i * 2).filter!(i => i % 3 == 0)
                .format!"%s";
        }
    });

    arenaReportLock.lock;
    scope(exit) arenaReportLock.unlock;
    arenaReport.should == "";
}


// Host code shares Phobos' caches (`std.functional.memoize` behind
// `std.regex.regex`, which the import path search of the frontend's own
// initialization also uses) with the frontend's setup. That setup must not
// leave a cache's storage in the arena: the host then stores GC data in
// it, and no collection looks there.
debug
@("arenaHoldsNoGCPointers.hostLibraryCacheAfterInitialization")
unittest {
    import std.regex: matchFirst, regex;

    const match = matchFirst("snippet_42", regex(`hostCacheProbe\d+|snippet_\d+`));
    match.empty.should == false;

    arenaReportLock.lock;
    scope(exit) arenaReportLock.unlock;
    arenaReport.should == "";
}


// The report finds a GC pointer stored in the arena. `--lowmem` puts the
// identifier itself on the GC heap, so the planted word never lands in
// the arena and the report stays empty; the report only ever names GC
// pointers that the arena holds.
debug
@("arenaHoldsNoGCPointers.reportsAPointerIntoTheGCHeap")
unittest {
    import dmd.identifier: Identifier;
    import snakebite.frontend.compiler: newInFrontend;
    import snakebite.gc: lowmem;

    {
        arenaReportLock.lock;
        scope(exit) arenaReportLock.unlock;
        // An identifier's name is arena memory the test can write a word to.
        auto identifier = newInFrontend!(Identifier.idPool)(
            "reportsAPointerIntoTheGCHeapWithRoomForAWord");
        auto word = cast(void**) identifier.toChars;
        auto block = new ubyte[64];
        auto saved = *word;
        *word = block.ptr;
        scope(exit) *word = saved;

        if (lowmem)
            arenaReport.should == "";
        else
            "1 arena words point into the GC heap".should.be in arenaReport;
    }
}


// A block that druntime allocates NO_SCAN while the frontend runs is arena
// memory that cannot hold a pointer: a word in it that has the value of a
// GC address is data, so the report does not read it. dmd's own line
// tables are such blocks (`uint[]`). `--lowmem` puts the block on the GC
// heap instead, so the report is empty there whatever the report skips,
// and the test then checks nothing.
debug
@("arenaHoldsNoGCPointers.skipsMemoryThatHoldsNoPointers")
unittest {
    import snakebite.frontend.compiler: withCompilerLock;
    import snakebite.gc: enterFrontend, leaveFrontend;

    arenaReportLock.lock;
    scope(exit) arenaReportLock.unlock;
    withCompilerLock({
        void* data;
        {
            enterFrontend;
            scope(exit) leaveFrontend;
            data = GC.malloc(64, GC.BlkAttr.NO_SCAN);
        }
        auto block = new ubyte[64];
        auto word = cast(void**) data;
        *word = block.ptr;

        arenaReport.should == "";
    });
}


// Regions are walked in the order they were made, and a later region can
// be at a lower address. Each range to skip is in the region it is in.
debug
@("arenaWalk.skipsRangesInRegionsAtDescendingAddresses")
unittest {
    import snakebite.arena: PointerFreeRange, walkSpanPointerWords;

    align(16) static ubyte[128] low;
    align(16) static ubyte[128] high;
    const(ubyte)[][2] spans = [high[], low[]];
    const PointerFreeRange[2] skip = [
        PointerFreeRange(&high[32], &high[64]),
        PointerFreeRange(&low[16], &low[48]),
    ];

    size_t visited;
    size_t next;
    foreach (span; spans)
        walkSpanPointerWords(span, skip[], next, (const(void*)* word) nothrow @nogc {
            ++visited;
        });

    // 32 words in all, 8 of them in the ranges.
    visited.should == 24;
}


// dmd's closure frames keep the address of the stack objects they
// capture, and the arena never frees them. The report skips a word that
// was a stack address when the frontend left. The GC heap covering a
// stack that no longer exists cannot be made to happen on demand, so the
// stack of the thread here is a GC block: the word does point into a live
// GC block while the report is read, and the report skips it only because
// of what the word was when the frontend left.
debug
@("arenaHoldsNoGCPointers.stackAddressesOfTheFrontendThread")
unittest {
    import core.sys.posix.pthread: pthread_attr_init, pthread_attr_setstack,
        pthread_attr_t, pthread_create, pthread_join, pthread_t;
    import core.thread: thread_attachThis, thread_detachThis;
    import snakebite.frontend.compiler: withCompilerLock;
    import snakebite.gc: enterFrontend, leaveFrontend;

    __gshared void delegate() onStack;
    __gshared void** closureFrame;

    enum stackSize = 1 << 20;
    auto memory = new ubyte[stackSize + 4096];
    auto aligned = cast(void*) ((cast(size_t) memory.ptr + 4095) & ~size_t(4095));

    onStack = {
        withCompilerLock({
            enterFrontend;
            scope(exit) leaveFrontend;
            int local;
            closureFrame = (new void*[1]).ptr;
            closureFrame[0] = &local;
        });
    };
    static extern(C) void* run(void*) {
        thread_attachThis;
        scope(exit) thread_detachThis;
        onStack();
        return null;
    }

    {
        arenaReportLock.lock;
        scope(exit) arenaReportLock.unlock;
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstack(&attributes, aligned, stackSize).should == 0;
        pthread_t thread;
        pthread_create(&thread, &attributes, &run, null).should == 0;
        pthread_join(thread, null).should == 0;
        scope(exit) closureFrame[0] = null;

        arenaReport.should == "";
    }
}


// A collection frees nothing the AST uses, and marks none of it: code
// dmd compiled before the collection runs correctly after it.
static foreach (backend; Matrix!()) {
    @("astSurvivesCollection." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        collectAndOverwriteFreedMemory;

        25.shouldBeRetOf!(backend, q{
            import std.algorithm: map, sum;
            import std.conv: text;
            import std.range: iota;

            abstract class Shape {
                abstract int area();
            }

            class Square : Shape {
                int side;
                this(int side) { this.side = side; }
                override int area() { return side * side; }
            }

            int survivor() {
                int[string] counts;
                foreach (word; ["a", "bb", "a"])
                    ++counts[word];
                Shape shape = new Square(3);
                return iota(4).map!(x => x * 2).sum + shape.area
                    + counts["a"] + cast(int) text(42).length;
            }
        }, "survivor");
    }
}


// A freed block that something still used would now hold 0xAB.
private void collectAndOverwriteFreedMemory() {
    GC.collect;
    GC.minimize;
    foreach (i; 0 .. 1024) {
        auto junk = new ubyte[4096];
        junk[] = 0xAB;
    }
    GC.collect;
}


// Guest objects stay GC memory, like compiled D's: a collection finalizes
// the ones nothing refers to.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run the GC"),
)) {
    @("guestObjectsAreCollected." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;

            __gshared int finalized;

            class Resource {
                ~this() { ++finalized; }
            }

            void allocate() {
                foreach (i; 0 .. 100)
                    new Resource;
            }

            int main() {
                finalized = 0;
                allocate();
                GC.collect();
                return finalized > 0 ? 0 : 1;
            }
        });
    }
}


// Only the thread inside the frontend allocates from the arena: a guest
// thread running at the same time allocates from the GC.
@("otherThreadsAllocateFromTheGCWhileTheFrontendRuns")
unittest {
    import core.sync.semaphore: Semaphore;
    import core.thread: Thread;
    import snakebite.frontend.compiler: withCompilerLock;
    import snakebite.gc: enterFrontend, leaveFrontend, lowmem;

    auto go = new Semaphore;
    auto done = new Semaphore;
    int* fromOtherThread;
    auto other = new Thread({
        go.wait;
        fromOtherThread = new int;
        done.notify;
    });
    other.start;

    int* fromFrontendThread;
    withCompilerLock({
        enterFrontend;
        scope(exit) leaveFrontend;
        go.notify;
        done.wait;
        fromFrontendThread = new int;
    });
    other.join;

    (GC.addrOf(fromOtherThread) !is null).should == true;
    (GC.addrOf(fromFrontendThread) is null).should == !lowmem;
}
