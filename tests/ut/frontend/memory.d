module ut.frontend.memory;


// The frontend allocates like dmd does: from an arena that is never
// freed and never scanned (`snakebite.gc`). Guest and host code keep
// the GC, exactly like compiled D.


import core.memory: GC;
import snakebite.frontend.compiler: arenaReport, parseSnippet;
import ut.backends;


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
// to would be freed while the AST still uses it. Serial: ordered
// against reportsAPointerIntoTheGCHeap below, so it never reads the
// report while that test's planted pointer is still in the arena.
debug
@("arenaHoldsNoGCPointers.largeImport")
@Serial
unittest {
    parseSnippet(q{
        module arenaHoldsNoGCPointersLargeImport;
        import std;
        string describe() {
            return iota(10).map!(i => i * 2).filter!(i => i % 3 == 0)
                .format!"%s";
        }
    });

    arenaReport.should == "";
}


// The report finds a GC pointer stored in the arena. Serial: every other
// test that reads the report expects an empty one. `--lowmem` puts the
// identifier itself on the GC heap, so the planted word never lands in
// the arena and the report stays empty; the report only ever names GC
// pointers that the arena holds.
debug
@("arenaHoldsNoGCPointers.reportsAPointerIntoTheGCHeap")
@Serial
unittest {
    import dmd.identifier: Identifier;
    import snakebite.frontend.compiler: frontend;
    import snakebite.gc: lowmem;

    // An identifier's name is arena memory the test can write a word to.
    auto identifier = frontend!(Identifier.idPool)(
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


// A collection frees nothing the AST uses, and marks none of it: code
// dmd compiled before the collection runs correctly after it.
static foreach (backend; Matrix!()) {
    @("astSurvivesCollection." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
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
    @Serial
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
