module snakebite.frontend.lock;

private:

import core.sync.mutex: Mutex;

// The one lock around dmd's process-global state. It only excludes other
// threads: code that holds it allocates from the GC. It is a global because
// dmd's state is process-global too. It lives in a module of its own because
// both the compiler and the delegate queries need it, and neither may import
// the other.
package(snakebite.frontend) __gshared Mutex frontendMutex;

private shared static this() {
    frontendMutex = new Mutex;
}

// Thread-owned metadata belongs to one set of frontend declarations.
// Reset and shutdown require exclusive access with no live frontend users;
// the next read on each thread must discard its previous snapshots.
private shared size_t _metadataGeneration;

public size_t metadataGeneration() @safe nothrow @nogc {
    import core.atomic: atomicLoad, MemoryOrder;

    return atomicLoad!(MemoryOrder.acq)(_metadataGeneration);
}

package(snakebite.frontend) void discardMetadata() @safe nothrow @nogc {
    import core.atomic: atomicOp;

    atomicOp!"+="(_metadataGeneration, size_t(1));
}

// Metadata queries can run inside an unfinished diagnostic pass. They must
// exclude semantic writers without clearing that pass's errors or flags.
public void withCompilerQuery(scope void delegate() query) {
    import snakebite.memory.gc: resumeFrontend, suspendFrontend;

    version(unittest) {
        import snakebite.host.sharedtable: assertCacheFillAllowed;
        assertCacheFillAllowed!"frontend metadata query";
    }
    frontendMutex.lock;
    scope(exit) frontendMutex.unlock;

    const depth = suspendFrontend;
    scope(exit) resumeFrontend(depth);
    query();
}
