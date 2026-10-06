module ut.backends.threadstate;


import core.memory: GC;
import snakebite.backends: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import snakebite.hostthreads: heapObjectsOfThisThread;
import ut.backends;


// A guest object that a collection finalizes after its backend's owner
// went out of scope still runs its guest destructor. The program touches
// no thread-local variable, so the owner released an empty table, and the
// finalizer makes a new state. The collection may leave some objects alive
// (the GC is conservative), so the test checks that at least one
// destructor ran and that no run crashed.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run the GC"),
)) {
    @("finalizerOfGuestObjectRunsAfterBackendOwnerEnded." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Lives as long as the process: a finalizer that a later collection
        // runs must not write into the frame of a test that ended.
        static __gshared int[2] probe;
        probe = [-1, 0];
        runResources!(backend, Touches.nothing)(probe);
        (probe[1] > 0).should == true;
    }
}


// A guest destructor can still read a thread-local variable through a
// pointer after the owner ended: the owner must not free that storage.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run the GC"),
)) {
    @("threadLocalOfGuestOutlivesBackendOwner." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static __gshared int[2] probe;
        probe = [-1, 0];
        runResources!(backend, Touches.threadLocal)(probe);
        (probe[1] > 0).should == true;
        probe[0].should == 42;
    }
}


// The table of thread-local variables that a program did not touch is empty:
// no pointer can point into it, so the owner releases it with the rest of
// the state.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE has no execution state"),
)) {
    @("emptyThreadLocalTableIsReleasedWithOwner." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // The objects keep this address after the test returns.
        static __gshared int[2] probe;
        // The first use of a backend on a thread makes a state that stays
        // until the thread ends.
        makeResources!(backend, Touches.nothing)(probe);
        const before = heapObjectsOfThisThread;
        makeResources!(backend, Touches.nothing)(probe);
        heapObjectsOfThisThread.should == before;
    }
}


private enum Touches { nothing, threadLocal }

private int nativeLocal = 42;

private final class NativeResource {
    int* place;
    int* probe;
    this(int* probe) {
        place = &nativeLocal;
        this.probe = probe;
    }
    ~this() {
        probe[0] = *place;
        ++probe[1];
    }
}

private final class NativeResourceWithoutLocal {
    int* probe;
    this(int* probe) {
        this.probe = probe;
    }
    ~this() {
        ++probe[1];
    }
}

// Makes 100 guest objects through a backend that ends before this returns,
// then collects. Each destructor counts itself in `probe[1]`, and one that
// touches a thread-local variable stores its value in `probe[0]`.
private void runResources(Backend, Touches touches)(ref int[2] probe) {
    makeResources!(Backend, touches)(probe);
    // Stack garbage must not keep an object alive.
    clobberStack;
    GC.collect;
}

private void makeResources(Backend, Touches touches)(ref int[2] probe) {
    static if (is(Backend == Native)) {
        foreach (i; 0 .. 100) {
            static if (touches == Touches.threadLocal)
                new NativeResource(probe.ptr);
            else
                new NativeResourceWithoutLocal(probe.ptr);
        }
    } else {
        static if (touches == Touches.threadLocal) {
            enum source = q{
                int local = 42;

                class Resource {
                    int* place;
                    int* probe;
                    this(int* probe) {
                        place = &local;
                        this.probe = probe;
                    }
                    ~this() {
                        probe[0] = *place;
                        ++probe[1];
                    }
                }

                void make(int* probe) {
                    foreach (i; 0 .. 100)
                        new Resource(probe);
                }
            };
        } else {
            enum source = q{
                class Resource {
                    int* probe;
                    this(int* probe) {
                        this.probe = probe;
                    }
                    ~this() {
                        ++probe[1];
                    }
                }

                void make(int* probe) {
                    foreach (i; 0 .. 100)
                        new Resource(probe);
                }
            };
        }
        auto module_ = parseSnippet(source);
        auto program = Program([module_]);
        auto instance = Owned!Backend(program);
        int* pointer = probe.ptr;
        void*[1] arguments = [cast(void*) &pointer];
        instance.call(findFunction(module_, "make"), null, arguments[]);
    }
}

// Overwrites the stack below the caller, where a dead frame left pointers.
private void clobberStack() {
    ubyte[16384] filler = 0xAB;
    cast(void) filler[$ / 2];
}


// Running programs one after another in one process must not pile up
// execution state, with its frame stacks that the GC scans, on the thread
// that ran them.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE has no execution state"),
)) {
    @("executionsDoNotAccumulateThreadState." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // The first use of a backend on a thread makes a state that stays
        // until the thread ends.
        1.shouldBeRetOf!(
            backend, q{ int answer() { return 1; } }, "answer");
        const before = heapObjectsOfThisThread;
        foreach (run; 0 .. 5)
            1.shouldBeRetOf!(
                backend, q{ int answer() { return 1; } }, "answer");
        heapObjectsOfThisThread.should == before;
    }
}
