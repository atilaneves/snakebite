module snakebite.native.staticstore;


private:


import snakebite.host.threads: PerThread;
import snakebite.native.value: TypeFacts;
import snakebite.stack.tls: TlsSlots;


// The blocks that hold static data, and the free space in them. A block
// never moves: slots can hold addresses of other slots. The blocks are in
// the GC heap, so that the GC scans what the data point to, and live as
// long as this does.
public struct StaticBlocks {
    // A copy would share the free space with the original.
    @disable this(this);

    // Written under the compiler lock only, like every miss that fills
    // them.
    private void[][] _blocks;
    private void[] _available;

    // The caller holds the compiler lock.
    public void[] reserve(in TypeFacts facts) {
        // Slots cannot move: constants can hold addresses of other slots.
        const needed = facts.size + facts.alignment - 1;
        if (_available.length < needed) {
            import std.algorithm: max;

            _available = new void[max(4096, needed)];
            _blocks ~= _available;
        }
        const start = -cast(size_t) _available.ptr & (facts.alignment - 1);
        auto bytes = _available[start .. start + facts.size];
        _available = _available[start + facts.size .. $];
        return bytes;
    }
}


// The storage that holds the static data and constants of a program while
// it runs. It holds no frontend type: what fills it is in `NativeData`.
public struct StaticStore {
    // Holds a `PerThread`: a copy would share storage with the original.
    @disable this(this);

    // The blocks of the data that no D module owns, or all of the data when
    // the owner of this gives no other blocks.
    private StaticBlocks _blocks;
    // The copies are outside the GC heap, as read-only data is in compiled
    // D, and are freed with this object.
    private void*[] _stringBlocks;
    // This thread's own copies of the thread-local variables, never shared,
    // so `TlsSlots.slotFor` takes no lock.
    private PerThread!(TlsSlots*) _tls;

    // `newTlsSlots` makes the table of thread-local variables that a thread
    // gets on its first use of the store.
    public this(TlsSlots* delegate() newTlsSlots) {
        _tls = PerThread!(TlsSlots*)(newTlsSlots);
    }

    ~this() {
        import core.stdc.stdlib: free;

        foreach (block; _stringBlocks)
            free(block);
    }

    // The caller holds the compiler lock.
    public void[] reserve(in TypeFacts facts) {
        return _blocks.reserve(facts);
    }

    // Takes ownership of a `malloc`ed block. The caller holds the compiler
    // lock.
    public void adoptString(void* block) {
        _stringBlocks ~= block;
    }

    // Gives back this thread's table of thread-local variables, unless it
    // holds a variable: a guest object that outlives the owner can still
    // point into the storage of one, and compiled D keeps it until the
    // thread ends too.
    public void release() {
        _tls.release((slots) => slots.empty);
    }

    public TlsSlots* tlsSlots() {
        return _tls.current;
    }
}
