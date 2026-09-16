module ut.threadsync;


import core.atomic: atomicLoad, atomicOp;
import core.thread: Thread;
import core.time: msecs;


// A foreign thread's attach into druntime (automatic, ADR-0006, or by
// hand with `thread_attachThis`) must never overlap an explicit
// `GC.collect` run from another thread. `thread_attachThis` allocates
// its `Thread` object before it registers the thread, and a collect
// that runs in that window frees the object - a druntime bug, not a
// snakebite bug (see the "Known limitation" heading of ADR-0006).
//
// unit-threaded runs many unittest bodies from different modules at
// the same time. A test that starts a collector thread has no idea a
// wholly different test, in a wholly different module, is attaching a
// foreign thread right then. These four functions close that window
// for the whole test binary: every place that attaches a foreign
// thread, or that runs an explicit collect on another thread, gates
// itself through here first, so the two kinds of work never overlap,
// no matter which test each one belongs to.
//
// Two plain atomic counters, not a lock: nothing here is ever
// unlocked by a thread other than the one that locked it, which a
// `Mutex` handed from one thread to another cannot promise.
private shared int attaching = 0;
private shared int collecting = 0;


private void enter(ref shared int mine, ref shared int other) @trusted {
    while (true) {
        while (atomicLoad(other) > 0)
            Thread.sleep(1.msecs);
        atomicOp!"+="(mine, 1);
        if (atomicLoad(other) == 0)
            return;
        // The other side started an already-open window between the
        // check above and the increment. Back off and try again.
        atomicOp!"-="(mine, 1);
    }
}


// Call before a foreign thread may start attaching, for example
// before `pthread_create` on a thread whose first guest entry will
// attach it. Waits out any explicit collect already running.
void beginForeignAttach() @trusted {
    enter(attaching, collecting);
}


// Call once the foreign thread has made its first guest entry: attach
// is done by then, automatic (ADR-0006) or by hand
// (`thread_attachThis`), because guest code cannot run before it.
void endForeignAttach() @trusted {
    atomicOp!"-="(attaching, 1);
}


// Call before an explicit `GC.collect` that runs on another thread.
// Waits out any foreign thread that is still attaching.
void beginExplicitCollect() @trusted {
    enter(collecting, attaching);
}


void endExplicitCollect() @trusted {
    atomicOp!"-="(collecting, 1);
}
